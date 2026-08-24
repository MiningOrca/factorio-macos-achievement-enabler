# Factorio macOS Achievement Enabler

Enable Steam achievements with mods in Factorio 2.0/2.1 on macOS Apple Silicon (ARM64).

The patch modifies only achievement-related mod checks and makes modded games use the normal `achievements.dat` instead of `achievements-modded.dat`. It does **not** disable mod detection globally.

## Requirements

* Factorio for macOS
* Apple Silicon (ARM64)
* Steam version

Factorio is expected at the default Steam location:

```text
~/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app
```

## Usage

Download `factorio-achievements-patch.sh` and make it executable:

```bash
chmod +x factorio-achievements-patch.sh
```

Quit Factorio before enabling, disabling, or restoring the patch.

### Enable

```bash
./factorio-achievements-patch.sh on
```

The original executable is backed up automatically.

### Check status

```bash
./factorio-achievements-patch.sh status
```

Example:

```text
Factorio: /Users/.../Factorio/factorio.app/Contents/MacOS/factorio
Locations: symbols

SteamContext::setStat                                      bytes: 20010054
SteamContext::unlockAchievement                            bytes: 20010054
unlockAchievementsThatAreOnSteamButArentActivatedLocally   bytes: a0030054
SteamContext::updateAchievementStatsFromSteam              bytes: 20010054
PlayerData::PlayerData                                     bytes: 02000014

Patch: OFF
```

### Disable

```bash
./factorio-achievements-patch.sh off
```

Restores the original five instructions while keeping the backup.

### Restore original executable

```bash
./factorio-achievements-patch.sh restore
```

Restores the complete original executable from the backup.

## Compatibility

Verified with Factorio **2.0** and **2.1** ARM64 builds.

The script normally finds the required functions from their ARM64 symbols and calculates the patch locations relative to them instead of relying on fixed executable addresses.

Because of this, newer Factorio versions may continue to work without changes to the script.

Before modifying anything, the script verifies that every patch location contains exactly the expected original or already-patched instruction. If a game update changes the relevant code, the script refuses to modify the executable.

If symbols are unavailable, verified fallback addresses are included for Factorio 2.0 and 2.1.

## What It Patches

Five achievement-related code paths are modified:

```text
SteamContext::setStat
SteamContext::unlockAchievement
unlockAchievementsThatAreOnSteamButArentActivatedLocally
SteamContext::updateAchievementStatsFromSteam
PlayerData::PlayerData
```

The first four bypass mod-dependent checks that prevent Steam achievement and statistic operations.

The relevant conditional branches are changed from:

```asm
b.eq target
```

to unconditional branches to the same target:

```asm
b target
```

The `PlayerData::PlayerData()` patch makes modded games use:

```text
achievements.dat
```

instead of:

```text
achievements-modded.dat
```

## Game Updates

After updating Factorio, run:

```bash
./factorio-achievements-patch.sh status
```

If the relevant code has not changed, the script should continue to work normally.

If it reports:

```text
Patch: UNKNOWN BUILD / BYTES
Refusing to modify this binary until the patch is re-verified.
```

do not try to force the old patch.

Please open a GitHub issue and include:

* your Factorio version;
* the full output of the `status` command.

The new build can then be checked and support added if necessary.

## Backup and Recovery

The first successful `on` creates:

```text
factorio.original
factorio.original.sha256
```

next to the patch script.

The backup checksum is verified before it is used.

To restore the saved original executable:

```bash
./factorio-achievements-patch.sh restore
```

Steam's **Verify integrity of game files** can also restore the official executable.

## License

MIT
