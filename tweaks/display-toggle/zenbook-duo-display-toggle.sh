#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
TARGET_OUTPUT="${TARGET_OUTPUT:-eDP-2}"
RETRY_COUNT="${RETRY_COUNT:-5}"
RETRY_DELAY_SEC="${RETRY_DELAY_SEC:-0.6}"
BOOT_MODE=false

log()
{
	logger -t zenbook-duo-display-toggle "$*"
}

usage()
{
	echo "Usage: $0 <attach|detach|boot>"
	echo "  attach -> disable ${TARGET_OUTPUT}"
	echo "  detach -> enable ${TARGET_OUTPUT}"
	echo "  boot   -> detect keyboard, then attach or detach"
}

if [[ "${ACTION}" != "attach" && "${ACTION}" != "detach" && "${ACTION}" != "boot" ]]; then
	usage
	exit 2
fi

if ! command -v kscreen-doctor >/dev/null 2>&1; then
	log "ERROR: kscreen-doctor is not installed or not in PATH"
	exit 1
fi

is_keyboard_present()
{
	awk '
	BEGIN { RS=""; Found=0 }
	{
		# Treat only the physically docked keyboard as "attached":
		# USB device 0b05:1cd7 (Primax). Bluetooth keyboard (0b05:1cd8)
		# should still be considered detached for display behavior.
		if ($0 ~ /Vendor=0b05/ &&
		    $0 ~ /Product=1cd7/ &&
		    $0 !~ /P: Phys=py-evdev-uinput/)
		{
			Found=1;
		}
	}
	END { exit(Found ? 0 : 1) }
	' /proc/bus/input/devices 2>/dev/null
}

# Boot mode: detect keyboard presence, resolve to attach/detach
if [[ "${ACTION}" == "boot" ]]; then
	BOOT_MODE=true
	RETRY_COUNT=30
	RETRY_DELAY_SEC=2
	if is_keyboard_present; then
		ACTION="attach"
		log "Boot check: keyboard present, will disable ${TARGET_OUTPUT}"
	else
		ACTION="detach"
		log "Boot check: keyboard absent, will enable ${TARGET_OUTPUT}"
	fi
fi

if [[ "${ACTION}" == "attach" ]]; then
	KSCREEN_CMD="output.${TARGET_OUTPUT}.disable"
else
	KSCREEN_CMD="output.${TARGET_OUTPUT}.enable"
fi

resolve_active_graphical_session()
{
	local session_id
	session_id="$(loginctl list-sessions --no-legend | awk '{print $1}' | while read -r sid; do
		state="$(loginctl show-session "${sid}" -p Active --value 2>/dev/null || true)"
		type="$(loginctl show-session "${sid}" -p Type --value 2>/dev/null || true)"
		class="$(loginctl show-session "${sid}" -p Class --value 2>/dev/null || true)"
		remote="$(loginctl show-session "${sid}" -p Remote --value 2>/dev/null || true)"
		if [[ "${state}" == "yes" && ("${type}" == "wayland" || "${type}" == "x11") && "${class}" == "user" && "${remote}" == "no" ]]; then
			echo "${sid}"
			break
		fi
	done)"

	if [[ -z "${session_id}" ]]; then
		return 1
	fi

	SESSION_UID="$(loginctl show-session "${session_id}" -p User --value)"
	SESSION_USER="$(getent passwd "${SESSION_UID}" | cut -d: -f1)"
	SESSION_TYPE="$(loginctl show-session "${session_id}" -p Type --value)"
	XDG_RUNTIME_DIR="/run/user/${SESSION_UID}"
	DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
	return 0
}

# In boot mode, retry session resolution since the desktop may not be ready yet
if [[ "${BOOT_MODE}" == true ]]; then
	SESSION_FOUND=false
	for session_attempt in $(seq 1 "${RETRY_COUNT}"); do
		if resolve_active_graphical_session; then
			SESSION_FOUND=true
			break
		fi
		log "Waiting for graphical session (attempt ${session_attempt}/${RETRY_COUNT})..."
		sleep "${RETRY_DELAY_SEC}"
	done
	if [[ "${SESSION_FOUND}" != true ]]; then
		log "ERROR: No graphical session found after ${RETRY_COUNT} attempts"
		exit 1
	fi
else
	if ! resolve_active_graphical_session; then
		log "ERROR: No active local graphical session found"
		exit 1
	fi
fi

for attempt in $(seq 1 "${RETRY_COUNT}"); do
	if runuser -u "${SESSION_USER}" -- env \
		XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
		DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
		XDG_SESSION_TYPE="${SESSION_TYPE}" \
		kscreen-doctor "${KSCREEN_CMD}" >/dev/null 2>&1; then
		log "SUCCESS: action=${ACTION}, output=${TARGET_OUTPUT}, user=${SESSION_USER}, attempt=${attempt}"
		exit 0
	fi
	sleep "${RETRY_DELAY_SEC}"
done

log "ERROR: Failed action=${ACTION}, output=${TARGET_OUTPUT}, user=${SESSION_USER} after ${RETRY_COUNT} attempts"
exit 1
