# Unified Sleep Mode Optimization Framework

Unified Sleep Mode Optimization Framework: a Linux utility for managing suspend/resume.

Version: 1.1

Copyright (C) 2025-2026 Maksym Nazar.
Created with the assistance of Claude, ChatGPT, and Perplexity.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

## What this is

A single compiled program that prepares the system for suspend, performs
the actual suspend, and restores the previous hardware state on resume:
CPU governors, Wi-Fi/Bluetooth (rfkill), network interfaces, USB storage
devices (safely unmounted before sleep and remounted after), USB
wakeup/power settings, SATA/SCSI disk power management, touchpad state,
and screen power (X11 and Wayland).

It also includes a workaround for a firmware behavior on some hardware
where changing the AC adapter's connection state while asleep wakes the
system almost instantly: when detected, it goes straight back to sleep on
its own, up to a configurable number of attempts.

One binary, two ways to run it:

- **No arguments** — runs the sleep/resume logic directly (headless). This
  is the default, so anything invoking it unattended (a keybinding, a
  lid-close handler via `acpid`, a menu entry) works without needing to
  know a GUI exists.
- **`--gui` (or `-g`)** — opens a settings panel: view/edit tunable values,
  toggle individual pipeline stages on or off, trigger a sleep cycle
  manually, reset to defaults, and view the version history.

See Terms of Use and License (available from the `--gui` settings panel)
for more info.

## Repository contents

| File | What it is | Needed to just build and run the program? |
|---|---|---|
| `sleep-unified.c` | The whole program — GTK settings panel plus the sleep/resume logic embedded as a byte array. Compiles into a single binary. | **Yes — this is the only file you need.** |
| `sleep-unified.sh` | The sleep/resume logic on its own, as a standalone bash script. This is where that logic is actually edited; `sleep-unified.c`'s embedded copy is generated from it. Can also be run directly with `bash sleep-unified.sh` for development/testing. | No — only if you want to read or modify the logic, or run it without compiling anything. |
| `regenerate_embedded_script.sh` | Development tool: regenerates the byte array inside `sleep-unified.c` from the current `sleep-unified.sh`, after editing the latter. | No — only needed if you're changing `sleep-unified.sh`. |
| `99-ac-adapter-timestamp.rules` | A copy of the udev rule the program installs automatically on first run. Kept here for reference/review, or for installing it by hand instead. | No — the program installs this itself. |

## Installation

See [INSTALL.txt](INSTALL.txt) for step-by-step build, run, and uninstall
instructions.

## Settings

Settings are not stored inside the binary or the embedded script — they
live in a small external per-user config file,
`~/.config/Unified_Sleep/config`, written by the `--gui` settings panel.
If that file doesn't exist, built-in defaults are used and the program is
fully functional without it. "Reset to Defaults" in the GUI simply deletes
this file.

