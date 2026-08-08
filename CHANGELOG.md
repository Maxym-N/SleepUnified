# Changelog

All notable changes to this project are documented here, newest first.

## 1.1

- Reordered settings fields (State file / State file max size / Log file / Log file max size).
- Clarified that the AC spurious-wake threshold only matters on hardware with that specific firmware behavior.
- Changing the AC udev rule path now removes the old rule file left at the previous path, instead of leaving it behind unreferenced.
- Replaced the Python regeneration helper with a bash one.

## 1.0

- Compiled into a single binary: no arguments runs the sleep/resume logic (embedded from `sleep-unified.sh`) directly; `--gui` opens the settings panel.
- Added ten independent stage toggles.
- Added an external per-user config file.
- Added "Reset to Defaults".

## 0.98

- Added touchpad state save/restore, working around a firmware behavior where the AC-adapter WMI event reuses the touchpad-toggle code.

## 0.97

- Added the in-script README and CONFIGURATION section.
- Corrected the usage documentation.
- Removed subjective wording from comments.

## 0.96

- Public-release readiness: filesystem-agnostic disk release check (works for any filesystem, not just NTFS/exFAT).
- Added Wayland screen on/off support.
- Various wording/portability cleanups.

## 0.95

- The udev rule is now installed automatically if missing, instead of requiring a separate manual install step.

## 0.94

- Extended AC spurious-wake detection to cover unplugging the adapter, not just plugging it in.

## 0.93

- **Security fix:** Wi-Fi/Bluetooth were never actually being blocked before sleep due to a parsing bug; fixed.

## 0.92

- Added diagnostic rfkill-state logging at each wake.

## 0.91

- Simplified the udev rule to a single self-contained file.

## 0.90

- Replaced dmesg-based AC-event detection with a companion udev rule (more reliable across different hardware/firmware).

## 0.89

- Added automatic re-sleep for a firmware behavior where an AC-adapter state change while asleep wakes the system almost instantly.

## 0.88

- Fixed detection of USB network-tethering devices (e.g. a phone in USB-modem mode) for post-resume recovery.
- Switched their recovery to a full USB reauthorization cycle instead of an ineffective driver rebind.

## 0.87

- Reverted 0.86: no process holding a file open is ever signalled or killed. Applications keep running; only a safe unmount path is used.

## 0.86

- Added SIGTERM/SIGKILL escalation for processes blocking a USB disk unmount. *(Later reverted in 0.87.)*

## 0.85

- Notifications now always print to the console in addition to any GUI dialog, and GUI dialogs are only attempted when a display is actually present.
- Added `notify-send`/`xmessage`/`yad`/`whiptail` as further fallbacks.

## 0.84

- Removed a dead, non-functional state check left over from before the state array existed at that point in execution. No behavior change.

## 0.83

- Fixed partition detection for USB disks where partitions are nested one level deeper than expected (e.g. `block/sdb/sdb1`), which had caused unmounts to be silently skipped.

## 0.82

- Fixed a race: USB disks could be granted permission to spin down before being safely unmounted. SATA/SCSI power management now runs after USB disks are disconnected, not before.

## 0.81

Baseline for version-tracked history (earlier development wasn't version-logged):

- Pre-suspend hardware prep (ACPI wakeup, CPU governors, rfkill, network interfaces, USB wakeup/power, SATA power management).
- USB storage disconnect/reconnect.
- Matching post-resume restore.
