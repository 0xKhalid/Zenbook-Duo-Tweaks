#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
TARGET_OUTPUT="${TARGET_OUTPUT:-eDP-2}"
RETRY_COUNT="${RETRY_COUNT:-5}"
RETRY_DELAY_SEC="${RETRY_DELAY_SEC:-0.6}"

log()
{
	logger -t zenbook-duo-display-toggle "$*"
}

usage()
{
	echo "Usage: $0 <attach|detach>"
	echo "  attach -> disable ${TARGET_OUTPUT}"
	echo "  detach -> enable ${TARGET_OUTPUT}"
}

if [[ "${ACTION}" != "attach" && "${ACTION}" != "detach" ]]; then
	usage
	exit 2
fi

if ! command -v kscreen-doctor >/dev/null 2>&1; then
	log "ERROR: kscreen-doctor is not installed or not in PATH"
	exit 1
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

if ! resolve_active_graphical_session; then
	log "ERROR: No active local graphical session found"
	exit 1
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
