# Zenbook Duo Tweaks for Linux

System tweaks for the ASUS Zenbook Duo 2026 (UX8407) on Linux Fedora KDE / Plasma Wayland.

## Tested On

| | |
|---|---|
| **Device** | ASUS Zenbook Duo 2026 (UX8407) |
| **OS** | Fedora 44 |
| **Desktop** | KDE Plasma Wayland 6.7.3 |
| **Kernel** | 7.0.14-201.fc44.x86_64 |
| **GPU** | Intel Panther Lake Graphics `[8086:b090]` |
| **Driver** | `xe` |

## Available Tweaks

| Tweak | Description |
|-------|-------------|
| `duo-display-control` | Automatic dual-screen control and rotation |
| `span-both-screens` | Span maximized windows across both screens |
| `brightness-lock` | Keep the lower screen at full brightness |
| `kbd-backlight` | Control the detachable keyboard backlight |
| `speaker-fix` | Fix silent built-in speakers |
| `whisper-dictate` | Private, on-device voice typing |
| `heic-support` | Open HEIC and HEIF images in KDE |
| `touchpad-fix` | Stop cursor jumps while typing |

## Usage

```bash
sudo ./zenbook-tweaks
```

Launches an interactive TUI — browse tweaks, read a simple summary, open **More info** for technical details, and install or uninstall. Arrow keys navigate and Enter selects. Requires `sudo` for install/uninstall.

## Adding New Tweaks

1. Create a folder under `tweaks/` with your tweak name
2. Add your script, service, or rule files inside it
3. Create a `tweak.conf` file defining:
   - `TWEAK_NAME` — short identifier
   - `TWEAK_DESCRIPTION` — short one-line label for the tweak list
   - `TWEAK_SUMMARY` — plain-language explanation shown on the tweak screen
   - `TWEAK_INFO` — technical details shown in the tweak's **More info** view
   - `TWEAK_FILES` — array of `"source:dest:permissions"` entries (can be empty for package-only tweaks)
   - Optional hook functions: `tweak_pre_install`, `tweak_post_install`, `tweak_pre_uninstall`, `tweak_post_uninstall`
   - Optional `tweak_status_check` — custom status function for tweaks without files (must echo one of: `not installed`, `partially installed`, `installed`)
   - Optional `TWEAK_ACTIONS` — array of custom installed-tweak actions in `"Label:function_name"` format

The TUI auto-discovers all tweaks from `tweaks/*/tweak.conf`.
Custom `TWEAK_ACTIONS` appear in the tweak detail screen after the tweak is installed.

## Files

```
Zenbook-Duo-Tweaks/
├── zenbook-tweaks
├── tweaks/
│   ├── duo-display-control/
│   │   ├── tweak.conf
│   │   ├── zenbook-duo-display-control.sh
│   │   ├── zenbook-duo-icon-layout.js
│   │   ├── zenbook-duo-display-control.service
│   │   ├── zenbook-duo-display-control@.service
│   │   ├── 99-zenbook-duo-display-control.rules
│   │   └── 90-zenbook-duo-display-control.conf
│   ├── span-both-screens/
│   │   ├── tweak.conf
│   │   ├── metadata.json
│   │   ├── zenbook-duo-span-both-screens
│   │   └── contents/code/main.js
│   ├── brightness-lock/
│   │   ├── tweak.conf
│   │   ├── zenbook-duo-brightness-lock.sh
│   │   ├── zenbook-duo-brightness-lock.service
│   │   └── zenbook-duo-brightness-lock.timer
│   ├── kbd-backlight/
│   │   ├── tweak.conf
│   │   ├── kbd-backlight.sh
│   │   └── 99-asus-kbd-backlight.rules
│   ├── speaker-fix/
│   │   ├── tweak.conf
│   │   ├── zenbook-duo-speaker-fix.sh
│   │   └── zenbook-duo-speaker-fix.service
│   ├── whisper-dictate/
│   │   ├── tweak.conf
│   │   └── whisper-dictate-toggle
│   ├── heic-support/
│   │   └── tweak.conf
│   └── touchpad-fix/
│       ├── tweak.conf
│       └── local-overrides.quirks
├── .gitignore
└── README.md
```

## Disclaimer

This software is provided "as is", without warranty of any kind, express or implied. The authors are not responsible for any damage, data loss, or system issues that may result from using these tweaks. These tweaks modify system-level files and services — use at your own risk. Always review what a tweak does before installing.

## Changelog

### v2.9 - Explicit primary display selection:
- Added a `Set primary display` action to `duo-display-control` with explicit Upper screen (`eDP-1`) and Lower screen (`eDP-2`) choices.
- The selected preference is applied immediately and remembered across reboot, rotation, and keyboard dock/undock events without restarting the sensor monitor.
- Choosing the lower screen makes it primary while detached, restores the upper screen while docked, and makes the lower screen primary again after detaching.
- Replaced `LOWER_DISPLAY_PRIMARY_WHEN_DETACHED=0|1` with `PRIMARY_DISPLAY_WHEN_DETACHED=upper|lower`, including automatic migration of managed and legacy preferences.
- Expanded display-control status with the remembered preference and active KDE primary output.
- Updated Tested On metadata for Fedora 44, kernel `7.0.14-201.fc44.x86_64`, KDE Plasma Wayland 6.7.3, Intel Panther Lake Graphics `[8086:b090]`, and the `xe` driver.

### v2.8 - Display, touch, desktop, and window improvements:
- Simplified every tweak screen with a short plain-language summary and moved technical details into a separate scrollable **More info** view.
- Added same-size portrait icon fitting for both built-in Folder View desktops, moving only icons outside the visible grid and using free space on the other active panel when required.
- Kept independent landscape and portrait position profiles: normal and upside-down share landscape placement, while left and right share portrait placement.
- Added a pre-change Plasma profile barrier so cross-resolution position tracking cannot copy portrait edits over the landscape layout.
- Corrected the inverted upper RAYD0001 touchscreen with a narrowly matched 180-degree libinput base calibration that follows eDP-1 through all four automatic orientations without changing the lower touchscreen or either stylus interface.
- Added a timestamped pre-v2.8 Plasma layout backup, an automatic `fit-icons` helper, geometry/profile validation, and non-blocking failure handling so icon-layout errors never undo a successful display rotation.
- Added the standalone `span-both-screens` tweak using Fedora's stock KWin.
- Maximize-button clicks, titlebar double-clicks, and `Meta+PgUp` span normal resizable windows across both built-in displays; repeating the action restores the saved window state.
- Added native-style tear-off, orientation-aware geometry updates, dock/undock reconciliation, and a titlebar Span/Restore action while preserving native per-screen dragging and snapping.
- Updated Tested On metadata for Fedora 44, kernel `7.0.14-201.fc44.x86_64`, KDE Plasma Wayland 6.7.3, Intel Panther Lake Graphics `[8086:b090]`, and the `xe` driver.

### v2.7 - Unified adaptive display control:
- Replaced `display-toggle` and `auto-rotate` with `duo-display-control`, one state machine for physical keyboard docking, lower-panel enablement, primary-display selection, dual-panel geometry, and automatic rotation.
- Enabled the UX8407 accelerometer with the checksum-verified ASUS Sensor Solution firmware while retaining Fedora's generic firmware for rollback and including the override in initramfs.
- Added all four paired screen orientations with a one-second stability filter, atomic KScreen updates, duplicate suppression, and a shared transaction lock.
- Added a TUI action for changing the rotation stability delay from immediate to 10 seconds, including decimal values, without restarting the sensor monitor.
- Existing `display-toggle` installations migrate automatically, including the lower-display primary preference; superseded project services, scripts, and udev rules are removed.
- Updated Tested On metadata for Fedora 44, kernel `7.0.14-201.fc44.x86_64`, KDE Plasma Wayland 6.7.3, Intel Panther Lake Graphics `[8086:b090]`, and the `xe` driver.

### v2.6 - Physical display-state reconciliation:
- Fixed `display-toggle` false detach events caused by input-remapper virtual keyboards copying the physical keyboard's name and USB IDs.
- Physical USB add/remove events now wake one coalesced sync action, which checks `/sys/bus/usb/devices` for the real docked keyboard before enabling or disabling `eDP-2`.
- Updated Tested On metadata for Fedora 44, kernel `7.0.14-201.fc44.x86_64`, KDE Plasma Wayland 6.7.2, Intel Panther Lake Graphics `[8086:b090]`, and the `xe` driver.

### v2.5 - Whisper local model picker:
- `whisper-dictate` now includes a local-only model picker for Fast (`base.en`), Better (`small.en`), Strong (`medium.en`), and Best practical (`large-v3-turbo-q5_0`) models. Missing models download only when selected, existing downloads are reused, and the selected model is stored in `~/.config/zenbook-tweaks/whisper-dictate.conf`.
- The Silero VAD helper model is now downloaded from the current `ggml-org/whisper-vad` source, validated by size, and repaired automatically if a stale/broken placeholder file is found.

### v2.4 - Brightness-lock hardening and latest tested specs:
- Hardened `brightness-lock` to write `/sys/class/backlight/card0-eDP-2-backlight` directly, skip no-op writes, and re-apply every 30 seconds instead of calling KScreen every 3 seconds.
- Updated Tested On metadata for Fedora 44, kernel `7.0.10-201.fc44.x86_64`, KDE Plasma Wayland 6.6.5, Intel Panther Lake Graphics `[8086:b090]`, and the `xe` driver.

### v2.3 - Optional primary display switching:
- `display-toggle` can now optionally make `eDP-2` the KDE primary display when the lower screen is enabled,
  without changing the physical screen layout or rewriting output positions.
- Install/reinstall asks whether to enable the behavior and stores the choice in
  `/etc/default/zenbook-duo-display-toggle`.

### v2.2 - Display-toggle boot hardening:
- Hardened `display-toggle` startup behavior by waiting for KDE/Wayland, session DBus, the Wayland socket, and KWin before calling `kscreen-doctor`.
- Added a runtime lock and 30-second duplicate-action debounce so early udev attach/detach bursts cannot run overlapping display changes or repeatedly hit KScreen during login.

### v2.1 - Boot detached display-toggle reliability fix:
- Fixed detached-at-boot reliability by making boot-check retry until a graphical session is ready and changing detection to treat only physically docked USB keyboard (`0b05:1cd7`) as attached, while Bluetooth mode is treated as detached.

### v2.0 - Lower display brightness lock:
- New `brightness-lock` tweak: keeps the lower built-in display (`eDP-2`) pinned to full brightness to reduce the dual-slider brightness issue in KDE.
- Installs `zenbook-duo-brightness-lock.sh` plus a systemd service/timer that re-applies full lower-screen brightness periodically during the graphical session.
- Configurable via service environment variables (`TARGET_OUTPUT`, `TARGET_BRIGHTNESS`) for users with different panel naming.

### v1.9 - Boot-time display check:
- `display-toggle` now checks keyboard presence at boot and sets eDP-2 accordingly — no more manual plug/unplug cycle needed when booting without the keyboard.
- New `boot` action in the display toggle script with extended retry logic (waits up to 60s for the graphical session to be ready).
- New `zenbook-duo-display-boot-check.service` enabled automatically on install.

### v1.8 - Touchpad fix for detachable keyboard:
- New `touchpad-fix` tweak: installs a libinput quirks file that marks the detachable Bluetooth keyboard and its touchpad as a combo device.
- Enables proper "disable while typing" behavior — accidental palm/brush touches are suppressed and the cursor stops jumping while typing.
- Single file install to `/etc/libinput/local-overrides.quirks`, logout/reboot to apply.

### v1.7 - Audio feedback for whisper-dictate:
- `whisper-dictate` now plays short audio cues on record start/stop for instant feedback.
- Uses freedesktop system sounds — no extra packages or files needed.
- Configurable: `WHISPER_SOUND=0` to disable, or set custom paths via `WHISPER_SOUND_START` / `WHISPER_SOUND_STOP`.

### v1.6 - HEIC support + backup framework + state tracking:
- New `heic-support` tweak: installs the minimum HEIC/HEIF codec packages from RPM Fusion Free (`libheif-freeworld`, `qt-heif-image-plugin`) for native image viewing in Gwenview, Dolphin, and other KDE/Qt apps.
- Added `tweak_status_check` hook: allows package-only tweaks (no installed files) to report custom install status.
- Added automatic backup/restore: existing system files are backed up before a tweak overwrites them and restored on uninstall.
- Added state tracking for package-only tweaks: records which packages were newly installed vs pre-existing. Uninstall only removes packages that the tweak itself installed — pre-existing packages are never touched.

### v1.5 - Let there be sound! Speaker fixed!:
- New `speaker-fix` tweak: enables the ALSA `Speaker Switch` on the sof-soundwire card at boot.
- The CS42L43/CS35L56 UCM profile does not set this control, leaving laptop speakers silent by default.
- Installs a lightweight systemd service — no existing system files are modified.

### v1.4 - Timeout auto-finalize:
- `whisper-dictate` now auto-transcribes and pastes when recording reaches the max duration limit.
- Added tweak info note for `WHISPER_MAX_RECORD_SECONDS` configurability and timeout behavior.

### v1.3 - On-device live transcription:
- Updated `whisper-dictate` messaging to focus on live on-device voice-to-text transcription.
- Made Copilot/F12 mapping guidance optional (example only; users can choose any key).
- Improved installer reliability:
  - Continue with warnings when packages/services are already present or partially unavailable.
  - Auto-detect `ydotool.service` vs `ydotoold.service`.
- Improved transcription runtime robustness:
  - Validate `whisper-cli` and model presence before transcription.
  - Use Silero VAD first when supported and available, with fallback path for compatibility.
  - Support alternate transcript output naming (`transcript.txt` or `<input>.txt`).
  - Keep original text normalization behavior for pasted output.
- Added a 5-minute default recording limit for `whisper-dictate` (`WHISPER_MAX_RECORD_SECONDS=300`), with transcription preserved on next toggle after timeout.
- Tweaks status UI now labels `[~]` as **update available** for reinstall flow.
- Back from Tweaks now returns correctly to Main Menu (no unintended exit under `set -e`).
- About screen now shows static `Tested On` values instead of dynamic runtime environment values.

### v1.2 - TUI-only simplification:
- Removed CLI mode and made the manager TUI-only.
- Added per-tweak `TWEAK_INFO` in detail screen.
- Updated status icons and streamlined tweak actions.
