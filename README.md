# Zenbook Duo Tweaks for Linux

System tweaks for the ASUS Zenbook Duo 2026 (UX8407) on Linux Fedora KDE / Plasma Wayland.

## Tested On

| | |
|---|---|
| **Device** | ASUS Zenbook Duo 2026 (UX8407) |
| **OS** | Fedora 43 |
| **Desktop** | KDE Plasma (Wayland) |
| **Kernel** | 6.19.9-200.fc43.x86_64 |

## Available Tweaks

| Tweak | Description |
|-------|-------------|
| `display-toggle` | Auto-toggle eDP-2 on keyboard attach/detach + boot check |
| `brightness-lock` | Keep lower built-in screen (`eDP-2`) at 100% brightness |
| `kbd-backlight` | ASUS keyboard backlight control (levels 0-3) |
| `speaker-fix` | Enable laptop speaker (sof-soundwire Speaker Switch) |
| `whisper-dictate` | Live on-device voice-to-text transcription |
| `heic-support` | Native HEIC/HEIF image support (RPM Fusion Free) |
| `touchpad-fix` | Disable-while-typing for detachable keyboard touchpad |

## Usage

```bash
sudo ./zenbook-tweaks
```

Launches an interactive TUI — browse tweaks, view details and usage instructions, install/uninstall. Arrow keys to navigate, Enter to select. Requires `sudo` for install/uninstall.

## Adding New Tweaks

1. Create a folder under `tweaks/` with your tweak name
2. Add your script, service, or rule files inside it
3. Create a `tweak.conf` file defining:
   - `TWEAK_NAME` — short identifier
   - `TWEAK_DESCRIPTION` — one-line description
   - `TWEAK_INFO` — multiline usage/instructions text (shown in TUI)
   - `TWEAK_FILES` — array of `"source:dest:permissions"` entries (can be empty for package-only tweaks)
   - Optional hook functions: `tweak_pre_install`, `tweak_post_install`, `tweak_pre_uninstall`, `tweak_post_uninstall`
   - Optional `tweak_status_check` — custom status function for tweaks without files (must echo one of: `not installed`, `partially installed`, `installed`)

The TUI auto-discovers all tweaks from `tweaks/*/tweak.conf`.

## Files

```
Zenbook-Duo-Tweaks/
├── zenbook-tweaks
├── tweaks/
│   ├── display-toggle/
│   │   ├── tweak.conf
│   │   ├── zenbook-duo-display-toggle.sh
│   │   ├── zenbook-duo-display-toggle@.service
│   │   ├── zenbook-duo-display-boot-check.service
│   │   └── 99-zenbook-duo-keyboard-display.rules
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
