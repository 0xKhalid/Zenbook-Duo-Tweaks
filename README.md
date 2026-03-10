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
├── zenbook-tweaks                               TUI manager v1.2
├── tweaks/
│   ├── display-toggle/
│   │   ├── tweak.conf
│   │   ├── zenbook-duo-display-toggle.sh
│   │   ├── zenbook-duo-display-toggle@.service
│   │   └── 99-zenbook-duo-keyboard-display.rules
│   └── kbd-backlight/
│       ├── tweak.conf
│       ├── kbd-backlight.sh
│       └── 99-asus-kbd-backlight.rules
├── .gitignore
└── README.md
```
