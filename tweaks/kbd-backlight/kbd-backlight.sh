#!/usr/bin/env bash
set -euo pipefail
# ASUS Zenbook Duo UX8407AA Keyboard Backlight Control
# Uses HID feature report 0x5A with magic bytes BA C5 C4
# Supports USB (0B05:1CD7) and Bluetooth (0B05:1CD8)
#
# Usage:
#   kbd-backlight              Cycle: off → low → med → high → off
#   kbd-backlight set <0-3>    Set specific brightness level
#   kbd-backlight get          Show current level

STATE_FILE="/tmp/kbd-backlight-level"

# Find the correct hidraw device for the ASUS keyboard backlight interface
# USB: 0003:0B05:1CD7, interface 4 (input4)
# Bluetooth: 0005:0B05:1CD8, hid-generic driver
find_hidraw()
{
	# Try USB first (bus 0003, product 1CD7, interface input4)
	for uevent in /sys/bus/hid/devices/0003:0B05:1CD7.*/uevent; do
		if grep -q "input4" "$uevent" 2>/dev/null; then
			local devdir
			devdir=$(dirname "$uevent")
			local hidraw
			hidraw=$(ls "$devdir/hidraw/" 2>/dev/null | head -1)
			if [[ -n "$hidraw" ]]; then
				echo "/dev/$hidraw"
				return 0
			fi
		fi
	done

	# Try Bluetooth (bus 0005, product 1CD8, hid-generic driver)
	for uevent in /sys/bus/hid/devices/0005:0B05:1CD8.*/uevent; do
		local devdir
		devdir=$(dirname "$uevent")
		local driver
		driver=$(basename "$(readlink -f "$devdir/driver" 2>/dev/null)" 2>/dev/null || true)
		if [[ "$driver" == "hid-generic" ]]; then
			local hidraw
			hidraw=$(ls "$devdir/hidraw/" 2>/dev/null | head -1)
			if [[ -n "$hidraw" ]]; then
				echo "/dev/$hidraw"
				return 0
			fi
		fi
	done

	return 1
}

set_brightness()
{
	local level=$1
	local dev
	dev=$(find_hidraw) || true

	if [[ -z "$dev" ]]; then
		echo "Error: ASUS Zenbook Duo Keyboard not found" >&2
		return 1
	fi

	if [[ "$level" -lt 0 || "$level" -gt 3 ]]; then
		echo "Error: brightness must be 0-3" >&2
		return 1
	fi

	python3 -c "
import fcntl, os, array
fd = os.open('$dev', os.O_RDWR)
buf = array.array('B', [0x5a, 0xba, 0xc5, 0xc4, $level, 0,0,0,0,0,0,0,0,0,0,0])
fcntl.ioctl(fd, 0xC0004806 | (len(buf) << 16), buf)
os.close(fd)
"
	echo "$level" > "$STATE_FILE"
	echo "Keyboard backlight: level $level"
}

get_level()
{
	if [[ -f "$STATE_FILE" ]]; then
		cat "$STATE_FILE"
	else
		echo "0"
	fi
}

case "${1:-}" in
	"")
		current=$(get_level)
		next=$(( (current + 1) % 4 ))
		set_brightness "$next"
		;;
	set)
		set_brightness "${2:-3}"
		;;
	get)
		echo "Current level: $(get_level)"
		;;
	*)
		echo "Usage: kbd-backlight [set <0-3>|get]"
		exit 1
		;;
esac
