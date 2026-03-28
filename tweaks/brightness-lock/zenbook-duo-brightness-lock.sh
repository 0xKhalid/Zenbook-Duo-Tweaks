#!/usr/bin/env bash
set -euo pipefail

TARGET_OUTPUT="${TARGET_OUTPUT:-eDP-2}"
TARGET_BRIGHTNESS="${TARGET_BRIGHTNESS:-100}"
DEBUG_LOG="${DEBUG_LOG:-0}"

log()
{
	logger -t zenbook-duo-brightness-lock "$*"
}

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

run_kscreen_command()
{
	local command="$1"

	runuser -u "${SESSION_USER}" -- env \
		XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
		DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
		XDG_SESSION_TYPE="${SESSION_TYPE}" \
		kscreen-doctor "${command}" >/dev/null 2>&1
}

apply_brightness_lock()
{
	local primary_cmd="output.${TARGET_OUTPUT}.brightness.${TARGET_BRIGHTNESS}"
	if run_kscreen_command "${primary_cmd}"; then
		return 0
	fi

	# Fallback for builds expecting normalized brightness values.
	if [[ "${TARGET_BRIGHTNESS}" == "100" ]]; then
		if run_kscreen_command "output.${TARGET_OUTPUT}.brightness.1"; then
			return 0
		fi
	fi

	return 1
}

if ! command -v kscreen-doctor >/dev/null 2>&1; then
	log "ERROR: kscreen-doctor is not installed or not in PATH"
	exit 1
fi

if ! resolve_active_graphical_session; then
	# Not an error: no active graphical user session yet.
	exit 0
fi

if ! apply_brightness_lock; then
	if [[ "${DEBUG_LOG}" == "1" ]]; then
		log "WARNING: Failed to force ${TARGET_OUTPUT} brightness for user=${SESSION_USER}"
	fi
	exit 0
fi
