#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-monitor}"
REQUESTED_ORIENTATION="${2:-}"
TOP_OUTPUT="${TOP_OUTPUT:-eDP-1}"
BOTTOM_OUTPUT="${BOTTOM_OUTPUT:-eDP-2}"
LOWER_DISPLAY_PRIMARY_WHEN_DETACHED="${LOWER_DISPLAY_PRIMARY_WHEN_DETACHED:-0}"
PHYSICAL_KEYBOARD_VENDOR_ID="${PHYSICAL_KEYBOARD_VENDOR_ID:-0b05}"
PHYSICAL_KEYBOARD_PRODUCT_ID="${PHYSICAL_KEYBOARD_PRODUCT_ID:-1cd7}"
CONFIG_FILE="${CONFIG_FILE:-/etc/default/zenbook-duo-display-control}"
CONFIGURED_STABLE_SECONDS="$(awk -F= '/^[[:space:]]*ROTATION_STABILITY_DELAY_SECONDS[[:space:]]*=/ { value=$2 } END { gsub(/[[:space:]]/, "", value); print value }' "${CONFIG_FILE}" 2>/dev/null || true)"
STABLE_SECONDS="${ROTATION_STABILITY_DELAY_SECONDS:-${CONFIGURED_STABLE_SECONDS:-1}}"
if [[ ! "${STABLE_SECONDS}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] ||
	! LC_ALL=C awk -v value="${STABLE_SECONDS}" 'BEGIN { exit !(value >= 0 && value <= 10) }'
then
	STABLE_SECONDS=1
fi
EVENT_SETTLE_SECONDS="${EVENT_SETTLE_SECONDS:-1}"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-30}"
LOCK_FILE="${LOCK_FILE:-/run/zenbook-duo-display-control.lock}"
STATE_FILE="${STATE_FILE:-/run/zenbook-duo-display-control.state}"
READY_RETRY_COUNT="${READY_RETRY_COUNT:-15}"
READY_RETRY_DELAY_SECONDS="${READY_RETRY_DELAY_SECONDS:-1}"
BOOT_READY_RETRY_COUNT="${BOOT_READY_RETRY_COUNT:-45}"
BOOT_READY_RETRY_DELAY_SECONDS="${BOOT_READY_RETRY_DELAY_SECONDS:-2}"
KSCREEN_RETRY_COUNT="${KSCREEN_RETRY_COUNT:-5}"
KSCREEN_RETRY_DELAY_SECONDS="${KSCREEN_RETRY_DELAY_SECONDS:-0.6}"

SESSION_UID=""
SESSION_USER=""
SESSION_TYPE=""
SESSION_DISPLAY=""
XDG_RUNTIME_DIR=""
DBUS_SESSION_BUS_ADDRESS=""
WAYLAND_DISPLAY_NAME=""
READY_REASON=""
KSCREEN_ENV=()

log()
{
	logger -t zenbook-duo-display-control "$*"
}

usage()
{
	echo "Usage: $0 <monitor|sync|apply|status> [orientation]"
	echo "  monitor              reconcile at boot, then watch orientation events"
	echo "  sync                 reconcile keyboard state and current orientation"
	echo "  apply <orientation>  rotate enabled displays without changing enablement"
	echo "  status               show firmware, sensor, keyboard, and service policy"
}

is_keyboard_physically_docked()
{
	local device vendor_id product_id

	for device in /sys/bus/usb/devices/*; do
		[[ -r "${device}/idVendor" && -r "${device}/idProduct" ]] || continue
		read -r vendor_id < "${device}/idVendor" || continue
		read -r product_id < "${device}/idProduct" || continue
		if [[ "${vendor_id,,}" == "${PHYSICAL_KEYBOARD_VENDOR_ID,,}" &&
			"${product_id,,}" == "${PHYSICAL_KEYBOARD_PRODUCT_ID,,}" ]]
		then
			return 0
		fi
	done

	return 1
}

lower_display_should_be_primary()
{
	case "${LOWER_DISPLAY_PRIMARY_WHEN_DETACHED,,}" in
		1|true|yes|on) return 0 ;;
		*) return 1 ;;
	esac
}

resolve_active_graphical_session()
{
	local session_id state type class remote

	session_id="$(loginctl list-sessions --no-legend | awk '{print $1}' | while read -r sid; do
		state="$(loginctl show-session "${sid}" -p Active --value 2>/dev/null || true)"
		type="$(loginctl show-session "${sid}" -p Type --value 2>/dev/null || true)"
		class="$(loginctl show-session "${sid}" -p Class --value 2>/dev/null || true)"
		remote="$(loginctl show-session "${sid}" -p Remote --value 2>/dev/null || true)"
		if [[ "${state}" == "yes" && ("${type}" == "wayland" || "${type}" == "x11") &&
			"${class}" == "user" && "${remote}" == "no" ]]
		then
			echo "${sid}"
			break
		fi
	done)"

	[[ -n "${session_id}" ]] || return 1
	SESSION_UID="$(loginctl show-session "${session_id}" -p User --value)"
	SESSION_USER="$(getent passwd "${SESSION_UID}" | cut -d: -f1)"
	SESSION_TYPE="$(loginctl show-session "${session_id}" -p Type --value)"
	SESSION_DISPLAY="$(loginctl show-session "${session_id}" -p Display --value 2>/dev/null || true)"
	XDG_RUNTIME_DIR="/run/user/${SESSION_UID}"
	DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
}

check_graphical_session_ready()
{
	local socket

	WAYLAND_DISPLAY_NAME=""
	READY_REASON=""
	if [[ -z "${SESSION_USER}" ]]; then
		READY_REASON="session user not resolved"
		return 1
	fi
	if [[ ! -d "${XDG_RUNTIME_DIR}" || ! -S "${XDG_RUNTIME_DIR}/bus" ]]; then
		READY_REASON="session runtime or DBus socket missing"
		return 1
	fi

	if [[ "${SESSION_TYPE}" == "wayland" ]]; then
		for socket in "${XDG_RUNTIME_DIR}"/wayland-*; do
			if [[ -S "${socket}" ]]; then
				WAYLAND_DISPLAY_NAME="$(basename "${socket}")"
				break
			fi
		done
		if [[ -z "${WAYLAND_DISPLAY_NAME}" ]] || ! pgrep -u "${SESSION_USER}" -x kwin_wayland >/dev/null 2>&1; then
			READY_REASON="KDE Wayland session not ready"
			return 1
		fi
	elif [[ "${SESSION_TYPE}" == "x11" ]]; then
		if [[ -z "${SESSION_DISPLAY}" ]] || ! pgrep -u "${SESSION_USER}" -x kwin_x11 >/dev/null 2>&1; then
			READY_REASON="KDE X11 session not ready"
			return 1
		fi
	else
		READY_REASON="unsupported session type: ${SESSION_TYPE:-unknown}"
		return 1
	fi
}

build_kscreen_environment()
{
	KSCREEN_ENV=(
		"XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
		"DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}"
		"XDG_SESSION_TYPE=${SESSION_TYPE}"
	)
	if [[ "${SESSION_TYPE}" == "wayland" ]]; then
		KSCREEN_ENV+=("WAYLAND_DISPLAY=${WAYLAND_DISPLAY_NAME}" "QT_QPA_PLATFORM=wayland")
	else
		KSCREEN_ENV+=("DISPLAY=${SESSION_DISPLAY}" "QT_QPA_PLATFORM=xcb")
	fi
}

wait_for_graphical_session_ready()
{
	local attempt

	for attempt in $(seq 1 "${READY_RETRY_COUNT}"); do
		if resolve_active_graphical_session && check_graphical_session_ready; then
			build_kscreen_environment
			return 0
		fi
		[[ -n "${READY_REASON}" ]] || READY_REASON="no active local graphical session found"
		log "Waiting for KDE display readiness: ${READY_REASON} (${attempt}/${READY_RETRY_COUNT})"
		sleep "${READY_RETRY_DELAY_SECONDS}"
	done

	log "ERROR: KDE display session not ready: ${READY_REASON}"
	return 1
}

run_kscreen()
{
	runuser -u "${SESSION_USER}" -- env "${KSCREEN_ENV[@]}" kscreen-doctor "$@"
}

read_sensor_orientation()
{
	busctl --system get-property \
		net.hadess.SensorProxy \
		/net/hadess/SensorProxy \
		net.hadess.SensorProxy \
		AccelerometerOrientation 2>/dev/null | awk -F'"' '{print $2}'
}

orientation_is_valid()
{
	case "$1" in
		normal|bottom-up|left-up|right-up) return 0 ;;
		*) return 1 ;;
	esac
}

read_rotation_stability_delay()
{
	local value

	value="$(awk -F= '/^[[:space:]]*ROTATION_STABILITY_DELAY_SECONDS[[:space:]]*=/ { configured=$2 } END { gsub(/[[:space:]]/, "", configured); print configured }' "${CONFIG_FILE}" 2>/dev/null || true)"
	[[ -n "${value}" ]] || value="${ROTATION_STABILITY_DELAY_SECONDS:-1}"
	if [[ "${value}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] &&
		LC_ALL=C awk -v value="${value}" 'BEGIN { exit !(value >= 0 && value <= 10) }'
	then
		echo "${value}"
	else
		echo 1
	fi
}

set_orientation_geometry()
{
	local orientation="$1"

	case "${orientation}" in
		normal)
			TOP_ROTATION="inverted"; BOTTOM_ROTATION="none"
			TOP_POSITION="0,0"; BOTTOM_POSITION="0,1125"
			;;
		bottom-up)
			TOP_ROTATION="none"; BOTTOM_ROTATION="inverted"
			TOP_POSITION="0,1125"; BOTTOM_POSITION="0,0"
			;;
		left-up)
			TOP_ROTATION="right"; BOTTOM_ROTATION="left"
			TOP_POSITION="1125,0"; BOTTOM_POSITION="0,0"
			;;
		right-up)
			TOP_ROTATION="left"; BOTTOM_ROTATION="right"
			TOP_POSITION="0,0"; BOTTOM_POSITION="1125,0"
			;;
	esac
}

apply_display_state()
(
	local requested_mode="$1"
	local orientation="$2"
	local config_json connected_bottom enabled_top enabled_bottom state_mode
	local state_label saved_state primary_state attempt
	local args=()

	orientation_is_valid "${orientation}" || {
		log "ERROR: Invalid orientation: ${orientation}"
		return 2
	}

	exec 9>"${LOCK_FILE}"
	if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
		log "ERROR: Failed to acquire display-control lock"
		return 1
	fi

	if is_keyboard_physically_docked; then
		if [[ "${requested_mode}" == "rotate" ]]; then
			log "Ignoring orientation=${orientation}; physical keyboard is docked"
			return 0
		fi
		requested_mode="docked"
		orientation="normal"
	elif [[ "${requested_mode}" != "rotate" ]]; then
		requested_mode="detached"
	fi
	if [[ "${requested_mode}" == "docked" ]]; then
		state_mode="docked"
	else
		state_mode="detached"
	fi

	wait_for_graphical_session_ready || return 1
	config_json="$(run_kscreen -j 2>/dev/null)" || {
		log "ERROR: Failed to read KScreen configuration"
		return 1
	}
	connected_bottom="$(jq -r --arg name "${BOTTOM_OUTPUT}" '[.outputs[] | select(.name == $name and .connected == true)] | length > 0' <<< "${config_json}")"
	enabled_top="$(jq -r --arg name "${TOP_OUTPUT}" '[.outputs[] | select(.name == $name and .connected == true and .enabled == true)] | length > 0' <<< "${config_json}")"
	enabled_bottom="$(jq -r --arg name "${BOTTOM_OUTPUT}" '[.outputs[] | select(.name == $name and .connected == true and .enabled == true)] | length > 0' <<< "${config_json}")"
	primary_state=0
	lower_display_should_be_primary && primary_state=1
	state_label="${state_mode}:${orientation}:${enabled_top}:${enabled_bottom}:${primary_state}"
	saved_state="$(cat "${STATE_FILE}" 2>/dev/null || true)"
	if [[ "${requested_mode}" != "docked" && "${saved_state}" == "${state_label}" ]]; then
		log "Skipping unchanged state=${state_label}"
		return 0
	fi

	set_orientation_geometry "${orientation}"
	if [[ "${enabled_top}" == "true" ]]; then
		args+=("output.${TOP_OUTPUT}.rotation.${TOP_ROTATION}" "output.${TOP_OUTPUT}.position.${TOP_POSITION}")
	fi

	if [[ "${requested_mode}" == "docked" ]]; then
		if lower_display_should_be_primary && [[ "${enabled_top}" == "true" ]]; then
			args+=("output.${TOP_OUTPUT}.primary")
		fi
		if [[ "${enabled_bottom}" == "true" ]]; then
			args+=("output.${BOTTOM_OUTPUT}.rotation.none" "output.${BOTTOM_OUTPUT}.position.0,1125" "output.${BOTTOM_OUTPUT}.disable")
		fi
	elif [[ "${requested_mode}" == "detached" ]]; then
		if [[ "${connected_bottom}" == "true" ]]; then
			args+=("output.${BOTTOM_OUTPUT}.enable" "output.${BOTTOM_OUTPUT}.rotation.${BOTTOM_ROTATION}" "output.${BOTTOM_OUTPUT}.position.${BOTTOM_POSITION}")
			if lower_display_should_be_primary; then
				args+=("output.${BOTTOM_OUTPUT}.primary")
			fi
		fi
	elif [[ "${enabled_bottom}" == "true" ]]; then
		args+=("output.${BOTTOM_OUTPUT}.rotation.${BOTTOM_ROTATION}" "output.${BOTTOM_OUTPUT}.position.${BOTTOM_POSITION}")
	fi

	if [[ ${#args[@]} -eq 0 ]]; then
		log "No applicable built-in outputs; skipping state=${requested_mode}:${orientation}"
		return 0
	fi

	for attempt in $(seq 1 "${KSCREEN_RETRY_COUNT}"); do
		if run_kscreen "${args[@]}" >/dev/null 2>&1; then
			if [[ "${requested_mode}" == "docked" ]]; then
				printf '%s\n' "docked:normal:${enabled_top}:false:${primary_state}" > "${STATE_FILE}"
			elif [[ "${requested_mode}" == "detached" ]]; then
				printf '%s\n' "detached:${orientation}:${enabled_top}:${connected_bottom}:${primary_state}" > "${STATE_FILE}"
			else
				printf '%s\n' "detached:${orientation}:${enabled_top}:${enabled_bottom}:${primary_state}" > "${STATE_FILE}"
			fi
			log "SUCCESS: mode=${requested_mode}, orientation=${orientation}, top=${enabled_top}, bottom=${connected_bottom}, primary=${primary_state}, user=${SESSION_USER}, attempt=${attempt}"
			return 0
		fi
		sleep "${KSCREEN_RETRY_DELAY_SECONDS}"
	done

	log "ERROR: Failed mode=${requested_mode}, orientation=${orientation}, user=${SESSION_USER}"
	return 1
)

sync_state()
{
	local boot_mode="${1:-false}"
	local orientation

	if [[ "${boot_mode}" == "true" ]]; then
		READY_RETRY_COUNT="${BOOT_READY_RETRY_COUNT}"
		READY_RETRY_DELAY_SECONDS="${BOOT_READY_RETRY_DELAY_SECONDS}"
	else
		sleep "${EVENT_SETTLE_SECONDS}"
	fi

	if is_keyboard_physically_docked; then
		apply_display_state docked normal
		return
	fi

	orientation="$(read_sensor_orientation || true)"
	if ! orientation_is_valid "${orientation}"; then
		orientation="normal"
		log "Current orientation unavailable; using normal for detached reconciliation"
	fi
	apply_display_state detached "${orientation}"
}

monitor_orientations()
{
	local line pending latest

	command -v monitor-sensor >/dev/null 2>&1 || {
		log "ERROR: monitor-sensor is not installed"
		return 1
	}
	STABLE_SECONDS="$(read_rotation_stability_delay)"
	log "Starting accelerometer monitor with stable_seconds=${STABLE_SECONDS}"
	while IFS= read -r line; do
		if [[ "${line}" =~ Accelerometer\ orientation\ changed:\ ([a-z-]+) ]]; then
			pending="${BASH_REMATCH[1]}"
			orientation_is_valid "${pending}" || continue
			STABLE_SECONDS="$(read_rotation_stability_delay)"
			sleep "${STABLE_SECONDS}"
			latest="$(read_sensor_orientation || true)"
			if [[ "${latest}" == "${pending}" ]]; then
				apply_display_state rotate "${latest}" || true
			else
				log "Ignoring unstable orientation=${pending}, latest=${latest:-unknown}"
			fi
		fi
	done < <(stdbuf -oL monitor-sensor --accel)

	log "ERROR: accelerometer monitor exited"
	return 1
}

show_status()
{
	local firmware="/usr/lib/firmware/updates/intel/ish/ish_ptl.bin"
	local found_accel=false dev name orientation rotation_delay

	if [[ -f "${firmware}" ]]; then
		echo "Firmware override: installed"
		echo "Firmware SHA-256: $(sha256sum "${firmware}" | awk '{print $1}')"
	else
		echo "Firmware override: missing"
	fi
	for dev in /sys/bus/iio/devices/iio:device*; do
		[[ -d "${dev}" ]] || continue
		name="$(cat "${dev}/name" 2>/dev/null || true)"
		if [[ "${name}" == "accel_3d" ]] || find "${dev}" -maxdepth 1 -type f -name 'in_accel_*' -print -quit | grep -q .; then
			echo "Accelerometer: ${name} (${dev##*/})"
			found_accel=true
		fi
	done
	[[ "${found_accel}" == true ]] || echo "Accelerometer: not exposed (reboot may be required)"
	orientation="$(read_sensor_orientation || true)"
	rotation_delay="$(read_rotation_stability_delay)"
	echo "Current orientation: ${orientation:-unavailable}"
	echo "Rotation stability delay: ${rotation_delay} second(s)"
	if is_keyboard_physically_docked; then
		echo "Keyboard policy: docked; eDP-2 disabled and rotation suspended"
	else
		echo "Keyboard policy: detached; eDP-2 enabled and rotation active"
	fi
}

case "${ACTION}" in
	monitor)
		sync_state true
		monitor_orientations
		;;
	sync) sync_state false ;;
	apply)
		orientation_is_valid "${REQUESTED_ORIENTATION}" || { usage; exit 2; }
		apply_display_state rotate "${REQUESTED_ORIENTATION}"
		;;
	status) show_status ;;
	*) usage; exit 2 ;;
esac
