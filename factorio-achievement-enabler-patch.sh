#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio"
BACKUP="$SCRIPT_DIR/factorio.original"
BACKUP_SHA="$BACKUP.sha256"

# SteamContext::setStat()
# Stock:
#   cmp  x8, x9
#   b.eq vanilla_path
# Patched:
#   cmp  x8, x9
#   b    vanilla_path
VM_SET_STAT=$((0x10198CD64))
STOCK_SET_STAT="20010054"
PATCH_SET_STAT="09000014"

# SteamContext::unlockAchievement()
# Stock:
#   cmp  x8, x9
#   b.eq vanilla_path
# Patched:
#   cmp  x8, x9
#   b    vanilla_path
VM_UNLOCK=$((0x10198CE14))
STOCK_UNLOCK="20010054"
PATCH_UNLOCK="09000014"

# SteamContext::unlockAchievementsThatAreOnSteamButArentActivatedLocally()
# Stock:   b.eq reconciliation_path
# Patched: b    reconciliation_path
VM_RECONCILE=$((0x10198DC4C))
STOCK_RECONCILE="a0030054"
PATCH_RECONCILE="1d000014"

# SteamContext::updateAchievementStatsFromSteam()
# Stock:   b.eq sync_path
# Patched: b    sync_path
VM_SYNC=$((0x10198CF74))
STOCK_SYNC="20010054"
PATCH_SYNC="09000014"

# PlayerData::PlayerData()
# x10 = "achievements.dat", x21 = "achievements-modded.dat".
# Stock:   b +8  -> skip `mov x21, x10`
# Patched: b +4  -> execute `mov x21, x10`
VM_PLAYER_DATA=$((0x100346DE8))
STOCK_PLAYER_DATA="02000014"
PATCH_PLAYER_DATA="01000014"

PATCH_NAMES=(
  "setStat gate"
  "UnlockAchievement gate"
  "Local achievement reconciliation gate"
  "Steam stat sync gate"
  "PlayerData achievement file select"
)
PATCH_VMS=(
  "$VM_SET_STAT"
  "$VM_UNLOCK"
  "$VM_RECONCILE"
  "$VM_SYNC"
  "$VM_PLAYER_DATA"
)
PATCH_STOCK=(
  "$STOCK_SET_STAT"
  "$STOCK_UNLOCK"
  "$STOCK_RECONCILE"
  "$STOCK_SYNC"
  "$STOCK_PLAYER_DATA"
)
PATCH_ON=(
  "$PATCH_SET_STAT"
  "$PATCH_UNLOCK"
  "$PATCH_RECONCILE"
  "$PATCH_SYNC"
  "$PATCH_PLAYER_DATA"
)

usage() {
  cat <<'USAGE'
Usage:
  ./factorio-achievements-patch.sh status
  ./factorio-achievements-patch.sh on
  ./factorio-achievements-patch.sh off
  ./factorio-achievements-patch.sh restore

Commands:
  status   Show whether the achievement patch is ON/OFF.
  on       Enable Steam achievements with mods.
  off      Disable the patch and restore the original five instructions.
  restore  Restore the full original executable from the first-run backup.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_tools() {
  local tool
  for tool in lipo otool codesign shasum dd hexdump awk grep pgrep; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required."
  done
}

require_game() {
  [[ -f "$BIN" ]] || die "Factorio executable not found: $BIN"
  [[ -w "$BIN" ]] || die "Factorio executable is not writable: $BIN"
}

ensure_not_running() {
  if pgrep -x factorio >/dev/null 2>&1; then
    die "Factorio is running. Quit the game first."
  fi
}

backup_sha() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_backup() {
  [[ -f "$BACKUP" ]] || die "Original backup not found: $BACKUP"
  [[ -f "$BACKUP_SHA" ]] || die "Backup checksum not found: $BACKUP_SHA"

  local expected actual
  expected="$(tr -d '[:space:]' < "$BACKUP_SHA")"
  actual="$(backup_sha "$BACKUP")"
  [[ "$actual" == "$expected" ]] || die "Original backup checksum mismatch."
}

SLICE_OFF=0
TEXT_VMADDR=0
TEXT_FILEOFF=0
TEXT_FILESIZE=0

init_macho_layout() {
  local archs detailed text

  archs="$(lipo -archs "$BIN" 2>/dev/null)" || die "Unable to inspect Factorio Mach-O architectures."
  case " $archs " in
    *" arm64 "*) ;;
    *) die "ARM64 slice not found in Factorio executable." ;;
  esac

  detailed="$(lipo -detailed_info "$BIN")" || die "Unable to inspect Factorio universal binary."

  if grep -q '^Fat header in:' <<<"$detailed"; then
    SLICE_OFF="$(awk '
      /^architecture arm64$/ { in_arm64=1; next }
      /^architecture /       { in_arm64=0 }
      in_arm64 && $1 == "offset" { print $2; exit }
    ' <<<"$detailed")"
    [[ -n "$SLICE_OFF" ]] || die "Unable to determine ARM64 slice offset."
  else
    SLICE_OFF=0
  fi

  text="$(otool -arch arm64 -l "$BIN" | awk '
    $1 == "segname" && $2 == "__TEXT" { in_text=1; next }
    in_text && $1 == "vmaddr"  { vm=$2 }
    in_text && $1 == "fileoff" { fo=$2 }
    in_text && $1 == "filesize" { print vm, fo, $2; exit }
  ')"
  [[ -n "$text" ]] || die "Unable to locate ARM64 __TEXT segment."

  read -r TEXT_VMADDR TEXT_FILEOFF TEXT_FILESIZE <<<"$text"
}

vm_to_fileoff() {
  local vm="$1"
  (( vm >= TEXT_VMADDR && vm < TEXT_VMADDR + TEXT_FILESIZE )) ||
    die "VM address 0x$(printf '%x' "$vm") is outside ARM64 __TEXT."

  echo $((SLICE_OFF + TEXT_FILEOFF + vm - TEXT_VMADDR))
}

read4() {
  local off="$1"
  dd if="$BIN" bs=1 skip="$off" count=4 2>/dev/null |
    hexdump -v -e '1/1 "%02x"'
}

write4() {
  local off="$1" hex="$2" escaped="" i
  [[ ${#hex} -eq 8 ]] || die "Internal error: patch value must be exactly 4 bytes."

  for ((i = 0; i < 8; i += 2)); do
    escaped+="\\x${hex:i:2}"
  done

  printf '%b' "$escaped" |
    dd of="$BIN" bs=1 seek="$off" count=4 conv=notrunc 2>/dev/null

  [[ "$(read4 "$off")" == "$hex" ]] ||
    die "Byte verification failed at file offset 0x$(printf '%x' "$off")."
}

patch_binary() {
  local action="$1" i off current state global_state desired
  local -a offsets currents states

  init_macho_layout

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    off="$(vm_to_fileoff "${PATCH_VMS[i]}")"
    current="$(read4 "$off")"

    if [[ "$current" == "${PATCH_STOCK[i]}" ]]; then
      state="stock"
    elif [[ "$current" == "${PATCH_ON[i]}" ]]; then
      state="patched"
    else
      state="unknown"
    fi

    offsets[i]="$off"
    currents[i]="$current"
    states[i]="$state"
  done

  local stock_count=0 patched_count=0 unknown_count=0
  for state in "${states[@]}"; do
    case "$state" in
      stock)   ((stock_count += 1)) ;;
      patched) ((patched_count += 1)) ;;
      unknown) ((unknown_count += 1)) ;;
    esac
  done

  if (( unknown_count > 0 )); then
    global_state="UNKNOWN"
  elif (( stock_count == ${#states[@]} )); then
    global_state="OFF"
  elif (( patched_count == ${#states[@]} )); then
    global_state="ON"
  else
    global_state="MIXED"
  fi

  if [[ "$action" == "status" ]]; then
    echo "Factorio: $BIN"
    for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
      printf '%-44s %s\n' "${PATCH_NAMES[i]} bytes:" "${currents[i]}"
    done

    case "$global_state" in
      ON)      echo "Patch: ON" ;;
      OFF)     echo "Patch: OFF" ;;
      MIXED)   echo "Patch: MIXED (known bytes, but only part of the patch is applied)" ;;
      UNKNOWN)
        echo "Patch: UNKNOWN BUILD / BYTES"
        echo "Refusing to modify this binary until offsets are re-verified."
        ;;
    esac
    return 0
  fi

  [[ "$global_state" != "UNKNOWN" ]] || {
    patch_binary status
    die "Unexpected bytes. Factorio may have been updated; not patching."
  }

  if [[ "$action" == "check-stock" ]]; then
    [[ "$global_state" == "OFF" ]] ||
      die "First-run backup requires an unmodified executable; current state is $global_state."
    return 0
  fi

  case "$action" in
    on)
      [[ "$global_state" != "ON" ]] || { echo "Patch is already ON."; return 0; }
      ;;
    off)
      [[ "$global_state" != "OFF" ]] || { echo "Patch is already OFF."; return 0; }
      ;;
    *) die "Internal error: unknown patch action: $action" ;;
  esac

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    if [[ "$action" == "on" ]]; then
      desired="${PATCH_ON[i]}"
    else
      desired="${PATCH_STOCK[i]}"
    fi

    [[ "${currents[i]}" == "$desired" ]] || write4 "${offsets[i]}" "$desired"
  done

  # Verify the resulting state before signing.
  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    current="$(read4 "${offsets[i]}")"
    if [[ "$action" == "on" ]]; then
      desired="${PATCH_ON[i]}"
    else
      desired="${PATCH_STOCK[i]}"
    fi
    [[ "$current" == "$desired" ]] || die "Byte verification failed for ${PATCH_NAMES[i]}."
  done
}

ensure_backup() {
  if [[ -f "$BACKUP" || -f "$BACKUP_SHA" ]]; then
    verify_backup
    return
  fi

  patch_binary check-stock
  cp -p "$BIN" "$BACKUP"
  backup_sha "$BACKUP" > "$BACKUP_SHA"
  verify_backup
  echo "Backup: $BACKUP"
}

resign_binary() {
  echo "Re-signing Factorio ad-hoc while preserving signing metadata..."
  codesign \
    --force \
    --sign - \
    --preserve-metadata=identifier,entitlements,flags,runtime \
    "$BIN"

  echo "Verifying signature..."
  codesign --verify --strict "$BIN"
}

cmd_status() {
  patch_binary status
}

cmd_on() {
  ensure_not_running
  ensure_backup

  echo "Enabling achievement patch..."
  if ! patch_binary on; then
    echo "Patching failed; restoring original executable." >&2
    cp -p "$BACKUP" "$BIN"
    exit 1
  fi

  if ! resign_binary; then
    echo "Signing failed; restoring original executable." >&2
    cp -p "$BACKUP" "$BIN"
    exit 1
  fi

  echo
  echo "Achievement patch: ON"
}

cmd_off() {
  ensure_not_running

  echo "Disabling achievement patch..."
  patch_binary off
  resign_binary

  echo
  echo "Achievement patch: OFF"
}

cmd_restore() {
  ensure_not_running
  verify_backup

  echo "Restoring full original executable..."
  cp -p "$BACKUP" "$BIN"

  local expected actual
  expected="$(tr -d '[:space:]' < "$BACKUP_SHA")"
  actual="$(backup_sha "$BIN")"
  [[ "$actual" == "$expected" ]] || die "Restored executable checksum mismatch."

  echo "Original executable restored."
}

main() {
  require_tools
  require_game

  case "${1:-status}" in
    status)  cmd_status ;;
    on)      cmd_on ;;
    off)     cmd_off ;;
    restore) cmd_restore ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
