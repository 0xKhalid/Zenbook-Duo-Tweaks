# Zenbook Duo Tweaks for Linux

System tweaks for the ASUS Zenbook Duo 2026 (UX8407) on Linux Fedora KDE / Plasma Wayland.

## Tested On

| | |
|---|---|
| **Device** | ASUS Zenbook Duo 2026 (UX8407) |
| **OS** | Fedora 43 |
| **Desktop** | KDE Plasma (Wayland) |
| **Kernel** | 6.20.5 |

## Available Tweaks

| Tweak | Description |
|-------|-------------|
| `display-toggle` | Auto-toggle eDP-2 on keyboard attach/detach |
| `kbd-backlight` | ASUS keyboard backlight control (levels 0-3) |
| `speaker-fix` | Enable laptop speaker (sof-soundwire Speaker Switch) |
| `whisper-dictate` | Live on-device voice-to-text transcription |

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
   - `TWEAK_FILES` — array of `"source:dest:permissions"` entries
   - Optional hook functions: `tweak_pre_install`, `tweak_post_install`, `tweak_post_uninstall`

The TUI auto-discovers all tweaks from `tweaks/*/tweak.conf`.

## Files

```
Zenbook-Duo-Tweaks/
├── zenbook-tweaks                               TUI manager v1.4
├── tweaks/
│   ├── display-toggle/
│   │   ├── tweak.conf
│   │   ├── zenbook-duo-display-toggle.sh
│   │   ├── zenbook-duo-display-toggle@.service
│   │   └── 99-zenbook-duo-keyboard-display.rules
│   ├── kbd-backlight/
│   │   ├── tweak.conf
│   │   ├── kbd-backlight.sh
│   │   └── 99-asus-kbd-backlight.rules
│   ├── speaker-fix/
│   │   ├── tweak.conf
│   │   ├── zenbook-duo-speaker-fix.sh
│   │   └── zenbook-duo-speaker-fix.service
│   └── whisper-dictate/
│       ├── tweak.conf
│       └── whisper-dictate-toggle
├── .gitignore
└── README.md
```

## Disclaimer

This software is provided "as is", without warranty of any kind, express or implied. The authors are not responsible for any damage, data loss, or system issues that may result from using these tweaks. These tweaks modify system-level files and services — use at your own risk. Always review what a tweak does before installing.

## Changelog

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
