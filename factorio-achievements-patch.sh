#!/bin/bash
set -euo pipefail

APP="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app"
BIN="$APP/Contents/MacOS/factorio"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP="$SCRIPT_DIR/factorio.original"
BACKUP_SHA="$BACKUP.sha256"

PATCH_NAMES=(
  "SteamContext::setStat"
  "SteamContext::unlockAchievement"
  "unlockAchievementsThatAreOnSteamButArentActivatedLocally"
  "SteamContext::updateAchievementStatsFromSteam"
  "PlayerData::PlayerData"
)

PATCH_SYMBOLS=(
  '^__ZN12SteamContext7setStatEPKci$'
  '^__ZN12SteamContext17unlockAchievementEPKc$'
  'unlockAchievementsThatAreOnSteamButArentActivatedLocallyEv$'
  '^__ZN12SteamContext31updateAchievementStatsFromSteamEv$'
  '^__ZN10PlayerDataC2Ev$'
)

PATCH_REL=(
  $((0x38))
  $((0x34))
  $((0x54))
  $((0x40))
  $((0x20c))
)

# Stock -> patched ARM64 instruction bytes.
PATCH_STOCK=(
  "20010054"
  "20010054"
  "a0030054"
  "20010054"
  "02000014"
)

PATCH_ON=(
  "09000014"
  "09000014"
  "1d000014"
  "09000014"
  "01000014"
)

# Verified fallback patch VMs for builds where symbols are unavailable.
KNOWN_20=(
  $((0x10198cd64))
  $((0x10198ce14))
  $((0x10198dc4c))
  $((0x10198cf74))
  $((0x100346de8))
)

KNOWN_21=(
  $((0x101b3a9e0))
  $((0x101b3aa90))
  $((0x101b3b8c8))
  $((0x101b3abf0))
  $((0x10039e758))
)

PATCH_VMS=(0 0 0 0 0)
PATCH_OFFSETS=()
PATCH_CURRENTS=()
PATCH_STATES=()
LOCATION_SOURCE="unresolved"

SLICE_OFF=0
TEXT_VMADDR=0
TEXT_FILEOFF=0
TEXT_FILESIZE=0

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
  for tool in nm lipo otool codesign shasum dd hexdump awk grep pgrep tr; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required."
  done
}

require_game() {
  [[ -d "$APP" ]] || die "Factorio app not found: $APP"
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

is_adhoc_app() {
  codesign -dv --verbose=4 "$APP" 2>&1 | grep -q '^Signature=adhoc$'
}

is_clean_signed_app() {
  codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || return 1
  is_adhoc_app && return 1
  return 0
}

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
    in_text && $1 == "vmaddr"   { vm=$2 }
    in_text && $1 == "fileoff"  { fo=$2 }
    in_text && $1 == "filesize" { print vm, fo, $2; exit }
  ')"
  [[ -n "$text" ]] || die "Unable to locate ARM64 __TEXT segment."

  read -r TEXT_VMADDR TEXT_FILEOFF TEXT_FILESIZE <<<"$text"
}

vm_to_fileoff() {
  local vm="$1"
  (( vm >= TEXT_VMADDR && vm < TEXT_VMADDR + TEXT_FILESIZE )) || return 1
  echo $((SLICE_OFF + TEXT_FILEOFF + vm - TEXT_VMADDR))
}

read4() {
  local off="$1"
  dd if="$BIN" bs=1 skip="$off" count=4 2>/dev/null |
    hexdump -v -e '1/1 "%02x"'
}

write4() {
  local off="$1" hex="$2" escaped="" i
  [[ ${#hex} -eq 8 ]] || return 1

  for ((i = 0; i < 8; i += 2)); do
    escaped+="\\x${hex:i:2}"
  done

  printf '%b' "$escaped" |
    dd of="$BIN" bs=1 seek="$off" count=4 conv=notrunc 2>/dev/null || return 1

  [[ "$(read4 "$off")" == "$hex" ]]
}

symbol_vm() {
  local regex="$1" matches count hex

  matches="$(nm -arch arm64 -n "$BIN" 2>/dev/null | awk -v re="$regex" '$3 ~ re { print $1 }')" || return 1
  [[ -n "$matches" ]] || return 1

  count="$(printf '%s\n' "$matches" | awk 'END { print NR }')"
  [[ "$count" == "1" ]] || return 1

  hex="$(printf '%s\n' "$matches" | awk 'NR == 1 { print $1 }')"
  [[ "$hex" =~ ^[0-9a-fA-F]+$ ]] || return 1

  echo $((16#$hex))
}

resolve_vms_from_symbols() {
  local i base

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    base="$(symbol_vm "${PATCH_SYMBOLS[i]}")" || return 1
    PATCH_VMS[i]=$((base + PATCH_REL[i]))
  done

  LOCATION_SOURCE="symbols"
  return 0
}

set_known_vms() {
  local build="$1" i

  case "$build" in
    20)
      for ((i = 0; i < ${#PATCH_VMS[@]}; i++)); do
        PATCH_VMS[i]="${KNOWN_20[i]}"
      done
      LOCATION_SOURCE="verified build 2.0"
      ;;
    21)
      for ((i = 0; i < ${#PATCH_VMS[@]}; i++)); do
        PATCH_VMS[i]="${KNOWN_21[i]}"
      done
      LOCATION_SOURCE="verified build 2.1"
      ;;
    *) return 1 ;;
  esac
}

classify_patch_locations() {
  local i off current state
  PATCH_OFFSETS=()
  PATCH_CURRENTS=()
  PATCH_STATES=()

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    if off="$(vm_to_fileoff "${PATCH_VMS[i]}")"; then
      current="$(read4 "$off")"
    else
      off=""
      current="out-of-range"
    fi

    if [[ "$current" == "${PATCH_STOCK[i]}" ]]; then
      state="stock"
    elif [[ "$current" == "${PATCH_ON[i]}" ]]; then
      state="patched"
    else
      state="unknown"
    fi

    PATCH_OFFSETS[i]="$off"
    PATCH_CURRENTS[i]="$current"
    PATCH_STATES[i]="$state"
  done
}

has_unknown_patch_location() {
  local state
  for state in "${PATCH_STATES[@]}"; do
    [[ "$state" != "unknown" ]] || return 0
  done
  return 1
}

resolve_patch_locations() {
  if resolve_vms_from_symbols; then
    classify_patch_locations
    return 0
  fi

  set_known_vms 21
  classify_patch_locations
  if ! has_unknown_patch_location; then
    return 0
  fi

  set_known_vms 20
  classify_patch_locations
  if ! has_unknown_patch_location; then
    return 0
  fi

  LOCATION_SOURCE="unresolved"
  return 1
}

global_state() {
  local state stock_count=0 patched_count=0 unknown_count=0

  for state in "${PATCH_STATES[@]}"; do
    case "$state" in
      stock)   ((stock_count += 1)) ;;
      patched) ((patched_count += 1)) ;;
      *)       ((unknown_count += 1)) ;;
    esac
  done

  if (( unknown_count > 0 )); then
    echo "UNKNOWN"
  elif (( stock_count == ${#PATCH_STATES[@]} )); then
    echo "OFF"
  elif (( patched_count == ${#PATCH_STATES[@]} )); then
    echo "ON"
  else
    echo "MIXED"
  fi
}

show_status_resolved() {
  local i state
  state="$(global_state)"

  echo "Factorio: $BIN"
  echo "Locations: $LOCATION_SOURCE"
  echo

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    printf '%-58s bytes: %s\n' \
  "${PATCH_NAMES[i]}" \
  "${PATCH_CURRENTS[i]}"
  done

  echo
  case "$state" in
    ON)    echo "Patch: ON" ;;
    OFF)   echo "Patch: OFF" ;;
    MIXED) echo "Patch: MIXED (known bytes, but only part of the patch is applied)" ;;
    *)
      echo "Patch: UNKNOWN BUILD / BYTES"
      echo "Refusing to modify this binary until the patch is re-verified."
      ;;
  esac
}

resolve_and_classify() {
  init_macho_layout
  if ! resolve_patch_locations; then
    classify_patch_locations
  fi
}

patch_binary() {
  local action="$1" i desired state

  resolve_and_classify
  state="$(global_state)"

  if [[ "$action" == "status" ]]; then
    show_status_resolved
    return 0
  fi

  [[ "$state" != "UNKNOWN" ]] || {
    show_status_resolved
    return 1
  }

  if [[ "$action" == "check-stock" ]]; then
    [[ "$state" == "OFF" ]]
    return
  fi

  case "$action" in
    on)
      [[ "$state" != "ON" ]] || { echo "Patch is already ON."; return 0; }
      ;;
    off)
      [[ "$state" != "OFF" ]] || { echo "Patch is already OFF."; return 0; }
      ;;
    *) return 1 ;;
  esac

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    if [[ "$action" == "on" ]]; then
      desired="${PATCH_ON[i]}"
    else
      desired="${PATCH_STOCK[i]}"
    fi

    if [[ "${PATCH_CURRENTS[i]}" != "$desired" ]]; then
      write4 "${PATCH_OFFSETS[i]}" "$desired" || return 1
    fi
  done

  resolve_and_classify
  state="$(global_state)"
  if [[ "$action" == "on" ]]; then
    [[ "$state" == "ON" ]]
  else
    [[ "$state" == "OFF" ]]
  fi
}

make_or_refresh_backup() {
  local current_sha stored_sha

  patch_binary check-stock || die "A clean unpatched executable is required before creating or refreshing the backup."
  current_sha="$(backup_sha "$BIN")"

  if [[ -f "$BACKUP" || -f "$BACKUP_SHA" ]]; then
    [[ -f "$BACKUP" && -f "$BACKUP_SHA" ]] || die "Incomplete backup state. Remove both backup files after verifying Factorio through Steam."
    verify_backup
    stored_sha="$(tr -d '[:space:]' < "$BACKUP_SHA")"

    if [[ "$current_sha" == "$stored_sha" ]]; then
      return 0
    fi

    is_clean_signed_app || die "The existing backup belongs to another build, but the current app is not a clean signed installation. Verify Factorio through Steam first."
    echo "Game build changed; refreshing original executable backup..."
  else
    is_clean_signed_app || die "Refusing to create an original backup from an ad-hoc or invalidly signed app. Verify Factorio through Steam first."
    echo "Creating original executable backup..."
  fi

  cp -p "$BIN" "$BACKUP"
  backup_sha "$BACKUP" > "$BACKUP_SHA"
  verify_backup
  echo "Backup: $BACKUP"
}

resign() {
  echo "Re-signing Factorio ad-hoc while preserving signing metadata..."
  codesign \
    --force \
    --sign - \
    --preserve-metadata=identifier,entitlements,flags \
    "$APP"

  echo "Verifying signature..."
  codesign --verify --deep --strict --verbose=2 "$APP"
}

cmd_status() {
  resolve_and_classify
  show_status_resolved
}

cmd_on() {
  ensure_not_running
  make_or_refresh_backup

  echo "Enabling achievement patch..."
  if ! patch_binary on; then
    echo "Patching failed; restoring original executable." >&2
    cp -p "$BACKUP" "$BIN"
    exit 1
  fi

  if ! resign; then
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
  if ! patch_binary off; then
    die "Failed to restore stock instructions."
  fi

  resign

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

  echo "Verifying restored app signature..."
  if codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "Original executable restored and signature verifies."
  else
    echo "Original executable restored, but bundle verification failed." >&2
    echo "Use Steam -> Properties -> Installed Files -> Verify integrity if Factorio does not launch." >&2
    exit 1
  fi
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
