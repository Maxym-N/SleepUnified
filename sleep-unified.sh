#!/bin/bash
# -----------------------------------------------------------------------------
# Unified Sleep Mode Optimization Framework – Version 0.97
# Author: Maksym Nazar
# With assistance from: ChatGPT and Claude
# Year: 2025-2026
# License: GNU General Public License (GPL) Version 3.0
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# Description:
#   This script enhances system sleep reliability by preparing devices
#   and system components for low-power suspend modes. It optimizes
#   behavior for both shallow (s2idle) and deep sleep (suspend-to-RAM),
#   depending on hardware capabilities and system configuration.
#
# Changelog 0.82:
#   - Moved the SATA/SCSI "manage_start_stop" power-management loop to run
#     AFTER disconnect_external_usb_disks() instead of before it. Previously,
#     external USB disks could be granted permission to spin down/power off
#     while their filesystem was still mounted, causing NTFS-3G I/O errors
#     (ntfs_attr_pread_i / Failed to read MFT) as the still-mounted volume
#     tried to read from a disk that was being stopped/disconnected
#     concurrently. Disks are now fully unmounted and deauthorized first;
#     any disk still present afterwards (internal SATA, or a USB disk that
#     failed to disconnect) then goes through manage_start_stop as before.
#     No functionality was removed — USB disks still get manage_start_stop
#     applied if they remain in /sys/class/scsi_disk/* after disconnect.
#
# Changelog 0.83:
#   - Fixed partition-level detection inside disconnect_external_usb_disks().
#     find() correctly locates the "block" directory regardless of nesting
#     depth (e.g. host/target/scsi_device chains for UAS devices), but the
#     loop that walked *inside* that directory only went one level deep,
#     i.e. "$BLOCK_DIR"/*. On devices where the layout is
#     block/sdb/sdb1, block/sdb/sdb2 (partitions nested one level under the
#     whole-disk entry), that produced PART_DEV=/dev/sdb instead of
#     /dev/sdb1, findmnt on /dev/sdb always failed (since /dev/sdb1 was the
#     actually mounted device), and the unmount step was silently skipped —
#     while the device still went on to be deauthorized (authorized=0)
#     below, i.e. disconnected while still mounted. This is the same root
#     cause as the 0.82 fix, just hidden behind a detection bug rather than
#     ordering. The loop now checks whether a block entry has its own
#     partition subdirectories (name matching "<disk>N") and, if so,
#     iterates over those partitions instead of the whole-disk entry; disks
#     with no partition table (the whole disk is directly the filesystem)
#     still fall back to using the whole-disk entry itself.
#
# Changelog 0.84 (code cleanup, no behavior change):
#   - Removed a dead conditional in the pre-suspend "USB wakeup and power
#     management" section (power/control loop) that checked
#     ${STATE[USB_DISK_AUTH_...]} — the STATE associative array is only
#     declared later, in the POST-RESUME section (`declare -A STATE`), so
#     at this point in the script it did not exist yet. Even setting that
#     aside, the check's intent (skip devices already deauthorized this
#     cycle) could never be true at this point anyway, since
#     disconnect_external_usb_disks() — the function that deauthorizes USB
#     disks — runs later in the script, and $STATE_FILE is truncated at the
#     very start of each pre-suspend run, so no prior-cycle data survives
#     to check against either. The condition was therefore always false and
#     the `continue` never executed; removing it changes nothing about what
#     gets saved to $STATE_FILE or restored on resume — it only removes
#     inert code.
#
# Changelog 0.85:
#   - notify_user() and notify_user_critical() now ALWAYS print the message
#     to the console (in addition to logging it), regardless of whether any
#     GUI dialog tool is installed. Previously, if kdialog or zenity was
#     present, the plain-echo fallback was skipped entirely — so running
#     the script from a console with kdialog/zenity installed but no
#     working display produced no visible console output at all.
#   - GUI dialog tools (kdialog, zenity, notify-send, xmessage, yad) are now
#     only attempted when $DISPLAY or $WAYLAND_DISPLAY is actually set,
#     instead of being tried unconditionally. This avoids GUI tools
#     silently failing or hanging when there is no display to show them on.
#   - Added a few more fallbacks: notify-send and xmessage for regular
#     notifications; yad and whiptail for the critical/blocking dialog, in
#     addition to the existing kdialog/zenity/dialog.
#
# Changelog 0.86:
#   - Added a SIGKILL escalation step for processes that still hold a mount
#     point busy after being sent SIGTERM and not exiting in time. Some
#     applications (PDF viewers, media players, etc.) ignore SIGTERM or are
#     slow to exit, which previously meant the unmount — and therefore
#     sleep — would simply fail and require the user to manually close the
#     offending program. SIGKILL is now tried a few seconds before the
#     unmount timeout expires, still explicitly excluding the filesystem's
#     own FUSE driver process (same exclusion as the SIGTERM step). This is
#     safe for the near-universal case of an app that is only reading the
#     file (nothing to flush/lose), and is strictly safer than the
#     alternative of letting the system suspend with the disk still mounted
#     and attached — since suspend cuts USB bus power regardless of mount
#     state, and the disk frequently re-enumerates under a new /dev/sdX
#     name on resume, which is what produces silent corruption / stale
#     mount I/O errors. Killing the blocking application, not the disk, is
#     the safe way to guarantee sleep proceeds.
#   - Increased UNMOUNT_TIMEOUT from 15s to 20s so there is a meaningful gap
#     between the SIGTERM attempt (fired at half the timeout) and the new
#     SIGKILL escalation (fired 3s before the timeout expires), giving
#     well-behaved applications a real window to exit cleanly on their own
#     before being force-killed.
#
# Changelog 0.87:
#   - REVERTED the 0.86 SIGTERM/SIGKILL escalation entirely. Testing showed
#     applications keep working fine after resume even when the disk is
#     forcibly detached out from under an open file handle, so killing
#     them was unnecessary and undesirable — the user explicitly wants
#     blocking applications to be left running, not closed. No process is
#     signalled or killed by disconnect_external_usb_disks() anymore.
#   - The unmount loop now simply cycles through fusermount -u -> umount ->
#     umount -l (lazy) until one succeeds or the timeout is reached, with
#     no attempt to influence what is holding the mount busy.
#   - The post-lazy-unmount release-verification check (added in an earlier
#     revision) is narrowed to check only the filesystem's own driver
#     process (FS_DAEMON_PID, e.g. ntfs-3g) via `kill -0`, instead of
#     checking whether ANY process (via generic fuser on the device) still
#     holds it. Checking for any process was actually wrong for this
#     workflow: an application with an open file handle (e.g. a PDF
#     viewer) will always show up there and would have made the check
#     "stuck" forever, even though that handle is harmless once detached.
#     Only the filesystem driver being cut off mid-writeback was ever the
#     real corruption risk; that is what is now verified before the device
#     is deauthorized.
#   - UNMOUNT_TIMEOUT reverted to 15s, since it no longer needs to
#     accommodate a SIGTERM/SIGKILL escalation window.
#
# Changelog 0.88:
#   - Fixed network-device detection in the post-resume "Rebinding safe USB
#     devices" step. It previously checked "${DEV_PATH}/net" directly under
#     the USB device's own sysfs directory, which only matches a
#     non-composite USB Ethernet adapter. A phone in USB-tethering (RNDIS)
#     mode is a composite USB device, whose "net" directory actually lives
#     one level deeper, under a USB INTERFACE subdirectory (e.g.
#     .../1-4/1-4:1.0/net/usb0). The old check effectively never matched
#     such devices, so they were silently skipped here and never received
#     any post-resume recovery action.
#   - Network devices detected this way are no longer handled with a
#     driver-only unbind/bind. Android's RNDIS tethering session generally
#     does not renegotiate cleanly from a driver rebind alone (the device
#     itself is untouched) — it needs a real USB-level detach/reattach,
#     equivalent to physically unplugging and replugging the device. This
#     is now done via a full authorized=0 -> authorized=1 cycle on the USB
#     device (the same mechanism already used for USB storage disks), after
#     which the script waits briefly for the resulting net interface(s) to
#     reappear and brings them up. This is intended to remove the need to
#     manually toggle USB tethering off/on on the phone after resume; the
#     old driver-rebind path is kept only as a fallback for non-network
#     devices with wakeup=enabled (unrelated to this fix).
#
# Changelog 0.89:
#   - Added automatic re-sleep for a known firmware behavior where plugging in
#     the AC adapter while suspended wakes the system almost immediately.
#     This is not a normal ACPI wakeup event (confirmed not to appear in
#     /proc/acpi/wakeup), so it cannot be filtered out ahead of time the way
#     other wake sources are.
#   - Detection is timestamp-based, not duration-based: total time spent
#     asleep says nothing about whether a given wake was caused by an AC
#     plug-in event (the system could sleep for 30 minutes and still be
#     woken by an AC plug at any point during that time). Instead, the
#     script compares the wall-clock time of the AC adapter's own kernel
#     log event (via `dmesg -T`, resolved regardless of overall uptime) to
#     the time of the wake itself; if they are within SPURIOUS_WAKE_THRESHOLD
#     (5) seconds of each other, the wake is attributed to that event. A
#     secondary short-duration + AC-state-transition fallback check is kept
#     for hardware where the AC driver's dmesg wording doesn't match the
#     expected pattern, but that fallback only catches the narrower case of
#     an almost-instant wake right after entering sleep — it is not a
#     substitute for the timestamp-based check for longer sleeps.
#   - When identified as this behavior, the script goes straight back to sleep
#     on its own instead of falling through to the full (unwanted) resume
#     sequence, capped at MAX_RESLEEP_ATTEMPTS (3) automatic attempts as a
#     safety net so a legitimate wake is never suppressed indefinitely.
#
# Changelog 0.90:
#   - Replaced the dmesg-based AC event timestamp lookup with a companion
#     udev rule (99-ac-adapter-timestamp.rules, installed separately to
#     /etc/udev/rules.d/). Testing confirmed this hardware's AC adapter
#     driver does not print a matching message to dmesg, and the online
#     sysfs attribute's mtime does not update on change either — so neither
#     of the two in-script-only detection methods tried previously could
#     work here. The udev rule reacts to the kernel's own uevent for the
#     "online" attribute changing to 1 and writes the current time to
#     /tmp/ac-online-event-time; being purely reactive to an event the
#     kernel already generated, it does not cause a wakeup or hold the
#     system awake. get_last_ac_event_epoch() now just reads that file.
#   - The event file is deleted (consumed) after being checked, whether or
#     not it matched, so a single real plug-in event can never be
#     mistakenly matched against a later, unrelated wake far in the future.
#   - Requires the udev rule to be installed once (see the rule file's own
#     header for install steps); if it isn't installed, the existing
#     short-duration + AC-state-transition fallback still applies as
#     before, just with its narrower "only catches near-instant wakes"
#     limitation.
#
# Changelog 0.91:
#   - Removed the separate helper script (ac-adapter-timestamp.sh) added in
#     0.90 to work around udev eating a literal "%" in "date +%s". Instead,
#     the udev rule now writes plain `date` output (no format specifier at
#     all, so there is no "%" for udev to mangle), and get_last_ac_event_epoch()
#     converts that plain date string to epoch seconds itself via `date -d`
#     — entirely within the script, where "%" behaves normally. This keeps
#     the AC-timestamp feature to a single extra file (the udev rule) again
#     instead of two.
#
# Changelog 0.92:
#   - Added diagnostic-only rfkill state logging (`rfkill list` output) to
#     the resleep loop, recorded immediately after every wake. This exists
#     to answer, with certainty rather than inference, whether Wi-Fi/
#     Bluetooth radios are actually soft-blocked at each wake during a
#     spurious-AC-wake cycle — a bluetoothd resume message elsewhere in the
#     system log does not by itself confirm or rule out the radio's actual
#     block state. This is read-only: it does not call rfkill block/unblock
#     and does not change any radio's state.
#
# Changelog 0.93 (security-relevant fix):
#   - Fixed a bug in the pre-suspend rfkill blocking step where Wi-Fi and
#     Bluetooth were never actually being soft-blocked before sleep,
#     despite the script appearing to handle this. The regex parsing each
#     `rfkill list` line ("0: hci0: Bluetooth") captures three groups: ID,
#     interface name (hci0), and TYPE (Bluetooth) — but the script was
#     assigning BASH_REMATCH[2] (the interface name) to TYPE instead of
#     BASH_REMATCH[3] (the actual type). The subsequent case match
#     (`wlan|wifi|bluetooth`) was therefore comparing a device name like
#     "hci0" or "wlan0" against those keywords, which can never match,
#     so `rfkill block` was never called. This was discovered via a user
#     security check that logged actual rfkill state (added in 0.92) and
#     found both hci0 (Bluetooth) and the Wi-Fi adapter showing
#     "Soft blocked: no" at every wake, confirming they were never blocked
#     to begin with — unrelated to the AC-wake/resleep feature itself, this
#     bug existed since the original 0.81 script.
#   - Fixed by reading TYPE from BASH_REMATCH[3], and matching it
#     case-insensitively against substrings (real rfkill type strings are
#     capitalized and multi-word, e.g. "Wireless LAN", not the bare
#     lowercase single-word values the old pattern expected).
#   - Added a log line ("Blocking $ID ($TYPE)") when a device is actually
#     blocked, so future runs make it directly visible in the log which
#     devices were blocked, rather than only being inferable from rfkill
#     state.
#
# Changelog 0.94:
#   - Extended AC-related spurious-wake detection to cover unplugging the
#     adapter, not just plugging it in. Testing showed this firmware's
#     near-instant wake behavior can also be triggered by disconnecting the AC
#     adapter while asleep, not only connecting it.
#   - The udev rule (99-ac-adapter-timestamp.rules) now has a second line
#     matching ATTR{online}=="0" in addition to the existing "1" match, so
#     it timestamps the event regardless of direction.
#   - The short-duration fallback heuristic (used when the udev rule hasn't
#     recorded an event) now checks for any AC state transition
#     (`AC_STATE_BEFORE != AC_STATE_AFTER`) instead of only the specific
#     0->1 (plug-in) transition.
#   - Log message wording updated from "AC adapter plug-in event"/
#     "spurious wake from AC adapter plug-in" to the direction-neutral
#     "AC adapter state-change event"/"spurious wake from AC adapter state
#     change", since the cause could now be either direction.
#
# Changelog 0.95:
#   - Added ensure_ac_udev_rule(), called at the start of every pre-suspend
#     run. It checks whether /etc/udev/rules.d/99-ac-adapter-timestamp.rules
#     exists; if so, it's a no-op (single [ -f ] check). If missing, the
#     script writes the rule itself (embedded inline via heredoc — content
#     identical to the standalone 99-ac-adapter-timestamp.rules file),
#     applies normal 644 permissions (a .rules file is read by udevd, not
#     executed, so no chmod +x is needed), and reloads udev rules via
#     `udevadm control --reload-rules`. This makes sleep-unified.sh
#     self-contained for deployment — no separate manual
#     "cp .../99-ac-adapter-timestamp.rules ..." step is required before
#     first use. If not running as root, or if udevadm isn't found, this
#     logs a warning and continues; AC-adapter spurious-wake detection
#     simply falls back to the short-duration heuristic in that case,
#     exactly as it already does whenever the rule/timestamp is unavailable
#     for any other reason.
#
# Changelog 0.96 (public-release readiness pass):
#   - Generalized two illustrative "asus-wlan" examples in comments to the
#     vendor-neutral "wlan0" — these were only example device names used to
#     explain the BASH_REMATCH indexing bug, not anything hardware-specific
#     to the logic itself.
#   - Reworded a log message from "Normal rmdir failed" to "Plain rmdir
#     failed", to avoid any resemblance to a disk label name from testing;
#     purely cosmetic, no behavior change.
#   - Made the release-verification check after a lazy USB-disk unmount
#     filesystem-agnostic. Previously it only recognized named FUSE daemon
#     processes (ntfs-3g, exfat-fuse, mount.ntfs, mount.exfat) — useless for
#     kernel-native filesystems (ext4, btrfs, vfat, the in-kernel ntfs3
#     driver, etc.), which have no separate userspace process to check by
#     name, since the kernel itself does the I/O. Added a second, universal
#     signal alongside the existing named-process check: the block device's
#     own inflight I/O counters (/sys/block/<disk>/inflight, two numbers —
#     reads and writes currently in flight). This applies identically to
#     any filesystem, since it looks at actual pending I/O on the device
#     rather than at who issued it. Either signal reporting "still busy" is
#     enough to treat the unmount as not yet safe to deauthorize past.
#   - Added Wayland support for screen on/off via two new helper functions,
#     screen_off() and screen_on(), replacing the three previous inline
#     "xset dpms" call sites. X11 (xset) is tried first everywhere,
#     unchanged from before, including its ability to save/restore the
#     exact prior monitor on/off state. On Wayland ($WAYLAND_DISPLAY set,
#     no X11), swaymsg, wlopm, and kscreen-doctor are tried in that order,
#     covering sway/wlroots-based compositors and KDE Plasma; if none are
#     found, screen on/off is silently skipped, same fallback behavior
#     as the existing xset-not-found case. There is no portable
#     way to query the prior on/off state across Wayland compositors, so
#     unlike X11, the Wayland resume path always turns the screen back on
#     unconditionally rather than restoring a remembered prior state.
#
# Changelog 0.97:
#   - Added an in-file README section (what this is, how to use it,
#     requirements, portability notes) and a CONFIGURATION section grouping
#     all previously scattered tunable values — STATE_FILE, LOGFILE,
#     STATE_MAXSIZE, LOG_MAXSIZE, SYNC_TIMEOUT, UNMOUNT_TIMEOUT,
#     RELEASE_TIMEOUT, SPURIOUS_WAKE_THRESHOLD, MAX_RESLEEP_ATTEMPTS,
#     AC_EVENT_FILE, AC_UDEV_RULE_PATH — plus a new APP_NAME variable used
#     for desktop-notification/dialog titles (previously the literal string
#     "Sleep Optimizer" was hardcoded in three separate places, inconsistent
#     with the script's actual name).
#   - Rewrote the HOW TO USE section: it previously listed "systemd-sleep
#     hook" as a typical usage alongside direct invocation, which was
#     misleading. This script performs the actual suspend call itself
#     (echo mem > /sys/power/state), so its primary intended use is direct
#     invocation in place of `systemctl suspend` (keybinding, lid-close
#     handler, menu entry, manual run) — NOT as a systemd-sleep hook, since
#     those run around systemd's own suspend call and pairing the two would
#     cause the actual suspend to be attempted twice.
#   - Removed subjective/evaluative wording from comments ("gracefully
#     degrades"/"graceful-degradation", "niche") in favor of neutral,
#     purely functional descriptions, to keep documentation tone factual.
# -----------------------------------------------------------------------------
#
# ==============================================================================
# README
# ==============================================================================
#
# WHAT THIS IS
#   A single self-contained script that prepares a Linux laptop/desktop for
#   suspend (both s2idle and real deep/S3 sleep) and restores everything on
#   resume: CPU governors, rfkill (Wi-Fi/Bluetooth), network interfaces,
#   ACPI wakeup sources, USB wakeup/autosuspend, SATA/USB disk power
#   management, and — most of the actual complexity — safely unmounting and
#   re-mounting external USB storage devices around the sleep cycle so a
#   disk isn't spun down or power-cycled while still mounted (the original
#   motivation for this script: that used to produce filesystem I/O errors).
#
# HOW TO USE
#   This file is the sleep/resume logic itself. It is embedded, at build
#   time, into the compiled "sleep-unified" binary (built from
#   sleep-unified.c) — that binary is the actual thing end users run and
#   distribute: no arguments runs this logic directly (headless), "--gui"
#   opens a GTK settings panel instead. This .sh file can also be run
#   standalone via `bash sleep-unified.sh` for development/testing without
#   rebuilding the binary; its behavior is identical either way.
#
#   Run as root. This IS the suspend mechanism, not a hook that runs around
#   one: it performs pre-suspend prep, the actual suspend call itself
#   (echo mem > /sys/power/state), and the matching post-resume restore,
#   all in one continuous process.
#
#   The primary way to use it is to invoke the compiled binary directly, in
#   place of `systemctl suspend` or a raw `echo mem > /sys/power/state` —
#   for example bound to a keyboard shortcut, a lid-close handler (via
#   acpid), a power-button handler, or a menu entry.
#
#   It is NOT meant to be placed in systemd-sleep's hook directories
#   (/usr/lib/systemd/system-sleep/ or similar) or used alongside other
#   mechanisms that also call `systemctl suspend` — those trigger systemd's
#   own suspend, and pairing that with this would mean the actual suspend
#   call happens twice (once via systemd, once via this), which serves no
#   purpose. Use this as the suspend trigger itself, not as an add-on to a
#   different one.
#
#   One process, one continuous run — it does not exit and get re-invoked
#   separately for the pre/post halves.
#
# REQUIREMENTS
#   bash, standard coreutils, and: findmnt, blkid, udevadm, rfkill, ip,
#   mount/umount, fusermount (for FUSE filesystems). Optional, used only if
#   present (feature is skipped without error if missing): kdialog/zenity/
#   notify-send/xmessage/yad/whiptail/dialog (notifications), xset/swaymsg/
#   wlopm/kscreen-doctor (screen on/off), fuser/lsof (diagnostics).
#
# PORTABILITY NOTES — what's generic vs. what's specific to certain hardware/environments
#   Generic, should work on most Linux systems:
#     - System-disk detection, CPU governors, rfkill, network interfaces,
#       ACPI wakeup source scanning, USB wakeup/autosuspend, USB storage
#       disk unmount/reconnect (including partition detection, lazy-unmount
#       release verification via named FUSE daemons AND the filesystem-
#       agnostic block-device inflight-I/O check).
#   Present but a no-op / silently skipped on systems without the specific
#   thing they check for — never blocks core functionality:
#     - AC-adapter spurious-wake detection (SPURIOUS_WAKE_THRESHOLD /
#       MAX_RESLEEP_ATTEMPTS below): addresses a specific firmware behavior,
#       seen on some laptops, where changing the AC adapter's connection
#       state while asleep wakes the system almost instantly. On hardware
#       without this behavior, the detection logic simply never triggers.
#       Best accuracy requires the companion udev rule (self-installed on
#       first run as root — see ensure_ac_udev_rule() below); without it,
#       a narrower short-sleep-duration fallback heuristic is used instead.
#     - Wayland screen on/off (screen_off/screen_on): tries swaymsg, wlopm,
#       then kscreen-doctor; on a Wayland compositor without any of those,
#       or in a plain console with no display at all, this is skipped.
#     - Desktop notifications: tries several GUI tools when a display is
#       present, plus always logs and echoes to the console regardless.
#
# CONFIGURATION
#   All the tunable values below are grouped in one place — see the
#   CONFIGURATION section immediately following this README for the list
#   and what each one controls.
#
# ==============================================================================

# ==============================================================================
# CONFIGURATION — safe to edit these values; nothing else in the script
# should need to change for normal use. These are the BUILT-IN DEFAULTS.
#
# When run via the compiled "sleep-unified" binary, its --gui settings
# panel does NOT edit this file directly — it reads/writes a small
# external per-user config file (~/.config/Unified_Sleep/config) and
# passes any changed values to this script as environment variables,
# which override the corresponding "NAME=default" assignment below (each
# uses NAME="${NAME:-default}" for exactly this reason — see each
# variable). If no such environment variable is set (e.g. running this
# .sh file directly with plain `bash`, with no config file involved at
# all), the default shown here is used as-is.
# ==============================================================================

# BEGIN GUI-EDITABLE CONFIGURATION

# Display name used in desktop notifications and dialog titles.
APP_NAME="${APP_NAME:-Unified Sleep Mode Optimization Framework}"

# Where the script keeps its state (saved settings to restore on resume)
# and log between the pre-suspend and post-resume halves of a run.
STATE_FILE="${STATE_FILE:-/tmp/sleep-unified.state}"
LOGFILE="${LOGFILE:-/tmp/sleep-unified.log}"

# Both files are trimmed to their last ~200/100 lines once they exceed this
# many bytes, so they don't grow unbounded across many sleep cycles.
STATE_MAXSIZE="${STATE_MAXSIZE:-10240}"
LOG_MAXSIZE="${LOG_MAXSIZE:-10240}"

# How long (seconds) to wait for the initial pre-suspend `sync` to finish
# before giving up and blocking sleep with a diagnostic notification.
SYNC_TIMEOUT="${SYNC_TIMEOUT:-15}"

# How long (seconds) to keep retrying an external USB disk's unmount
# (fusermount -u / umount / umount -l) before giving up on that device and
# blocking sleep entirely (better to block sleep once than risk the disk).
UNMOUNT_TIMEOUT="${UNMOUNT_TIMEOUT:-15}"

# After a lazy unmount (umount -l) succeeds, how long (seconds) to wait for
# confirmation that the disk is actually safe to deauthorize — i.e. that no
# named FUSE driver process is still alive for it AND the block device's
# own inflight-I/O counters have reached zero. See the comments inside
# disconnect_external_usb_disks() for why this check exists.
RELEASE_TIMEOUT="${RELEASE_TIMEOUT:-10}"

# AC-adapter spurious-wake handling (see the README section above for what
# this addresses). SPURIOUS_WAKE_THRESHOLD is how close (seconds) an AC
# adapter state-change event and a wake need to be to each other to be
# treated as cause-and-effect. MAX_RESLEEP_ATTEMPTS caps how many times the
# script will automatically go back to sleep in a row for this reason, so a
# genuinely intended wake is never suppressed indefinitely.
SPURIOUS_WAKE_THRESHOLD="${SPURIOUS_WAKE_THRESHOLD:-5}"
MAX_RESLEEP_ATTEMPTS="${MAX_RESLEEP_ATTEMPTS:-3}"

# Where the companion udev rule records AC-adapter state-change timestamps,
# and where that udev rule itself lives. See ensure_ac_udev_rule() and
# get_last_ac_event_epoch() below.
AC_EVENT_FILE="${AC_EVENT_FILE:-/tmp/ac-online-event-time}"
AC_UDEV_RULE_PATH="${AC_UDEV_RULE_PATH:-/etc/udev/rules.d/99-ac-adapter-timestamp.rules}"

# --- Stage toggles ---
# Each of these enables/disables one independent piece of the pre-suspend/
# post-resume pipeline. All default to enabled (1); set to 0 to skip a
# stage entirely (both its pre-suspend action and its matching post-resume
# restore are skipped together, as a pair). Every stage was already
# individually optional in practice (each checks for the tools/hardware it
# needs and no-ops if absent) — these toggles just make that an explicit,
# deliberate choice instead of an implicit one.
ENABLE_CPU_GOVERNORS="${ENABLE_CPU_GOVERNORS:-1}"          # Switch CPUs to powersave before sleep, restore after
ENABLE_RFKILL="${ENABLE_RFKILL:-1}"                 # Block Wi-Fi/Bluetooth before sleep, restore after
ENABLE_NETWORK_INTERFACES="${ENABLE_NETWORK_INTERFACES:-1}"     # Bring network interfaces down before sleep, restore after
ENABLE_USB_WAKEUP_POWER="${ENABLE_USB_WAKEUP_POWER:-1}"       # Tune per-device USB wakeup/autosuspend before sleep, restore after
ENABLE_USB_DISK_SAFE_UNMOUNT="${ENABLE_USB_DISK_SAFE_UNMOUNT:-1}"  # Safely unmount/deauthorize USB disks before sleep, remount after
ENABLE_SATA_POWER_MANAGEMENT="${ENABLE_SATA_POWER_MANAGEMENT:-1}"  # SATA/SCSI manage_start_stop power management
ENABLE_TOUCHPAD_RESTORE="${ENABLE_TOUCHPAD_RESTORE:-1}"       # Save/restore touchpad enabled state (AC-WMI phantom-toggle workaround)
ENABLE_AC_SPURIOUS_WAKE="${ENABLE_AC_SPURIOUS_WAKE:-1}"       # Detect the AC-adapter spurious-wake firmware behavior and auto re-sleep
ENABLE_SCREEN_DPMS="${ENABLE_SCREEN_DPMS:-1}"            # Turn the screen off before sleep, back on after (X11/Wayland)
ENABLE_ACPI_WAKEUP_PRUNING="${ENABLE_ACPI_WAKEUP_PRUNING:-1}"    # Disable non-essential ACPI wakeup sources before sleep

# END GUI-EDITABLE CONFIGURATION

# --- Load per-user config overrides, if any ---
# The GUI (sleep-unified --gui) writes any changed values here rather than
# editing this file's own embedded defaults, since a compiled binary can't
# safely rewrite its own embedded strings. If this file doesn't exist, the
# defaults above are used as-is — the script is fully functional without
# it. Resolved per invoking USER, not per root, so that running the actual
# sleep cycle via sudo/pkexec (which needs root) still picks up the same
# config a normal user saved through the GUI (which does not need root
# just to edit settings): prefer $SUDO_USER's home directory if set, since
# that's the real user behind a sudo invocation, falling back to the
# current $HOME otherwise.
CONFIG_REAL_USER="${SUDO_USER:-$USER}"
CONFIG_REAL_HOME=$(getent passwd "$CONFIG_REAL_USER" 2>/dev/null | cut -d: -f6)
[ -z "$CONFIG_REAL_HOME" ] && CONFIG_REAL_HOME="$HOME"
CONFIG_DIR="${CONFIG_REAL_HOME}/.config/Unified_Sleep"
CONFIG_FILE="${CONFIG_DIR}/config"
# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# === Notify user ===
# Always echoes to the console/log first, then additionally tries a GUI
# popup if one is available AND a display is actually present. This way,
# running the script from a plain console (no X session, no $DISPLAY) will
# always show the message right there, instead of silently attempting a
# GUI dialog that has nowhere to appear.
notify_user() {
    local MSG="$1"
    echo "$MSG" >> "$LOGFILE"
    echo "$MSG"

    [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && return

    if command -v kdialog >/dev/null 2>&1; then
        kdialog --passivepopup "$MSG" 3
    elif command -v zenity >/dev/null 2>&1; then
        zenity --notification --text="$MSG"
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "$APP_NAME" "$MSG"
    elif command -v xmessage >/dev/null 2>&1; then
        xmessage -timeout 5 "$MSG" 2>/dev/null &
    fi
}

notify_user_critical() {
    local MSG="$1"
    echo "$MSG" >> "$LOGFILE"
    echo "$MSG"

    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
        if command -v kdialog >/dev/null 2>&1; then
            kdialog --title "Sleep Blocked" --msgbox "$MSG"
            return
        fi

        if command -v zenity >/dev/null 2>&1; then
            zenity --info --width=450 --height=300 --text="$MSG"
            return
        fi

        if command -v yad >/dev/null 2>&1; then
            yad --title "Sleep Blocked" --text="$MSG" --button=OK:0
            return
        fi

        if command -v xmessage >/dev/null 2>&1; then
            xmessage -center "$MSG" 2>/dev/null
            return
        fi
    fi

    if command -v whiptail >/dev/null 2>&1 && [ -t 1 ]; then
        local TMP="/tmp/sleep_block_msg_$$.txt"
        printf "%s\n" "$MSG" > "$TMP"
        whiptail --backtitle "$APP_NAME" \
                 --title "Sleep Blocked" \
                 --textbox "$TMP" 20 80
        rm -f "$TMP"
        return
    fi

    if command -v dialog >/dev/null 2>&1 && [ -t 1 ]; then
        local TMP="/tmp/sleep_block_msg_$$.txt"
        printf "%s\n" "$MSG" > "$TMP"
        dialog --backtitle "$APP_NAME" \
               --title "Sleep Blocked" \
               --textbox "$TMP" 20 80
        rm -f "$TMP"
        return
    fi

    # No GUI available (or no display) and no interactive full-screen text
    # tool — the plain echo above already put the message on the console
    # and in the log, so there is nothing further to do here.
}

# === Wait for sync with timeout ===
wait_sync() {
    local SYNC_PID
    local waited=0

    ( sync ) &
    SYNC_PID=$!

    while kill -0 "$SYNC_PID" 2>/dev/null; do
        if [ "$waited" -ge "$SYNC_TIMEOUT" ]; then
            local info=""
            if command -v lsof >/dev/null 2>&1; then
                info="$(lsof +D /run/media 2>/dev/null || true)"
                info="$info\n$(lsof +D /media 2>/dev/null || true)"
                info="$info\n$(lsof +D /mnt 2>/dev/null || true)"
                info="$info\n$(lsof /dev/sd* 2>/dev/null | head -n 50 || true)"
            fi

            if [ -z "$info" ] && command -v fuser >/dev/null 2>&1; then
                info="$(fuser -m /run/media 2>/dev/null || true)"
                info="$info\n$(fuser -m /media 2>/dev/null || true)"
                info="$info\n$(fuser -m /mnt 2>/dev/null || true)"
            fi

            if [ -z "$info" ]; then
                info="$(awk 'NR>0 {print}' /proc/diskstats 2>/dev/null | tail -n 20 || true)"
            fi

            if [ -n "$info" ]; then
                local summary
                summary="$(printf '%s' "$info" | sed -n '1,60p')"
                notify_user_critical "Error: sync did not complete within ${SYNC_TIMEOUT}s. Sleep blocked — possible blocking processes/files:\n$summary"
            else
                notify_user_critical "Error: sync did not complete within ${SYNC_TIMEOUT}s. Sleep blocked (no blocking process information found)."
            fi

            kill -9 "$SYNC_PID" 2>/dev/null || true
            wait "$SYNC_PID" 2>/dev/null || true
            exit 1
        fi

        sleep 1
        waited=$((waited + 1))
    done

    wait "$SYNC_PID" 2>/dev/null
    local EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
        notify_user "Error: sync failed unexpectedly (exit code ${EXIT_CODE}). Sleep blocked."
        exit 1
    fi
}

# === Turn the screen off (X11 or Wayland, best-effort) ===
# X11 uses xset dpms, which also lets the resume path query and restore the
# exact prior state ("was the monitor on or off before sleep"). There is no
# single universal equivalent on Wayland — DPMS control is compositor-
# specific — so this tries a few common tools in order and does nothing if
# none are found, the same fallback behavior already used for
# xset itself. Unlike X11, the Wayland path here does not attempt to query
# or remember the prior on/off state (no portable way to do so across
# compositors); screen_on() below always forces the display back on
# instead, which matches the expected behavior of a normal resume.
screen_off() {
    if command -v xset >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        xset dpms force off 2>/dev/null
        return
    fi

    [ -z "$WAYLAND_DISPLAY" ] && return

    if command -v swaymsg >/dev/null 2>&1; then
        swaymsg 'output * dpms off' >/dev/null 2>&1 && return
    fi
    if command -v wlopm >/dev/null 2>&1; then
        wlopm --off '*' >/dev/null 2>&1 && return
    fi
    if command -v kscreen-doctor >/dev/null 2>&1; then
        kscreen-doctor --dpms off >/dev/null 2>&1 && return
    fi
}

# === Turn the screen on (X11 or Wayland, best-effort) ===
screen_on() {
    if command -v xset >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        xset dpms force on 2>/dev/null
        return
    fi

    [ -z "$WAYLAND_DISPLAY" ] && return

    if command -v swaymsg >/dev/null 2>&1; then
        swaymsg 'output * dpms on' >/dev/null 2>&1 && return
    fi
    if command -v wlopm >/dev/null 2>&1; then
        wlopm --on '*' >/dev/null 2>&1 && return
    fi
    if command -v kscreen-doctor >/dev/null 2>&1; then
        kscreen-doctor --dpms on >/dev/null 2>&1 && return
    fi
}

# === Find the touchpad's xinput device id ===
# Same logic as acpi/actions/touchpad-toggle.sh: some evdev-based touchpads
# expose two xinput devices sharing the same name prefix — an absolute-axis
# "...Touchpad" entry and a relative-axis "...Mouse" entry that actually
# drives the cursor. Toggling "Device Enabled" only has a visible effect on
# whichever of the two is the real pointer device, so this resolves the
# sibling "Mouse" device by name prefix first, falling back to the
# "Touchpad" device itself if no such sibling exists.
get_touchpad_xinput_id() {
    command -v xinput >/dev/null 2>&1 || return 1
    [ -n "$DISPLAY" ] || return 1

    local TOUCHPAD_LINE PREFIX ID
    TOUCHPAD_LINE=$(xinput list 2>/dev/null | grep -i "touchpad" | head -n1)
    [ -z "$TOUCHPAD_LINE" ] && return 1

    PREFIX=$(echo "$TOUCHPAD_LINE" | sed -E 's/^[^A-Za-z0-9]*//; s/[[:space:]]*Touchpad.*$//')

    ID=""
    if [ -n "$PREFIX" ]; then
        ID=$(xinput list 2>/dev/null | grep -F "$PREFIX" | grep -i "mouse" | grep -oP 'id=\K[0-9]+' | head -n1)
    fi
    if [ -z "$ID" ]; then
        ID=$(echo "$TOUCHPAD_LINE" | grep -oP 'id=\K[0-9]+')
    fi
    [ -z "$ID" ] && return 1

    echo "$ID"
}

# === Save touchpad enabled/disabled state before suspend ===
# xinput device ids are resolved by name at save time and again at restore
# time (via get_touchpad_xinput_id), so this does not depend on the id
# staying numerically stable across the sleep cycle — only the device name
# needs to stay the same.
save_touchpad_state() {
    local ID STATE
    ID=$(get_touchpad_xinput_id) || { echo "Touchpad: no xinput device found, skipping state save" >> "$LOGFILE"; return; }

    STATE=$(xinput list-props "$ID" 2>/dev/null | grep "Device Enabled" | grep -oP '[0-9]+$')
    [ -z "$STATE" ] && { echo "Touchpad: could not read Device Enabled for id $ID" >> "$LOGFILE"; return; }

    echo "TOUCHPAD_ENABLED=${STATE}" >> "$STATE_FILE"
    echo "Touchpad state saved: id=$ID enabled=$STATE" >> "$LOGFILE"
}

# === Restore touchpad enabled/disabled state after resume ===
# The firmware sends the same WMI code used for Fn+F6 on AC adapter
# plug/unplug events, and acpid (netlink event delivery) is frozen during
# sleep, so a phantom toggle from an AC event during sleep can leave the
# touchpad in the wrong state after resume, with no acpid-side timing
# window left to catch and revert it (see touchpad-toggle.sh for the
# in-session version of this same race). Restoring explicitly here does not
# depend on that timing at all — it just forces the saved state back.
# Runs twice: once immediately, and once more ~3s later in the background,
# in case a phantom WMI event from AC arrives with a short delay after
# resume completes and flips the toggle again.
restore_touchpad_state() {
    local VALUE="${STATE[TOUCHPAD_ENABLED]:-}"
    [ -z "$VALUE" ] && return

    local ID
    ID=$(get_touchpad_xinput_id) || { echo "Touchpad: no xinput device found, skipping state restore" >> "$LOGFILE"; return; }

    if [ "$VALUE" = "1" ]; then
        xinput enable "$ID" 2>/dev/null
    else
        xinput disable "$ID" 2>/dev/null
    fi
    echo "Touchpad state restored: id=$ID enabled=$VALUE" >> "$LOGFILE"

    (
        sleep 3
        local ID2
        ID2=$(get_touchpad_xinput_id) || exit 0
        if [ "$VALUE" = "1" ]; then
            xinput enable "$ID2" 2>/dev/null
        else
            xinput disable "$ID2" 2>/dev/null
        fi
        echo "Touchpad state re-asserted after delay: id=$ID2 enabled=$VALUE" >> "$LOGFILE"
    ) &
}

# === Truncate state file ===
truncate_state_file() {
    if [ -f "$STATE_FILE" ] && [ "$(stat -c%s "$STATE_FILE")" -gt "$STATE_MAXSIZE" ]; then
        tail -n 200 "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
}

# === Force cleanup directory (unmount + remove) ===
force_cleanup_dir() {
    local DIR="$1"
    local MAX_ATTEMPTS=3
    local ATTEMPT=0

    while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
        if [ ! -d "$DIR" ]; then
            return 0
        fi

        if [ ! -z "$(ls -A "$DIR" 2>/dev/null)" ]; then
            return 1
        fi

        if ! mountpoint -q "$DIR" 2>/dev/null; then
            rmdir "$DIR" 2>/dev/null && return 0
        fi

        if command -v fusermount >/dev/null 2>&1; then
            fusermount -uz "$DIR" 2>/dev/null
        fi
        umount -l "$DIR" 2>/dev/null

        sleep 0.5
        ATTEMPT=$((ATTEMPT + 1))
    done

    [ -d "$DIR" ] && [ -z "$(ls -A "$DIR" 2>/dev/null)" ] && ! mountpoint -q "$DIR" 2>/dev/null && rmdir "$DIR" 2>/dev/null
    [ ! -d "$DIR" ] && return 0 || return 1
}

# === Cleanup empty mount point directories ===
cleanup_empty_mount_dirs() {
    local CLEANED=0

    for MEDIA_DIR in /media /run/media/$USER /run/media/*; do
        [ -d "$MEDIA_DIR" ] || continue

        for DIR in "$MEDIA_DIR"/*; do
            [ -d "$DIR" ] || continue

            local BASENAME=$(basename "$DIR")
            if ! [[ "$BASENAME" =~ _+$ || "$BASENAME" =~ _[0-9]+(_[0-9]+)*$ ]]; then
                continue
            fi

            if force_cleanup_dir "$DIR"; then
                CLEANED=$((CLEANED + 1))
            fi
        done
    done

    [ "$CLEANED" -gt 0 ] && echo "Cleaned $CLEANED empty directories" >> "$LOGFILE"
}

# ============================================================================
# PRE-SUSPEND FUNCTIONS (called before sleep)
# ============================================================================

# === Identify system disks ===
get_system_disk_ids() {
    local SYSTEM_IDS=""

    local ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null)
    if [ -n "$ROOT_DEV" ]; then
        local ROOT_BASE=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
        local ROOT_SYS=$(udevadm info -q path -n "$ROOT_BASE" 2>/dev/null || true)
        if [ -n "$ROOT_SYS" ]; then
            local ROOT_USB=$(echo "$ROOT_SYS" | grep -oP 'usb[0-9]+/\K[^/]+' | head -n1 || true)
            [ -n "$ROOT_USB" ] && SYSTEM_IDS="${SYSTEM_IDS} ${ROOT_USB}"
        fi
    fi

    for BOOT_MNT in /boot /boot/efi /efi; do
        [ -d "$BOOT_MNT" ] || continue
        local BOOT_DEV=$(findmnt -n -o SOURCE "$BOOT_MNT" 2>/dev/null || true)
        [ -z "$BOOT_DEV" ] && continue
        local BOOT_BASE=$(echo "$BOOT_DEV" | sed 's/[0-9]*$//')
        local BOOT_SYS=$(udevadm info -q path -n "$BOOT_BASE" 2>/dev/null || true)
        if [ -n "$BOOT_SYS" ]; then
            local BOOT_USB=$(echo "$BOOT_SYS" | grep -oP 'usb[0-9]+/\K[^/]+' | head -n1 || true)
            [ -n "$BOOT_USB" ] && SYSTEM_IDS="${SYSTEM_IDS} ${BOOT_USB}"
        fi
    done

    while read -r SWAP_DEV _; do
        case "$SWAP_DEV" in
            /dev/*) ;;
            *) continue ;;
        esac
        local SWAP_BASE=$(echo "$SWAP_DEV" | sed 's/[0-9]*$//')
        local SWAP_SYS=$(udevadm info -q path -n "$SWAP_BASE" 2>/dev/null || true)
        if [ -n "$SWAP_SYS" ]; then
            local SWAP_USB=$(echo "$SWAP_SYS" | grep -oP 'usb[0-9]+/\K[^/]+' | head -n1 || true)
            [ -n "$SWAP_USB" ] && SYSTEM_IDS="${SYSTEM_IDS} ${SWAP_USB}"
        fi
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

    echo $SYSTEM_IDS | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' '
}

# === Get USB ID from block device ===
get_usb_id_from_block() {
    local BLOCK_DEV="$1"
    local SYS_PATH=$(udevadm info -q path -n "$BLOCK_DEV" 2>/dev/null || true)
    if [ -n "$SYS_PATH" ]; then
        echo "$SYS_PATH" | grep -oP 'usb[0-9]+/\K[^/]+' | head -n1 || true
    fi
}

# === Save mount points for USB storage devices ===
save_usb_disk_mounts() {
    local SYSTEM_IDS="$1"
    echo "Saving mount points for USB storage devices..." >> "$LOGFILE"

    while read -r SOURCE TARGET FSTYPE OPTIONS; do
        case "$SOURCE" in
            /dev/*) ;;
            *) continue ;;
        esac

        local BASE_DEV=$(echo "$SOURCE" | sed 's/[0-9]*$//')
        local USB_ID=$(get_usb_id_from_block "$BASE_DEV")
        [ -z "$USB_ID" ] && continue

        local IS_SYSTEM=0
        for SYS_ID in $SYSTEM_IDS; do
            [[ "$USB_ID" == "$SYS_ID" ]] && { IS_SYSTEM=1; break; }
        done
        [ "$IS_SYSTEM" -eq 1 ] && continue

        local PART_UUID=$(blkid -s UUID -o value "$SOURCE" 2>/dev/null || true)

        if [ -n "$PART_UUID" ]; then
            echo "USB_MOUNT_${USB_ID}_UUID_${PART_UUID}_TARGET=${TARGET}" >> "$STATE_FILE"
            echo "USB_MOUNT_${USB_ID}_UUID_${PART_UUID}_FSTYPE=${FSTYPE}" >> "$STATE_FILE"
            echo "USB_MOUNT_${USB_ID}_UUID_${PART_UUID}_OPTIONS=${OPTIONS}" >> "$STATE_FILE"
            echo "Saved mount: $SOURCE (UUID=$PART_UUID) -> $TARGET ($FSTYPE)" >> "$LOGFILE"
        else
            echo "WARNING: Could not get UUID for $SOURCE, skipping" >> "$LOGFILE"
        fi
    done < <(findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true)
}

# === Unmount and disconnect USB storage devices ===
disconnect_external_usb_disks() {
    local SYSTEM_IDS="$1"
    # UNMOUNT_TIMEOUT is a global, set in the CONFIGURATION section.
    echo "System USB IDs (will NOT disconnect): $SYSTEM_IDS" >> "$LOGFILE"

    local DISCONNECTED_COUNT=0
    local FAILED_DEVICES=""

    for USB_DEV in /sys/bus/usb/devices/*/; do
        [ -d "$USB_DEV" ] || continue

        local DEV_ID=$(basename "$USB_DEV")

        if [[ "$DEV_ID" =~ ^usb[0-9]+$ ]]; then
            continue
        fi

        local IS_SYSTEM=0
        for SYS_ID in $SYSTEM_IDS; do
            if [[ "$DEV_ID" == "$SYS_ID" ]]; then
                IS_SYSTEM=1
                break
            fi
        done

        if [ "$IS_SYSTEM" -eq 1 ]; then
            echo "Skipping system device: $DEV_ID" >> "$LOGFILE"
            continue
        fi

        local HAS_BLOCK=0

        if ls -d "${USB_DEV}"*/block 2>/dev/null | grep -q .; then
            HAS_BLOCK=1
        fi

        if [ "$HAS_BLOCK" -eq 0 ]; then
            local DEV_CLASS=$(cat "${USB_DEV}bDeviceClass" 2>/dev/null || echo "00")
            if [ "$DEV_CLASS" = "00" ]; then
                for INTF in "${USB_DEV}"*/bInterfaceClass; do
                    [ -f "$INTF" ] || continue
                    local INTF_CLASS=$(cat "$INTF" 2>/dev/null)
                    if [ "$INTF_CLASS" = "08" ]; then
                        HAS_BLOCK=1
                        break
                    fi
                done
            elif [ "$DEV_CLASS" = "08" ]; then
                HAS_BLOCK=1
            fi
        fi

        if [ "$HAS_BLOCK" -eq 0 ]; then
            continue
        fi

        echo "Processing USB storage device: $DEV_ID" >> "$LOGFILE"

        local ALL_UNMOUNTED=1
        # NOTE: block/ is NOT always two levels down from USB_DEV. For
        # UAS/usb-storage devices it typically sits under a host/target/
        # scsi_device chain, e.g.:
        #   2-2/2-2:1.0/host1/target1:0:0/1:0:0:0/block/sdb
        # find (without -L) locates that "block" directory regardless of
        # depth, avoiding the earlier fixed "*/block/*" glob that silently
        # found nothing on such devices.
        #
        # Inside that "block" directory, entries are whole-disk device
        # names (e.g. "sdb"), and on partitioned disks the *partitions*
        # (sdb1, sdb2, ...) are nested one level further down, e.g.:
        #   block/sdb/sdb1
        #   block/sdb/sdb2
        # rather than being siblings of "sdb" directly under "block/". The
        # loop below therefore checks each block entry for partition
        # subdirectories matching "<diskname><number>" and, if found,
        # iterates over those partitions (the actually-mounted devices).
        # If no such subdirectories exist (unpartitioned disk, filesystem
        # directly on the whole disk), it falls back to using the
        # whole-disk entry itself.
        while IFS= read -r BLOCK_DIR; do
            [ -d "$BLOCK_DIR" ] || continue
            for BLOCK_PATH in "$BLOCK_DIR"/*; do
            [ -d "$BLOCK_PATH" ] || continue

            local DISK_NAME
            DISK_NAME=$(basename "$BLOCK_PATH")

            local PART_DEVS=()
            for SUBPATH in "$BLOCK_PATH"/*; do
                [ -d "$SUBPATH" ] || continue
                local SUBNAME
                SUBNAME=$(basename "$SUBPATH")
                if [[ "$SUBNAME" =~ ^${DISK_NAME}[0-9]+$ ]]; then
                    PART_DEVS+=("/dev/$SUBNAME")
                fi
            done

            if [ "${#PART_DEVS[@]}" -eq 0 ]; then
                # No partitions found — treat the whole disk as the device
                # (e.g. unpartitioned disk with a filesystem directly on it).
                PART_DEVS=("/dev/$DISK_NAME")
            fi

            for PART_DEV in "${PART_DEVS[@]}"; do

            if ! findmnt -n "$PART_DEV" >/dev/null 2>&1; then
                continue
            fi

            local MOUNT_POINT=$(findmnt -n -o TARGET "$PART_DEV" 2>/dev/null)
            echo "Unmounting $PART_DEV (mounted at: $MOUNT_POINT)..." >> "$LOGFILE"

            sync
            sleep 0.3

            # Identify the PID of the filesystem's OWN driver/FUSE server
            # process for this mount (e.g. ntfs-3g). This is used ONLY to
            # verify, after a lazy unmount, that the driver has actually
            # released the underlying block device before it gets
            # deauthorized (see the release-verification check below) — no
            # process, including this one, is ever killed by this function.
            #
            # This name list only helps for FUSE-based filesystems, where a
            # separate userspace process does the actual I/O and can still
            # be mid-flush after the kernel-level unmount returns. Kernel-
            # native filesystems (ext4, btrfs, vfat, the in-kernel ntfs3
            # driver, etc.) have no such separate process — the kernel
            # itself is the "driver" — so this check alone would silently
            # do nothing useful for them. That gap is covered by the
            # filesystem-agnostic inflight-I/O check further below, which
            # looks at the block device itself rather than any process
            # name, and applies to every filesystem type identically.
            local FS_DAEMON_PID=""
            FS_DAEMON_PID=$(ps -eo pid,args 2>/dev/null | grep -E "(ntfs-3g|mount\.ntfs|exfat-fuse|mount\.exfat)[^|]*\b${PART_DEV//\//\\/}\b" | grep -v grep | awk '{print $1}' | head -n1)

            local UNMOUNT_SUCCESS=0
            local LAZY_UNMOUNT_USED=0
            local WAIT_TIME=0

            # No process on the mount point is ever signalled/killed here.
            # Applications with an open file handle (e.g. a PDF viewer) are
            # left completely alone — testing confirmed they keep working
            # fine after resume even once the disk has been forcibly
            # detached out from under them. The only thing that actually
            # risked data loss was interrupting the FILESYSTEM'S OWN I/O
            # engine (a FUSE driver, or the kernel's writeback for a
            # native filesystem) mid-flush, which is a separate concern
            # handled below, not by killing anyone.
            while [ "$WAIT_TIME" -lt "$UNMOUNT_TIMEOUT" ]; do
                if command -v fusermount >/dev/null 2>&1; then
                    if fusermount -u "$MOUNT_POINT" 2>/dev/null; then
                        sleep 0.3
                        if ! findmnt -n "$PART_DEV" >/dev/null 2>&1; then
                            echo "FUSE unmount successful for $PART_DEV" >> "$LOGFILE"
                            UNMOUNT_SUCCESS=1
                            break
                        fi
                    fi
                fi

                if umount "$PART_DEV" 2>/dev/null; then
                    sync
                    sleep 0.3
                    if ! findmnt -n "$PART_DEV" >/dev/null 2>&1 && ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
                        echo "Successfully unmounted $PART_DEV" >> "$LOGFILE"
                        UNMOUNT_SUCCESS=1
                        break
                    fi
                fi

                if umount -l "$PART_DEV" 2>/dev/null; then
                    sleep 1
                    if ! findmnt -n "$PART_DEV" >/dev/null 2>&1; then
                        echo "Lazy unmount successful for $PART_DEV" >> "$LOGFILE"
                        UNMOUNT_SUCCESS=1
                        LAZY_UNMOUNT_USED=1
                        break
                    fi
                fi

                sleep 1
                WAIT_TIME=$((WAIT_TIME + 1))
            done

            # A lazy unmount (umount -l) only detaches the mount point from
            # the namespace immediately — it does NOT guarantee that all
            # data has actually been written to the physical device yet.
            # If the device is deauthorized (authorized=0) while writeback
            # is still pending, whatever is doing that writeback can get
            # "Input/output error" on its next write, since the USB device
            # disappears out from under it — this is the one scenario that
            # actually risks the data on the disk.
            #
            # Ordinary applications that still have an open file handle
            # (e.g. a PDF viewer) are NOT checked here and are never
            # signalled — once the mount is detached, their handle simply
            # goes stale; they keep running and work fine after resume.
            # Two independent, filesystem-agnostic signals are checked
            # instead:
            #   1. A named FUSE driver process (FS_DAEMON_PID above), if one
            #      was found for this device — covers ntfs-3g/exfat-fuse.
            #   2. The block device's own inflight I/O counters
            #      (/sys/block/<disk>/inflight) — covers ANY filesystem,
            #      including kernel-native ones (ext4, btrfs, vfat, kernel
            #      ntfs3, etc.) that have no separate process to check by
            #      name, since this looks at actual pending reads/writes on
            #      the device itself rather than at who issued them.
            # Either signal reporting "still busy" is enough to treat the
            # unmount as not yet safe to proceed past.
            if [ "$UNMOUNT_SUCCESS" -eq 1 ] && [ "$LAZY_UNMOUNT_USED" -eq 1 ]; then
                sync

                local BASE_DISK
                BASE_DISK=$(basename "$PART_DEV" | sed 's/[0-9]*$//')
                local INFLIGHT_PATH="/sys/block/${BASE_DISK}/inflight"

                echo "Verifying device release after lazy unmount of $PART_DEV (daemon PID: ${FS_DAEMON_PID:-none}, inflight path: ${INFLIGHT_PATH})..." >> "$LOGFILE"

                local RELEASE_WAIT=0
                # RELEASE_TIMEOUT is a global, set in the CONFIGURATION section.
                local STILL_BUSY=1

                while [ "$RELEASE_WAIT" -lt "$RELEASE_TIMEOUT" ]; do
                    STILL_BUSY=0

                    if [ -n "$FS_DAEMON_PID" ] && kill -0 "$FS_DAEMON_PID" 2>/dev/null; then
                        STILL_BUSY=1
                    fi

                    if [ "$STILL_BUSY" -eq 0 ] && [ -f "$INFLIGHT_PATH" ]; then
                        # Format is two whitespace-separated numbers: reads
                        # in flight, writes in flight. Anything nonzero
                        # means the block device still has pending I/O.
                        local INFLIGHT_VALS
                        INFLIGHT_VALS=$(cat "$INFLIGHT_PATH" 2>/dev/null)
                        if [ -n "$INFLIGHT_VALS" ] && ! echo "$INFLIGHT_VALS" | grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]*$'; then
                            STILL_BUSY=1
                        fi
                    fi

                    [ "$STILL_BUSY" -eq 0 ] && break

                    sleep 1
                    RELEASE_WAIT=$((RELEASE_WAIT + 1))
                done

                if [ "$STILL_BUSY" -eq 1 ]; then
                    echo "WARNING: $PART_DEV still shows pending I/O or an active driver process ${RELEASE_TIMEOUT}s after lazy unmount, treating as unmount failure" >> "$LOGFILE"
                    UNMOUNT_SUCCESS=0
                else
                    echo "Device $PART_DEV released after ${RELEASE_WAIT}s (no pending I/O, no active named driver process)" >> "$LOGFILE"
                fi
            fi

            if [ "$UNMOUNT_SUCCESS" -eq 0 ]; then
                echo "ERROR: Failed to unmount $PART_DEV after ${UNMOUNT_TIMEOUT}s" >> "$LOGFILE"
                ALL_UNMOUNTED=0
                FAILED_DEVICES="${FAILED_DEVICES}${PART_DEV} (${DEV_ID})\n"
            else
                sync
                sleep 0.5

                if [ -d "$MOUNT_POINT" ]; then
                    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
                        echo "WARNING: $MOUNT_POINT still mounted after umount, forcing lazy unmount" >> "$LOGFILE"
                        umount -l "$MOUNT_POINT" 2>/dev/null || true
                        sleep 0.5
                    fi

                    if [ -z "$(ls -A "$MOUNT_POINT" 2>/dev/null)" ]; then
                        if ! rmdir "$MOUNT_POINT" 2>/dev/null; then
                            echo "Plain rmdir failed, trying lazy unmount + fusermount" >> "$LOGFILE"

                            if command -v fusermount >/dev/null 2>&1; then
                                fusermount -uz "$MOUNT_POINT" 2>/dev/null || true
                            fi

                            umount -l "$MOUNT_POINT" 2>/dev/null || true
                            sleep 0.5

                            if rmdir "$MOUNT_POINT" 2>/dev/null; then
                                echo "Successfully removed $MOUNT_POINT after cleanup" >> "$LOGFILE"
                            else
                                echo "WARNING: Could not remove $MOUNT_POINT - will remain as empty directory" >> "$LOGFILE"
                            fi
                        else
                            echo "Successfully removed empty mount point: $MOUNT_POINT" >> "$LOGFILE"
                        fi
                    fi
                fi
            fi
            done
            done
        done < <(find "$USB_DEV" -maxdepth 8 -type d -name block 2>/dev/null)

        if [ "$ALL_UNMOUNTED" -eq 1 ]; then
            sync
            sleep 1

            local AUTHORIZED="${USB_DEV}authorized"
            if [ -f "$AUTHORIZED" ]; then
                local WAS_AUTH=$(cat "$AUTHORIZED" 2>/dev/null || echo "1")
                echo "USB_DISK_AUTH_${DEV_ID}=${WAS_AUTH}" >> "$STATE_FILE"

                echo "Disconnecting USB storage device: $DEV_ID" >> "$LOGFILE"
                echo 0 > "$AUTHORIZED" 2>/dev/null || true
                DISCONNECTED_COUNT=$((DISCONNECTED_COUNT + 1))
            fi
        else
            echo "WARNING: Skipping disconnect of $DEV_ID due to unmount failures" >> "$LOGFILE"
        fi
    done

    echo "Total USB storage devices disconnected: $DISCONNECTED_COUNT" >> "$LOGFILE"

    if [ -n "$FAILED_DEVICES" ]; then
        notify_user_critical "Error: Cannot enter sleep mode - failed to unmount the following devices:\n${FAILED_DEVICES}\nPlease close all applications using these devices and try again."
        exit 1
    fi
}

# === Get AC adapter online state (1 = plugged in, 0 = not) ===
get_ac_online() {
    local ONLINE=0
    for PS in /sys/class/power_supply/*/online; do
        [ -f "$PS" ] || continue
        local PS_DIR
        PS_DIR=$(dirname "$PS")
        local TYPE
        TYPE=$(cat "${PS_DIR}/type" 2>/dev/null)
        [ "$TYPE" = "Battery" ] && continue
        local VAL
        VAL=$(cat "$PS" 2>/dev/null)
        if [ "$VAL" = "1" ]; then
            ONLINE=1
            break
        fi
    done
    echo "$ONLINE"
}

# === Get epoch time of the most recent AC adapter state-change event ===
# Relies on /etc/udev/rules.d/99-ac-adapter-timestamp.rules, which writes
# the current time to AC_EVENT_FILE the instant the kernel reports the AC
# adapter's "online" attribute changing, in EITHER direction (plugged in OR
# unplugged — testing showed both can trigger the same near-instant spurious
# wake on this hardware). This is far more reliable than trying to parse
# dmesg for a matching driver message, since not all hardware/firmware
# prints one (confirmed absent on some systems) and sysfs attribute mtimes
# are not reliably updated on change either. Returns empty if the udev rule
# isn't installed or hasn't recorded an event yet.
#
# The udev rule writes plain `date` output (no "%s" format specifier) — a
# literal "%" in a udev RUN command is intercepted by udev's own
# substitution engine before reaching the shell, which on this hardware
# silently ate "%s" and produced an empty file. Converting that plain date
# string to epoch seconds is done here instead, entirely within the script,
# where "%" is not a special character. (AC_EVENT_FILE and
# AC_UDEV_RULE_PATH are globals, set in the CONFIGURATION section.)

get_last_ac_event_epoch() {
    [ -f "$AC_EVENT_FILE" ] || return
    local DATESTR
    DATESTR=$(cat "$AC_EVENT_FILE" 2>/dev/null)
    [ -z "$DATESTR" ] && return
    date -d "$DATESTR" +%s 2>/dev/null
}

# === Self-install the AC-adapter timestamp udev rule if missing ===
# Makes the script self-contained for deployment: rather than requiring a
# separate manual "sudo cp .../99-ac-adapter-timestamp.rules ..." step
# before first use, the script checks for the rule on every run and
# installs it if absent. If the rule is already present, this is a no-op
# (a single [ -f ] check) and adds negligible overhead. A .rules file does
# not need to be executable — udevd just reads it — so no chmod +x is
# applied, only normal 644 permissions.
#
# If AC_UDEV_RULE_PATH is later changed to a different location, cleaning
# up the rule left behind at the old location is handled by the --gui
# Save Settings flow (see save_settings_clicked_cb in sleep-unified.c),
# which already knows both the old and new value at the moment of saving
# — no extra system-wide tracking file is needed here for that.
ensure_ac_udev_rule() {
    [ -f "$AC_UDEV_RULE_PATH" ] && return

    echo "AC adapter udev rule not found at $AC_UDEV_RULE_PATH, installing..." >> "$LOGFILE"

    if [ "$(id -u)" -ne 0 ]; then
        echo "WARNING: not running as root, cannot install $AC_UDEV_RULE_PATH. AC-adapter spurious-wake detection will fall back to the short-duration heuristic only." >> "$LOGFILE"
        return
    fi

    if ! cat > "$AC_UDEV_RULE_PATH" << 'AC_UDEV_RULE_EOF'
# /etc/udev/rules.d/99-ac-adapter-timestamp.rules
#
# Records the wall-clock time of every AC adapter state change (plugged in
# OR unplugged) to /tmp/ac-online-event-time. Used by the Unified Sleep
# Mode Optimization Framework script (sleep-unified.sh) to detect a
# firmware behavior where changing the AC adapter's connection state while the
# system is asleep wakes it almost immediately — this does not register as
# a normal ACPI wakeup event, so it can't be filtered out ahead of time;
# instead the script compares the wake time to this timestamp after the
# fact. Installed automatically by sleep-unified.sh if not already present.
#
# This rule is purely reactive: it only runs in response to a uevent the
# kernel already generated (attribute change), so it never causes a wakeup
# or keeps the system from sleeping.
#
# NOTE: this writes plain `date` output (no format specifier), not
# `date +%s` — a literal "%" in a udev rule is intercepted by udev's own
# substitution engine before the command ever reaches the shell, which on
# some hardware silently eats the "%s" format specifier and produces an
# empty file. Avoiding "%" entirely sidesteps that; sleep-unified.sh
# converts this plain date string to epoch seconds itself via `date -d`.

ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/bin/sh -c 'date > /tmp/ac-online-event-time'"
ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/bin/sh -c 'date > /tmp/ac-online-event-time'"
AC_UDEV_RULE_EOF
    then
        echo "WARNING: failed to write $AC_UDEV_RULE_PATH." >> "$LOGFILE"
        return
    fi

    chmod 644 "$AC_UDEV_RULE_PATH" 2>/dev/null

    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null
        echo "Installed and reloaded udev rule: $AC_UDEV_RULE_PATH" >> "$LOGFILE"
    else
        echo "WARNING: installed $AC_UDEV_RULE_PATH but 'udevadm' was not found, so rules were not reloaded. It will take effect after the next reboot or manual 'udevadm control --reload-rules'." >> "$LOGFILE"
    fi
}

# ============================================================================
# MAIN SCRIPT - PRE-SUSPEND
# ============================================================================

wait_sync

ensure_ac_udev_rule

if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE")" -gt "$LOG_MAXSIZE" ]; then
    tail -n 100 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
fi
echo "==== $(date) ====" >> "$LOGFILE"

# Cleanup old empty mount directories from previous runs
cleanup_empty_mount_dirs

MEM_SLEEP=$(cat /sys/power/mem_sleep 2>/dev/null)
ACTIVE_SLEEP=$(echo "$MEM_SLEEP" | grep -o '\[.*\]' | tr -d '[]')
echo "mem_sleep modes: $MEM_SLEEP" >> "$LOGFILE"
echo "Detected active sleep mode: $ACTIVE_SLEEP" >> "$LOGFILE"

REAL_DEEP=0
if [ "$ACTIVE_SLEEP" = "deep" ]; then
    REAL_DEEP=1
    notify_user "Deep sleep available. System is preparing to sleep..."
else
    notify_user "System is preparing to sleep..."
fi

> "$STATE_FILE"
SUSPEND_START=$(date +%s)
echo "SUSPEND_START=$SUSPEND_START" >> "$STATE_FILE"
echo "Suspend start time: $SUSPEND_START" >> "$LOGFILE"

# === ACPI wakeup control ===
if [ "$ENABLE_ACPI_WAKEUP_PRUNING" = "1" ]; then
    HAS_USB_KBD=0
    for DATA in /run/udev/data/c*; do
        grep -qs "ID_INPUT_KEYBOARD=1" "$DATA" && HAS_USB_KBD=1 && break
    done

    ACPI_KEEP="PS2K|PBTN|LID"
    [ "$HAS_USB_KBD" -eq 1 ] && ACPI_KEEP="PS2K|PBTN|LID|XHC|XHCI"

    echo "Scanning ACPI wake sources..." >> "$LOGFILE"
    if [ -f /proc/acpi/wakeup ]; then
        while IFS= read -r line; do
            DEVICE=$(echo "$line" | awk '{print $1}')
            STATUS=$(echo "$line" | awk '{print $3}')
            [ "$DEVICE" = "Device" ] && continue
            echo "ACPI_${DEVICE}=${STATUS}" >> "$STATE_FILE"
            echo "ACPI device: $DEVICE state: $STATUS" >> "$LOGFILE"
            if [[ "$STATUS" == "*enabled" ]] && [[ ! "$DEVICE" =~ $ACPI_KEEP ]]; then
                echo "$DEVICE" > /proc/acpi/wakeup 2>/dev/null
            fi
        done < /proc/acpi/wakeup
    fi
else
    echo "ACPI wakeup pruning disabled (ENABLE_ACPI_WAKEUP_PRUNING=0)" >> "$LOGFILE"
fi

# === CPU governors backup ===
if [ "$ENABLE_CPU_GOVERNORS" = "1" ] && [ "$REAL_DEEP" -eq 0 ]; then
    echo "Saving CPU governors..." >> "$LOGFILE"
    for GOV in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$GOV" ] || continue
        CPU_NUM=$(echo "$GOV" | grep -oP 'cpu\K[0-9]+')
        VALUE=$(cat "$GOV" 2>/dev/null)
        echo "CPU${CPU_NUM}=${VALUE}" >> "$STATE_FILE"
        echo "CPU $CPU_NUM governor: $VALUE" >> "$LOGFILE"
    done

    echo "Switching all CPUs to powersave" >> "$LOGFILE"
    echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
elif [ "$ENABLE_CPU_GOVERNORS" != "1" ]; then
    echo "CPU governor management disabled (ENABLE_CPU_GOVERNORS=0)" >> "$LOGFILE"
fi

# === Save rfkill states and disable Wi-Fi/Bluetooth ===
if [ "$ENABLE_RFKILL" = "1" ]; then
    echo "Saving rfkill states and disabling Wi-Fi/Bluetooth..." >> "$LOGFILE"

    if command -v rfkill >/dev/null 2>&1; then
        rfkill list 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9]+):\ (.+):\ (.+)$ ]]; then
            ID="${BASH_REMATCH[1]}"
            # BASH_REMATCH[2] is the interface/device name (e.g. hci0,
            # wlan0) — BASH_REMATCH[3] is the actual rfkill TYPE (e.g.
            # "Bluetooth", "Wireless LAN"). Using [2] here was a bug: the
            # case match below compared a device name against type
            # keywords and could never match, so rfkill block was never
            # actually being called for Wi-Fi/Bluetooth.
            TYPE="${BASH_REMATCH[3]}"

            SOFT=$(rfkill list "$ID" 2>/dev/null | grep "Soft blocked:" | awk '{print $3}')
            HARD=$(rfkill list "$ID" 2>/dev/null | grep "Hard blocked:" | awk '{print $3}')

            echo "RFKILL_${ID}_TYPE=$TYPE" >> "$STATE_FILE"
            echo "RFKILL_${ID}_SOFT=$SOFT" >> "$STATE_FILE"
            echo "RFKILL_${ID}_HARD=$HARD" >> "$STATE_FILE"
            echo "RFKILL device $ID ($TYPE): soft=$SOFT hard=$HARD" >> "$LOGFILE"

            # Real rfkill type strings are capitalized, multi-word (e.g.
            # "Wireless LAN", "Bluetooth", "Wireless WAN"), not the bare
            # lowercase single-word values the old case pattern expected —
            # match case-insensitively against substrings instead.
            TYPE_LC=$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')
            case "$TYPE_LC" in
                *wlan*|*wifi*|*wireless\ lan*|*bluetooth*|*wireless\ wan*|*wwan*)
                    echo "Blocking $ID ($TYPE)" >> "$LOGFILE"
                    rfkill block "$ID" 2>/dev/null
                    ;;
            esac
        fi
    done
fi
else
    echo "rfkill management disabled (ENABLE_RFKILL=0)" >> "$LOGFILE"
fi

# === Save and disable network interfaces ===
if [ "$ENABLE_NETWORK_INTERFACES" = "1" ]; then
    echo "Saving and disabling network interfaces..." >> "$LOGFILE"
    for i in /sys/class/net/*; do
        iface=$(basename "$i")

        [[ "$iface" == lo* ]] && continue
        [[ "$iface" == docker* ]] && continue
        [[ "$iface" == veth* ]] && continue

        if ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
            STATE_VALUE="up"
            ip link set "$iface" down 2>/dev/null
        else
            STATE_VALUE="down"
        fi

        echo "NET_${iface}=${STATE_VALUE}" >> "$STATE_FILE"
        echo "Interface $iface state: $STATE_VALUE" >> "$LOGFILE"
    done
else
    echo "Network interface management disabled (ENABLE_NETWORK_INTERFACES=0)" >> "$LOGFILE"
fi

# === USB wakeup and power management ===
# NOTE: SATA/SCSI manage_start_stop handling has been MOVED further down,
# to run after disconnect_external_usb_disks(). This section now only
# configures USB remote-wakeup and USB autosuspend control, which do not
# risk causing filesystem I/O errors on still-mounted volumes.
if [ "$ENABLE_USB_WAKEUP_POWER" = "1" ] && [ "$REAL_DEEP" -eq 0 ]; then
    echo "Processing USB wakeup..." >> "$LOGFILE"
    for DEV in /sys/bus/usb/devices/*/power/wakeup; do
        [ -f "$DEV" ] || continue
        PREV=$(cat "$DEV")
        DEV_ID=$(echo "$DEV" | grep -oP '/sys/bus/usb/devices/\K[^/]+')
        echo "USB_WAKE_${DEV_ID}=${PREV}" >> "$STATE_FILE"

        NAME=$(udevadm info -q property -p "$(dirname "$DEV")" 2>/dev/null | grep ID_INPUT | head -n1)
        if [[ "$NAME" == *"keyboard"* || "$NAME" == *"touchpad"* ]]; then
            echo enabled > "$DEV" 2>/dev/null
        else
            echo disabled > "$DEV" 2>/dev/null
        fi
    done

    for DEV in /sys/bus/usb/devices/*/power/control; do
        [ -f "$DEV" ] || continue
        DEV_PATH=$(dirname "$DEV")
        DEV_ID=$(echo "$DEV" | grep -oP '/sys/bus/usb/devices/\K[^/]+')
        PREV=$(cat "$DEV")
        echo "USB_CONTROL_${DEV_ID}=${PREV}" >> "$STATE_FILE"

        PRODUCT=$(cat "${DEV_PATH}/product" 2>/dev/null || echo "")
        if [[ ! "$PRODUCT" == *"keyboard"* ]]; then
            echo auto > "$DEV" 2>/dev/null
        fi
    done
elif [ "$ENABLE_USB_WAKEUP_POWER" != "1" ]; then
    echo "USB wakeup/power management disabled (ENABLE_USB_WAKEUP_POWER=0)" >> "$LOGFILE"
fi

# === Screen power off ===
if [ "$ENABLE_SCREEN_DPMS" = "1" ]; then
    if command -v xset >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        SCREEN_PREV=$(xset q 2>/dev/null | grep "Monitor is" | awk '{print $3}')
        echo "SCREEN=${SCREEN_PREV}" >> "$STATE_FILE"
    fi
    screen_off
else
    echo "Screen power management disabled (ENABLE_SCREEN_DPMS=0)" >> "$LOGFILE"
fi

if [ "$ENABLE_TOUCHPAD_RESTORE" = "1" ]; then
    echo "Saving touchpad state..." >> "$LOGFILE"
    save_touchpad_state
else
    echo "Touchpad state save/restore disabled (ENABLE_TOUCHPAD_RESTORE=0)" >> "$LOGFILE"
fi

# === Disconnect USB storage devices ===
# This must run BEFORE the SATA/SCSI manage_start_stop loop below, so that
# external USB disks are safely unmounted and deauthorized before anything
# is granted permission to spin down/power off the underlying block device.
if [ "$ENABLE_USB_DISK_SAFE_UNMOUNT" = "1" ]; then
    echo "Identifying system disks..." >> "$LOGFILE"
    SYSTEM_DISK_IDS=$(get_system_disk_ids)
    echo "System disk USB IDs: $SYSTEM_DISK_IDS" >> "$LOGFILE"

    echo "Saving mount points of USB storage devices..." >> "$LOGFILE"
    save_usb_disk_mounts "$SYSTEM_DISK_IDS"

    echo "Disconnecting non-system USB storage devices..." >> "$LOGFILE"
    disconnect_external_usb_disks "$SYSTEM_DISK_IDS"
else
    echo "USB disk safe unmount disabled (ENABLE_USB_DISK_SAFE_UNMOUNT=0) — USB disks are left mounted and connected through sleep" >> "$LOGFILE"
fi

# === SATA/SCSI disk power management (runs after unmount/disconnect) ===
# Reasoning: previously this loop ran before disconnect_external_usb_disks(),
# which could grant manage_start_stop=1 to an external USB disk that was
# still mounted, allowing the kernel/disk to spin down or power off while
# ntfs-3g (or another driver) still had it mounted — causing
# "ntfs_attr_pread_i: ntfs_pread failed: Input/output error" style failures.
# Now, external USB disks that were successfully disconnected above will
# typically no longer even appear under /sys/class/scsi_disk/*, so this loop
# naturally only affects internal disks (or USB disks that failed to
# disconnect and are therefore still safely mounted).
if [ "$ENABLE_SATA_POWER_MANAGEMENT" = "1" ] && [ "$REAL_DEEP" -eq 0 ]; then
    echo "Saving SATA/SCSI disk power management state..." >> "$LOGFILE"
    for DISK in /sys/class/scsi_disk/*/manage_start_stop; do
        [ -w "$DISK" ] || continue
        PREV=$(cat "$DISK")
        DISK_ID=$(echo "$DISK" | grep -oP '/sys/class/scsi_disk/\K[^/]+')
        echo "SATA_${DISK_ID}=${PREV}" >> "$STATE_FILE"
        sync
        echo 1 > "$DISK"
    done
elif [ "$ENABLE_SATA_POWER_MANAGEMENT" != "1" ]; then
    echo "SATA/SCSI power management disabled (ENABLE_SATA_POWER_MANAGEMENT=0)" >> "$LOGFILE"
fi

# === Perform sleep ===
# Some firmware wakes the system almost immediately when the AC adapter's
# connection state changes while asleep — either plugging it in OR
# unplugging it. This is not a normal ACPI wakeup event (it does not show
# up in /proc/acpi/wakeup or the ACPI wake source scan above), so it cannot
# be filtered out ahead of time the way other wake sources are.
#
# Detection here does NOT rely on how long the system was actually asleep
# (a laptop can sleep for 30 minutes and still get woken the instant someone
# plugs in or unplugs the charger at any point during that time — the total
# sleep duration says nothing about whether THIS wake was caused by that).
# Instead it compares two independent timestamps taken right after waking:
# the time the AC adapter state-change event was recorded by the udev rule
# in 99-ac-adapter-timestamp.rules (get_last_ac_event_epoch — accurate
# regardless of overall uptime/sleep length, since it's written the instant
# the kernel reports the event) versus the time the wake itself happened. If
# those are within a few seconds of each other, the wake is attributed to
# the AC event and the script goes straight back to sleep instead of
# running the full (unwanted) resume sequence. As a fallback for systems
# where the udev rule isn't installed, a short-duration + AC-state-
# transition check is also kept, but it only catches the narrower case of
# an almost-instant wake right after this particular sleep call was
# entered. Capped at MAX_RESLEEP_ATTEMPTS re-sleep attempts as a safety
# net, so a legitimate wake is never suppressed indefinitely.
# (SPURIOUS_WAKE_THRESHOLD and MAX_RESLEEP_ATTEMPTS are globals, set in the
# CONFIGURATION section.)
RESLEEP_COUNT=0
AC_STATE_BEFORE=$(get_ac_online)

while true; do
    sync
    sleep 1

    if [ "$ENABLE_SCREEN_DPMS" = "1" ]; then
        screen_off
        echo "Screen forced off before sleep" >> "$LOGFILE"
    fi

    SLEEP_ENTER_TIME=$(date +%s)
    echo "Entering sleep mode at $(date)" >> "$LOGFILE"

    if [ "$REAL_DEEP" -eq 1 ]; then
        echo deep > /sys/power/mem_sleep 2>/dev/null || true
        echo mem > /sys/power/state 2>/dev/null || true
    else
        echo s2idle > /sys/power/mem_sleep 2>/dev/null || true
        echo mem > /sys/power/state 2>/dev/null || true
    fi

    SLEEP_EXIT_TIME=$(date +%s)
    SLEEP_DURATION=$((SLEEP_EXIT_TIME - SLEEP_ENTER_TIME))
    AC_STATE_AFTER=$(get_ac_online)
    AC_EVENT_EPOCH=$(get_last_ac_event_epoch)

    # Log actual rfkill state at each wake, purely for diagnostics. This is
    # a definitive, logged record of whether radios (Wi-Fi/Bluetooth) are
    # actually soft-blocked at this moment, rather than having to infer it
    # from indirect signals like a bluetoothd resume message elsewhere in
    # the system log — nothing here changes rfkill state, it only reads it.
    if command -v rfkill >/dev/null 2>&1; then
        echo "rfkill state at this wake:" >> "$LOGFILE"
        rfkill list 2>/dev/null >> "$LOGFILE"
    fi

    IS_SPURIOUS=0

    if [ "$ENABLE_AC_SPURIOUS_WAKE" = "1" ]; then
        if [ -n "$AC_EVENT_EPOCH" ]; then
            AC_EVENT_DELTA=$((SLEEP_EXIT_TIME - AC_EVENT_EPOCH))
            [ "$AC_EVENT_DELTA" -lt 0 ] && AC_EVENT_DELTA=$((-AC_EVENT_DELTA))
            if [ "$AC_EVENT_DELTA" -le "$SPURIOUS_WAKE_THRESHOLD" ]; then
                IS_SPURIOUS=1
                echo "AC adapter state-change event at ${AC_EVENT_EPOCH}, wake at ${SLEEP_EXIT_TIME} (delta ${AC_EVENT_DELTA}s)" >> "$LOGFILE"
            fi
            # Consume the event regardless of whether it matched, so a single
            # real plug-in can never be re-matched against a later, unrelated
            # wake far in the future.
            rm -f "$AC_EVENT_FILE" 2>/dev/null
        elif [ "$SLEEP_DURATION" -le "$SPURIOUS_WAKE_THRESHOLD" ] && [ "$AC_STATE_BEFORE" != "$AC_STATE_AFTER" ]; then
            IS_SPURIOUS=1
            echo "No AC event timestamp found (udev rule not installed/triggered); falling back to short-sleep + AC-state-transition heuristic (slept ${SLEEP_DURATION}s, AC ${AC_STATE_BEFORE}->${AC_STATE_AFTER})" >> "$LOGFILE"
        fi
    fi

    echo "Woke after ${SLEEP_DURATION}s (AC before=${AC_STATE_BEFORE}, AC after=${AC_STATE_AFTER}, spurious=${IS_SPURIOUS})" >> "$LOGFILE"

    if [ "$IS_SPURIOUS" -eq 1 ] && [ "$RESLEEP_COUNT" -lt "$MAX_RESLEEP_ATTEMPTS" ]; then
        RESLEEP_COUNT=$((RESLEEP_COUNT + 1))
        echo "Detected likely spurious wake from AC adapter state change (attempt ${RESLEEP_COUNT}/${MAX_RESLEEP_ATTEMPTS}), re-entering sleep..." >> "$LOGFILE"
        AC_STATE_BEFORE="$AC_STATE_AFTER"
        continue
    fi

    break
done

# ============================================================================
# MAIN SCRIPT - POST-RESUME
# ============================================================================

RESUME_TIME=$(date +%s)
echo "Woke up at: $RESUME_TIME" >> "$LOGFILE"

echo "Restoring previous states..." >> "$LOGFILE"

declare -A STATE
while IFS='=' read -r KEY VALUE; do
    STATE["$KEY"]="$VALUE"
done < "$STATE_FILE"

# === Restore ACPI wakeup ===
if [ "$ENABLE_ACPI_WAKEUP_PRUNING" = "1" ]; then
    for KEY in "${!STATE[@]}"; do
        [[ "$KEY" == ACPI_* ]] || continue
        DEVICE="${KEY#ACPI_}"
        ORIGINAL_STATUS="${STATE[$KEY]}"
        CURRENT_STATUS=$(grep "^${DEVICE}" /proc/acpi/wakeup 2>/dev/null | awk '{print $3}')
        if [ "$ORIGINAL_STATUS" != "$CURRENT_STATUS" ]; then
            echo "$DEVICE" > /proc/acpi/wakeup 2>/dev/null
        fi
    done
fi

# === Restore CPU governors ===
if [ "$ENABLE_CPU_GOVERNORS" = "1" ] && [ "$REAL_DEEP" -eq 0 ]; then
    for KEY in "${!STATE[@]}"; do
        [[ "$KEY" =~ ^CPU([0-9]+)$ ]] || continue
        CPU="${BASH_REMATCH[1]}"
        VALUE="${STATE[$KEY]}"
        GOV="/sys/devices/system/cpu/cpu${CPU}/cpufreq/scaling_governor"
        [ -f "$GOV" ] && echo "$VALUE" > "$GOV" 2>/dev/null
    done
fi

# === Restore USB autosuspend and wakeup ===
if [ "$ENABLE_USB_WAKEUP_POWER" = "1" ]; then
    for KEY in "${!STATE[@]}"; do
        [[ "$KEY" == USB_CONTROL_* ]] || continue
        DEV_ID="${KEY#USB_CONTROL_}"
        VALUE="${STATE[$KEY]}"
        DEV="/sys/bus/usb/devices/${DEV_ID}/power/control"
        [ -f "$DEV" ] && echo "$VALUE" > "$DEV" 2>/dev/null
    done

    for KEY in "${!STATE[@]}"; do
        [[ "$KEY" == USB_WAKE_* ]] || continue
        DEV_ID="${KEY#USB_WAKE_}"
        VALUE="${STATE[$KEY]}"
        DEV="/sys/bus/usb/devices/${DEV_ID}/power/wakeup"
        [ -f "$DEV" ] && echo "$VALUE" > "$DEV" 2>/dev/null
    done
fi

# ============================================================================
# POST-RESUME FUNCTIONS (called after wakeup)
# ============================================================================

# === Reconnect and remount USB storage devices ===
reconnect_usb_disks() {
    echo "Reconnecting USB storage devices..." >> "$LOGFILE"

    for KEY in "${!STATE[@]}"; do
        [[ "$KEY" == USB_DISK_AUTH_* ]] || continue

        local DEV_ID="${KEY#USB_DISK_AUTH_}"
        local WAS_AUTH="${STATE[$KEY]}"
        local AUTHORIZED="/sys/bus/usb/devices/${DEV_ID}/authorized"
        local DEV_PATH="/sys/bus/usb/devices/${DEV_ID}"

        if [ ! -d "$DEV_PATH" ]; then
            echo "Device path $DEV_PATH does not exist, attempting parent hub rebind..." >> "$LOGFILE"

            local PARENT_HUB=$(echo "$DEV_ID" | sed 's/-[^-]*$//')
            local PARENT_PATH="/sys/bus/usb/devices/${PARENT_HUB}"

            if [ -d "$PARENT_PATH" ] && [ -L "${PARENT_PATH}/driver" ]; then
                local DRV=$(basename "$(readlink "${PARENT_PATH}/driver")")
                echo "Rebinding parent hub $PARENT_HUB via $DRV" >> "$LOGFILE"
                echo "$PARENT_HUB" > "/sys/bus/usb/drivers/$DRV/unbind" 2>/dev/null || true
                sleep 1
                echo "$PARENT_HUB" > "/sys/bus/usb/drivers/$DRV/bind" 2>/dev/null || true
                sleep 2
            fi
        fi

        if [ -f "$AUTHORIZED" ] && [ "$WAS_AUTH" = "1" ]; then
            echo "Reconnecting USB storage device: $DEV_ID" >> "$LOGFILE"
            echo 1 > "$AUTHORIZED" 2>/dev/null || true

            echo "Waiting for device $DEV_ID to stabilize..." >> "$LOGFILE"
            sleep 3

            local UUIDS_TO_MOUNT=""
            for MOUNT_KEY in "${!STATE[@]}"; do
                if [[ "$MOUNT_KEY" =~ ^USB_MOUNT_${DEV_ID}_UUID_([^_]+)_TARGET$ ]]; then
                    local PART_UUID="${BASH_REMATCH[1]}"
                    UUIDS_TO_MOUNT="${UUIDS_TO_MOUNT} ${PART_UUID}"
                fi
            done

            if [ -z "$UUIDS_TO_MOUNT" ]; then
                echo "No UUIDs to mount for $DEV_ID" >> "$LOGFILE"
                continue
            fi

            echo "Need to mount UUIDs:$UUIDS_TO_MOUNT" >> "$LOGFILE"

            local WAIT_COUNT=0
            local MAX_WAIT=45
            local ALL_FOUND=0

            while [ "$WAIT_COUNT" -lt "$MAX_WAIT" ]; do
                ALL_FOUND=1

                for UUID in $UUIDS_TO_MOUNT; do
                    if [ ! -e "/dev/disk/by-uuid/$UUID" ]; then
                        ALL_FOUND=0
                        break
                    fi
                done

                if [ "$ALL_FOUND" -eq 1 ]; then
                    echo "All UUIDs found after ${WAIT_COUNT}s" >> "$LOGFILE"
                    break
                fi

                if [ "$WAIT_COUNT" -eq 10 ] || [ "$WAIT_COUNT" -eq 25 ]; then
                    echo "Triggering udev rescan..." >> "$LOGFILE"
                    udevadm trigger 2>/dev/null || true
                    udevadm settle 2>/dev/null || true
                fi

                sleep 1
                WAIT_COUNT=$((WAIT_COUNT + 1))
            done

            if [ "$ALL_FOUND" -eq 0 ]; then
                echo "ERROR: Not all UUIDs found for $DEV_ID after ${MAX_WAIT}s" >> "$LOGFILE"
                for UUID in $UUIDS_TO_MOUNT; do
                    if [ ! -e "/dev/disk/by-uuid/$UUID" ]; then
                        echo "  Missing UUID: $UUID" >> "$LOGFILE"
                    fi
                done
            fi

            for MOUNT_KEY in "${!STATE[@]}"; do
                if [[ "$MOUNT_KEY" =~ ^USB_MOUNT_${DEV_ID}_UUID_([^_]+)_TARGET$ ]]; then
                    local PART_UUID="${BASH_REMATCH[1]}"
                    local TARGET="${STATE[$MOUNT_KEY]}"
                    local FSTYPE="${STATE[USB_MOUNT_${DEV_ID}_UUID_${PART_UUID}_FSTYPE]}"
                    local OPTIONS="${STATE[USB_MOUNT_${DEV_ID}_UUID_${PART_UUID}_OPTIONS]}"

                    TARGET=$(echo -e "$TARGET")

                    echo "Processing mount entry: UUID=$PART_UUID -> ${TARGET}" >> "$LOGFILE"

                    if [ ! -e "/dev/disk/by-uuid/$PART_UUID" ]; then
                        echo "ERROR: UUID $PART_UUID not found in /dev/disk/by-uuid/" >> "$LOGFILE"
                        continue
                    fi

                    local CURRENT_DEV=$(readlink -f "/dev/disk/by-uuid/$PART_UUID" 2>/dev/null)

                    if [ -z "$CURRENT_DEV" ]; then
                        echo "ERROR: Cannot resolve UUID $PART_UUID to device" >> "$LOGFILE"
                        continue
                    fi

                    echo "UUID $PART_UUID resolved to $CURRENT_DEV" >> "$LOGFILE"

                    if [ ! -b "$CURRENT_DEV" ]; then
                        echo "ERROR: Device $CURRENT_DEV does not exist as block device" >> "$LOGFILE"
                        continue
                    fi

                    for OLD_DIR in "${BASE_TARGET}"_*; do
                        [ -e "$OLD_DIR" ] || continue
                        [ -d "$OLD_DIR" ] && force_cleanup_dir "$OLD_DIR"
                    done

                    if [ -d "$TARGET" ] && mountpoint -q "$TARGET" 2>/dev/null; then
                        local MOUNTED_UUID=$(findmnt -n -o UUID "$TARGET" 2>/dev/null || true)
                        if [ "$MOUNTED_UUID" = "$PART_UUID" ]; then
                            continue
                        fi

                        echo "Target $TARGET occupied, attempting cleanup..." >> "$LOGFILE"
                        if force_cleanup_dir "$TARGET"; then
                            echo "Successfully cleaned $TARGET" >> "$LOGFILE"
                        else
                            echo "Failed to clean $TARGET, using alternative" >> "$LOGFILE"
                            local COUNTER=1
                            TARGET="${BASE_TARGET}_${COUNTER}"
                            while [ -e "$TARGET" ]; do
                                if [ -d "$TARGET" ]; then
                                    if ! mountpoint -q "$TARGET" 2>/dev/null && [ -z "$(ls -A "$TARGET" 2>/dev/null)" ]; then
                                        force_cleanup_dir "$TARGET" && break
                                    fi
                                fi
                                COUNTER=$((COUNTER + 1))
                                TARGET="${BASE_TARGET}_${COUNTER}"
                            done
                        fi
                    fi

                    [ ! -d "$TARGET" ] && mkdir -p "$TARGET" 2>/dev/null

                    local MOUNT_SUCCESS=0

                    if [ -d "$TARGET" ]; then
                        if [ -n "$OPTIONS" ]; then
                            mount -t "$FSTYPE" -o "$OPTIONS" UUID="$PART_UUID" "$TARGET" 2>>"$LOGFILE" && MOUNT_SUCCESS=1
                        fi

                        [ "$MOUNT_SUCCESS" -eq 0 ] && mount -t "$FSTYPE" UUID="$PART_UUID" "$TARGET" 2>>"$LOGFILE" && MOUNT_SUCCESS=1
                        [ "$MOUNT_SUCCESS" -eq 0 ] && mount UUID="$PART_UUID" "$TARGET" 2>>"$LOGFILE" && MOUNT_SUCCESS=1

                        if [ "$MOUNT_SUCCESS" -eq 1 ]; then
                            echo "Mounted UUID=$PART_UUID to $TARGET" >> "$LOGFILE"
                        else
                            echo "Failed to mount UUID=$PART_UUID" >> "$LOGFILE"
                            force_cleanup_dir "$TARGET"
                        fi
                    fi
                fi
            done
        fi
    done
}

# ============================================================================
# CONTINUE POST-RESUME
# ============================================================================

# === Restore touchpad state ===
if [ "$ENABLE_TOUCHPAD_RESTORE" = "1" ]; then
    echo "Restoring touchpad state..." >> "$LOGFILE"
    restore_touchpad_state
fi

# === Restore rfkill states ===
if [ "$ENABLE_RFKILL" = "1" ]; then
    echo "Restoring rfkill states..." >> "$LOGFILE"
    if command -v rfkill >/dev/null 2>&1; then
        for KEY in "${!STATE[@]}"; do
            [[ "$KEY" =~ ^RFKILL_([0-9]+)_SOFT$ ]] || continue
            ID="${BASH_REMATCH[1]}"
            VALUE="${STATE[$KEY]}"

            [ -z "$VALUE" ] && continue

            if [[ "$VALUE" == "yes" ]]; then
                rfkill block "$ID" 2>/dev/null
            else
                rfkill unblock "$ID" 2>/dev/null
            fi
            echo "RFKILL device $ID restored to soft=$VALUE" >> "$LOGFILE"
        done
    fi
fi

# === Restore network interfaces ===
if [ "$ENABLE_NETWORK_INTERFACES" = "1" ]; then
    echo "Restoring network interfaces..." >> "$LOGFILE"
    for KEY in "${!STATE[@]}"; do
        [[ "$KEY" == NET_* ]] || continue
        IFACE="${KEY#NET_}"
        VALUE="${STATE[$KEY]}"

        ip link show "$IFACE" >/dev/null 2>&1 || continue

        if [[ "$VALUE" == "up" ]]; then
            ip link set "$IFACE" up 2>/dev/null
        else
            ip link set "$IFACE" down 2>/dev/null
        fi
        echo "Interface $IFACE restored to $VALUE" >> "$LOGFILE"
    done
fi

if [ "$ENABLE_USB_DISK_SAFE_UNMOUNT" = "1" ]; then
    reconnect_usb_disks
fi

echo "Rebinding safe USB devices..." >> "$LOGFILE"
for KEY in "${!STATE[@]}"; do
    [[ "$KEY" == USB_CONTROL_* ]] || continue
    DEV_ID="${KEY#USB_CONTROL_}"
    DEV_PATH="/sys/bus/usb/devices/${DEV_ID}"

    [[ -n "${STATE[USB_DISK_AUTH_${DEV_ID}]}" ]] && continue
    [ -d "$DEV_PATH" ] || continue

    # Network-capable USB devices (e.g. a phone in USB-tethering/RNDIS
    # mode) are composite devices: their "net" directory lives under a
    # USB INTERFACE subdirectory (e.g. .../1-4/1-4:1.0/net/usb0), not
    # directly under the device directory itself (.../1-4/net). Checking
    # "${DEV_PATH}/net" only ever matched a non-composite USB Ethernet
    # adapter and effectively never matched a phone, so this device type
    # was previously never handled here at all.
    NET_IFACES=$(for D in "${DEV_PATH}"/*/net/*; do [ -d "$D" ] && basename "$D"; done 2>/dev/null)

    if [ -n "$NET_IFACES" ]; then
        if [ "$ENABLE_NETWORK_INTERFACES" = "1" ]; then
        # A driver-only unbind/bind is not enough to make an Android phone
        # renegotiate its RNDIS tethering session after suspend — that is
        # the manual "toggle tethering off/on" the user was doing. The
        # closest system-side equivalent is a full authorized=0 -> 1 cycle
        # on the USB device itself, which forces a real USB-level
        # detach/reattach (the same as physically unplugging/replugging),
        # rather than just rebinding the driver to an unchanged device.
        AUTH_FILE="${DEV_PATH}/authorized"
        if [ -f "$AUTH_FILE" ]; then
            echo "Resetting network device $DEV_ID (interfaces:${NET_IFACES//$'\n'/ }) via authorized cycle" >> "$LOGFILE"
            echo 0 > "$AUTH_FILE" 2>/dev/null || true
            sleep 1
            echo 1 > "$AUTH_FILE" 2>/dev/null || true

            WAIT_NET=0
            while [ "$WAIT_NET" -lt 5 ]; do
                [ -d "$DEV_PATH" ] && ls -d "${DEV_PATH}"/*/net/* >/dev/null 2>&1 && break
                sleep 1
                WAIT_NET=$((WAIT_NET + 1))
            done

            for D in "${DEV_PATH}"/*/net/*; do
                [ -d "$D" ] || continue
                IFACE=$(basename "$D")
                ip link set "$IFACE" up 2>/dev/null || true
                echo "Interface $IFACE brought up after network device reset" >> "$LOGFILE"
            done
        fi
        else
            echo "Network device reset skipped for $DEV_ID (ENABLE_NETWORK_INTERFACES=0)" >> "$LOGFILE"
        fi
        continue
    fi

    if [ "$ENABLE_USB_WAKEUP_POWER" = "1" ]; then
        WAS_WAKE="${STATE[USB_WAKE_${DEV_ID}]:-}"
        if [ "$WAS_WAKE" = "enabled" ]; then
            if [ -L "${DEV_PATH}/driver" ]; then
                DRV=$(basename "$(readlink "${DEV_PATH}/driver")")
                echo "Rebinding $DEV_ID via $DRV" >> "$LOGFILE"
                echo "$DEV_ID" > "/sys/bus/usb/drivers/$DRV/unbind" 2>/dev/null || true
                sleep 0.2
                echo "$DEV_ID" > "/sys/bus/usb/drivers/$DRV/bind" 2>/dev/null || true
            fi
        fi
    fi
done

# === Restore SATA power ===
if [ "$ENABLE_SATA_POWER_MANAGEMENT" = "1" ]; then
    for KEY in "${!STATE[@]}"; do
        [[ "$KEY" == SATA_* ]] || continue
        DISK_ID="${KEY#SATA_}"
        VALUE="${STATE[$KEY]}"
        DISK="/sys/class/scsi_disk/${DISK_ID}/manage_start_stop"
        [ -w "$DISK" ] && echo "$VALUE" > "$DISK" 2>/dev/null
    done
fi

# === Restore screen power ===
if [ "$ENABLE_SCREEN_DPMS" = "1" ]; then
    if command -v xset >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        if [ "${STATE[SCREEN]}" = "On" ]; then
            screen_on
        fi
    elif [ -n "$WAYLAND_DISPLAY" ]; then
        # No portable way to have queried the prior on/off state on Wayland
        # (see screen_off/screen_on comments), so this always turns the
        # display back on, which matches the expected behavior of a resume.
        screen_on
    fi
fi

truncate_state_file

notify_user "System resumed from sleep."
echo "Resume completed successfully." >> "$LOGFILE"

exit 0
