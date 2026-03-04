# Zenbook-Duo-Tweaks

Auto-toggle the second internal display on Zenbook Duo 2026 (UX8407).

- Keyboard attached -> `eDP-2` OFF
- Keyboard detached -> `eDP-2` ON

Works on Fedora KDE / Plasma Wayland using `udev` + `systemd` + `kscreen-doctor`.

## Quick Start

1) Check your display names:

```bash
kscreen-doctor -o
```

2) Install files:

```bash
sudo install -Dm755 scripts/zenbook-duo-display-toggle.sh /usr/local/bin/zenbook-duo-display-toggle.sh
sudo install -Dm644 systemd/zenbook-duo-display-toggle@.service /etc/systemd/system/zenbook-duo-display-toggle@.service
sudo install -Dm644 udev/99-zenbook-duo-keyboard-display.rules /etc/udev/rules.d/99-zenbook-duo-keyboard-display.rules
```

3) Reload:

```bash
sudo systemctl daemon-reload
sudo udevadm control --reload
```

That’s it.

## Keyboard Match (Important)

Edit `/etc/udev/rules.d/99-zenbook-duo-keyboard-display.rules` if your keyboard IDs differ.

Find values with:

```bash
sudo udevadm monitor --udev --subsystem-match=input
sudo udevadm info --attribute-walk --name=/dev/input/eventX
```

Current known working values on UX8407:

- `ATTRS{id/vendor}=="0b05"`
- `ATTRS{id/product}=="1cd7"`
- `ATTRS{name}=="*Zenbook Duo Keyboard*"`

## Validate

Manual test:

```bash
sudo systemctl start zenbook-duo-display-toggle@detach.service
sudo systemctl start zenbook-duo-display-toggle@attach.service
```

Check logs:

```bash
journalctl -t zenbook-duo-display-toggle -n 50 --no-pager
```

Expected:

- `detach` -> `eDP-2` becomes enabled
- `attach` -> `eDP-2` becomes disabled

## Files

- `scripts/zenbook-duo-display-toggle.sh`
- `systemd/zenbook-duo-display-toggle@.service`
- `udev/99-zenbook-duo-keyboard-display.rules`
