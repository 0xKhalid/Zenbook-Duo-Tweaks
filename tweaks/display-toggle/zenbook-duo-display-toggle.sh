#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
TARGET_OUTPUT="${TARGET_OUTPUT:-eDP-2}"
KSCREEN_RETRY_COUNT="${KSCREEN_RETRY_COUNT:-5}"
KSCREEN_RETRY_DELAY_SEC="${KSCREEN_RETRY_DELAY_SEC:-0.6}"
READY_RETRY_COUNT="${READY_RETRY_COUNT:-10}"
READY_RETRY_DELAY_SEC="${READY_RETRY_DELAY_SEC:-1}"
BOOT_READY_RETRY_COUNT="${BOOT_READY_RETRY_COUNT:-45}"
BOOT_READY_RETRY_DELAY_SEC="${BOOT_READY_RETRY_DELAY_SEC:-2}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-30}"
LOCK_WAIT_SEC="${LOCK_WAIT_SEC:-30}"
LOCK_FILE="${LOCK_FILE:-/run/zenbook-duo-display-toggle.lock}"
STATE_FILE="${STATE_FILE:-/run/zenbook-duo-display-toggle.state}"
BOOT_MODE=false
SESSION_UID=""
SESSION_USER=""
SESSION_TYPE=""
SESSION_DISPLAY=""
XDG_RUNTIME_DIR=""
DBUS_SESSION_BUS_ADDRESS=""
WAYLAND_DISPLAY_NAME=""
READY_REASON=""

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

if ! command -v flock >/dev/null 2>&1; then
	log "ERROR: flock is not installed or not in PATH"
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
	READY_RETRY_COUNT="${BOOT_READY_RETRY_COUNT}"
	READY_RETRY_DELAY_SEC="${BOOT_READY_RETRY_DELAY_SEC}"
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
	local state
	local type
	local class
	local remote
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
	SESSION_DISPLAY="$(loginctl show-session "${session_id}" -p Display --value 2>/dev/null || true)"
	XDG_RUNTIME_DIR="/run/user/${SESSION_UID}"
	DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
	return 0
}

check_graphical_session_ready()
{
	local Socket

	WAYLAND_DISPLAY_NAME=""
	READY_REASON=""

	if [[ -z "${SESSION_USER}" ]]; then
		READY_REASON="session user not resolved"
		return 1
	fi

	if [[ ! -d "${XDG_RUNTIME_DIR}" ]]; then
		READY_REASON="runtime dir missing: ${XDG_RUNTIME_DIR}"
		return 1
	fi

	if [[ ! -S "${XDG_RUNTIME_DIR}/bus" ]]; then
		READY_REASON="session DBus socket missing"
		return 1
	fi

	if [[ "${SESSION_TYPE}" == "wayland" ]]; then
		for Socket in "${XDG_RUNTIME_DIR}"/wayland-*; do
			if [[ -S "${Socket}" ]]; then
				WAYLAND_DISPLAY_NAME="$(basename "${Socket}")"
				break
			fi
		done

		if [[ -z "${WAYLAND_DISPLAY_NAME}" ]]; then
			READY_REASON="Wayland socket missing"
			return 1
		fi

		if ! pgrep -u "${SESSION_USER}" -x kwin_wayland >/dev/null 2>&1; then
			READY_REASON="kwin_wayland not running"
			return 1
		fi
	elif [[ "${SESSION_TYPE}" == "x11" ]]; then
		if [[ -z "${SESSION_DISPLAY}" ]]; then
			READY_REASON="X11 display missing"
			return 1
		fi

		if ! pgrep -u "${SESSION_USER}" -x kwin_x11 >/dev/null 2>&1; then
			READY_REASON="kwin_x11 not running"
			return 1
		fi
	else
		READY_REASON="unsupported session type: ${SESSION_TYPE:-unknown}"
		return 1
	fi

	return 0
}

wait_for_graphical_session_ready()
{
	local Attempt

	for Attempt in $(seq 1 "${READY_RETRY_COUNT}"); do
		if resolve_active_graphical_session && check_graphical_session_ready; then
			return 0
		fi

		if [[ -z "${READY_REASON}" ]]; then
			READY_REASON="no active local graphical session found"
		fi

		log "Waiting for KDE display readiness: ${READY_REASON} (attempt ${Attempt}/${READY_RETRY_COUNT})"
		sleep "${READY_RETRY_DELAY_SEC}"
	done

	log "ERROR: KDE display session not ready after ${READY_RETRY_COUNT} attempts: ${READY_REASON}"
	return 1
}

should_debounce_action()
{
	local Now
	local LastAction
	local LastTime
	local Age

	Now="$(date +%s)"

	if [[ ! -f "${STATE_FILE}" ]]; then
		return 1
	fi

	read -r LastAction LastTime < "${STATE_FILE}" || return 1
	if [[ "${LastAction}" != "${ACTION}" || ! "${LastTime}" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	Age=$((Now - LastTime))
	if (( Age >= 0 && Age < DEBOUNCE_SECONDS )); then
		log "Skipping duplicate action=${ACTION}, output=${TARGET_OUTPUT}, age=${Age}s"
		return 0
	fi

	return 1
}

mark_action_complete()
{
	printf '%s %s\n' "${ACTION}" "$(date +%s)" > "${STATE_FILE}"
}

run_kscreen_doctor()
{
	local EnvArgs
	EnvArgs=(
		"XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
		"DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}"
		"XDG_SESSION_TYPE=${SESSION_TYPE}"
	)

	if [[ "${SESSION_TYPE}" == "wayland" ]]; then
		EnvArgs+=(
			"WAYLAND_DISPLAY=${WAYLAND_DISPLAY_NAME}"
			"QT_QPA_PLATFORM=wayland"
		)
	elif [[ "${SESSION_TYPE}" == "x11" ]]; then
		EnvArgs+=(
			"DISPLAY=${SESSION_DISPLAY}"
			"QT_QPA_PLATFORM=xcb"
		)
	fi

	runuser -u "${SESSION_USER}" -- env "${EnvArgs[@]}" kscreen-doctor "${KSCREEN_CMD}" >/dev/null 2>&1
}

exec 9>"${LOCK_FILE}"
if ! flock -w "${LOCK_WAIT_SEC}" 9; then
	log "ERROR: Failed to acquire display toggle lock after ${LOCK_WAIT_SEC}s"
	exit 1
fi

if should_debounce_action; then
	exit 0
fi

if ! wait_for_graphical_session_ready; then
	exit 1
fi

for attempt in $(seq 1 "${KSCREEN_RETRY_COUNT}"); do
	if run_kscreen_doctor; then
		mark_action_complete
		log "SUCCESS: action=${ACTION}, output=${TARGET_OUTPUT}, user=${SESSION_USER}, attempt=${attempt}"
		exit 0
	fi
	sleep "${KSCREEN_RETRY_DELAY_SEC}"
done

log "ERROR: Failed action=${ACTION}, output=${TARGET_OUTPUT}, user=${SESSION_USER} after ${KSCREEN_RETRY_COUNT} attempts"
exit 1
