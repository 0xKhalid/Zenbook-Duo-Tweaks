#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-monitor}"
REQUESTED_ORIENTATION="${2:-}"
TOP_OUTPUT="${TOP_OUTPUT:-eDP-1}"
BOTTOM_OUTPUT="${BOTTOM_OUTPUT:-eDP-2}"
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
ICON_LAYOUT_SCRIPT="${ICON_LAYOUT_SCRIPT:-/usr/local/share/zenbook-duo-display-control/zenbook-duo-icon-layout.js}"
if [[ ! -r "${ICON_LAYOUT_SCRIPT}" && -r "$(dirname "${BASH_SOURCE[0]}")/zenbook-duo-icon-layout.js" ]]; then
	ICON_LAYOUT_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/zenbook-duo-icon-layout.js"
fi
ICON_LAYOUT_RETRY_COUNT="${ICON_LAYOUT_RETRY_COUNT:-10}"
ICON_LAYOUT_RETRY_DELAY_SECONDS="${ICON_LAYOUT_RETRY_DELAY_SECONDS:-0.3}"
ICON_LAYOUT_BACKUP_ROOT="${ICON_LAYOUT_BACKUP_ROOT:-/var/lib/zenbook-tweaks/backups}"
ICON_LAYOUT_STATE_DIR="${ICON_LAYOUT_STATE_DIR:-/var/lib/zenbook-tweaks/state}"
UPPER_TOUCH_VENDOR_HEX="${UPPER_TOUCH_VENDOR_HEX:-2386}"
UPPER_TOUCH_PRODUCT_HEX="${UPPER_TOUCH_PRODUCT_HEX:-8c05}"
UPPER_TOUCH_VENDOR_DECIMAL="${UPPER_TOUCH_VENDOR_DECIMAL:-9094}"
UPPER_TOUCH_PRODUCT_DECIMAL="${UPPER_TOUCH_PRODUCT_DECIMAL:-35845}"
UPPER_TOUCH_NAME="${UPPER_TOUCH_NAME:-RAYD0001:00 2386:8C05}"
UPPER_TOUCH_UDEV_MATRIX="${UPPER_TOUCH_UDEV_MATRIX:--1 0 1 0 -1 1}"
UPPER_TOUCH_KWIN_MATRIX="${UPPER_TOUCH_KWIN_MATRIX:--1,0,1,0,0,-1,1,0,0,0,1,0,0,0,0,1}"
IDENTITY_KWIN_MATRIX="${IDENTITY_KWIN_MATRIX:-1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}"
TOUCH_CALIBRATION_BACKUP_ROOT="${TOUCH_CALIBRATION_BACKUP_ROOT:-/var/lib/zenbook-tweaks/backups}"
TOUCH_CALIBRATION_STATE_DIR="${TOUCH_CALIBRATION_STATE_DIR:-/var/lib/zenbook-tweaks/state}"
MISSING_KCONFIG_VALUE="__ZENBOOK_DUO_MISSING__"

SESSION_UID=""
SESSION_USER=""
SESSION_HOME=""
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
	echo "Usage: $0 <monitor|sync|apply|fit-icons|status> [orientation]"
	echo "  monitor              reconcile at boot, then watch orientation events"
	echo "  sync                 reconcile keyboard state and current orientation"
	echo "  apply <orientation>  reconcile keyboard state at the requested orientation"
	echo "  fit-icons [orientation]"
	echo "                       fit Folder View icons to the current portrait grids"
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

read_primary_display_preference()
{
	local value legacy_value

	value="$(awk -F= '/^[[:space:]]*PRIMARY_DISPLAY_WHEN_DETACHED[[:space:]]*=/ { value=$2 } END { gsub(/[[:space:]]/, "", value); print tolower(value) }' "${CONFIG_FILE}" 2>/dev/null || true)"
	if [[ -z "${value}" ]]; then
		value="${PRIMARY_DISPLAY_WHEN_DETACHED:-}"
	fi
	case "${value,,}" in
		upper|lower) echo "${value,,}"; return ;;
	esac

	legacy_value="$(awk -F= '/^[[:space:]]*LOWER_DISPLAY_PRIMARY_WHEN_DETACHED[[:space:]]*=/ { value=$2 } END { gsub(/[[:space:]]/, "", value); print tolower(value) }' "${CONFIG_FILE}" 2>/dev/null || true)"
	if [[ -z "${legacy_value}" ]]; then
		legacy_value="${LOWER_DISPLAY_PRIMARY_WHEN_DETACHED:-0}"
	fi
	case "${legacy_value,,}" in
		1|true|yes|on) echo lower ;;
		*) echo upper ;;
	esac
}

primary_output_from_json()
{
	jq -r '[.outputs[] | select(.connected == true and .enabled == true and (((.priority // 0) == 1) or ((.primary // false) == true))) | .name][0] // "unknown"'
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
	SESSION_HOME="$(getent passwd "${SESSION_UID}" | cut -d: -f6)"
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
	if [[ "${EUID}" -eq "${SESSION_UID}" ]]; then
		env "${KSCREEN_ENV[@]}" kscreen-doctor "$@"
	else
		runuser -u "${SESSION_USER}" -- env "${KSCREEN_ENV[@]}" kscreen-doctor "$@"
	fi
}

run_session_command()
{
	local session_environment=(
		"HOME=${SESSION_HOME}"
		"XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
		"DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}"
	)

	if [[ "${EUID}" -eq "${SESSION_UID}" ]]; then
		env "${session_environment[@]}" "$@"
	else
		runuser -u "${SESSION_USER}" -- env "${session_environment[@]}" "$@"
	fi
}

run_session_busctl()
{
	run_session_command busctl --user -- "$@"
}

find_upper_touch_sysname()
{
	local path vendor product name

	for path in /sys/class/input/event*; do
		[[ -r "${path}/device/id/vendor" && -r "${path}/device/id/product" && -r "${path}/device/name" ]] || continue
		read -r vendor < "${path}/device/id/vendor" || continue
		read -r product < "${path}/device/id/product" || continue
		read -r name < "${path}/device/name" || continue
		if [[ "${vendor,,}" == "${UPPER_TOUCH_VENDOR_HEX,,}" &&
			"${product,,}" == "${UPPER_TOUCH_PRODUCT_HEX,,}" &&
			"${name}" == "${UPPER_TOUCH_NAME}" ]]
		then
			basename "${path}"
			return 0
		fi
	done

	return 1
}

kwin_input_string_property()
{
	local sysname="$1"
	local property="$2"

	run_session_busctl get-property \
		org.kde.KWin \
		"/org/kde/KWin/InputDevice/${sysname}" \
		org.kde.KWin.InputDevice \
		"${property}" 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p'
}

set_kwin_input_calibration()
{
	local sysname="$1"
	local matrix="$2"

	run_session_busctl set-property \
		org.kde.KWin \
		"/org/kde/KWin/InputDevice/${sysname}" \
		org.kde.KWin.InputDevice \
		calibrationMatrix s "${matrix}"
}

read_saved_upper_touch_calibration()
{
	run_session_command kreadconfig6 \
		--file kcminputrc \
		--group Libinput \
		--group "${UPPER_TOUCH_VENDOR_DECIMAL}" \
		--group "${UPPER_TOUCH_PRODUCT_DECIMAL}" \
		--group "${UPPER_TOUCH_NAME}" \
		--key CalibrationMatrix \
		--default "${MISSING_KCONFIG_VALUE}"
}

restore_saved_upper_touch_calibration_key()
{
	local saved_value="$1"
	local args=(
		--file kcminputrc
		--group Libinput
		--group "${UPPER_TOUCH_VENDOR_DECIMAL}"
		--group "${UPPER_TOUCH_PRODUCT_DECIMAL}"
		--group "${UPPER_TOUCH_NAME}"
		--key CalibrationMatrix
	)

	if [[ "${saved_value}" == "${MISSING_KCONFIG_VALUE}" ]]; then
		run_session_command kwriteconfig6 "${args[@]}" --delete
	else
		run_session_command kwriteconfig6 "${args[@]}" "${saved_value}"
	fi
}

backup_touch_input_config()
{
	local marker config_file timestamp backup_dir

	[[ -n "${SESSION_UID}" && -n "${SESSION_HOME}" ]] || return 1
	marker="${TOUCH_CALIBRATION_STATE_DIR}/duo-display-control-touch-calibration-backup-${SESSION_UID}"
	[[ -f "${marker}" ]] && return 0

	timestamp="$(date +%Y%m%d-%H%M%S)"
	backup_dir="${TOUCH_CALIBRATION_BACKUP_ROOT}/duo-display-control-touch-calibration-pre-v2.8-${timestamp}-${SESSION_UID}"
	config_file="${SESSION_HOME}/.config/kcminputrc"
	install -d -m 700 "${backup_dir}" "${TOUCH_CALIBRATION_STATE_DIR}"
	if [[ -f "${config_file}" ]]; then
		install -m 600 "${config_file}" "${backup_dir}/kcminputrc"
	else
		printf '%s\n' "kcminputrc did not exist before touch calibration" > "${backup_dir}/kcminputrc.missing"
		chmod 600 "${backup_dir}/kcminputrc.missing"
	fi
	printf '%s\n' "${backup_dir}" > "${marker}"
	chmod 600 "${marker}"
	log "Saved pre-v2.8 touch-input backup: ${backup_dir}"
}

ensure_upper_touch_calibration()
{
	local sysname output_name live_matrix saved_value

	sysname="$(find_upper_touch_sysname || true)"
	[[ -n "${sysname}" ]] || {
		log "ERROR: Upper touchscreen ${UPPER_TOUCH_VENDOR_HEX}:${UPPER_TOUCH_PRODUCT_HEX} was not found"
		return 1
	}
	output_name="$(kwin_input_string_property "${sysname}" outputName || true)"
	[[ "${output_name}" == "${TOP_OUTPUT}" ]] || {
		log "ERROR: Refusing upper-touch calibration; ${sysname} maps to ${output_name:-no output}, not ${TOP_OUTPUT}"
		return 1
	}
	backup_touch_input_config || return 1
	live_matrix="$(kwin_input_string_property "${sysname}" calibrationMatrix || true)"
	[[ -n "${live_matrix}" ]] || {
		log "ERROR: Could not read KWin calibration for ${sysname}"
		return 1
	}
	[[ "${live_matrix}" == "${UPPER_TOUCH_KWIN_MATRIX}" ]] && return 0

	saved_value="$(read_saved_upper_touch_calibration || true)"
	[[ -n "${saved_value}" ]] || saved_value="${MISSING_KCONFIG_VALUE}"
	if ! set_kwin_input_calibration "${sysname}" "${UPPER_TOUCH_KWIN_MATRIX}"; then
		log "ERROR: Could not apply upper-touch calibration to ${sysname}"
		return 1
	fi
	if ! restore_saved_upper_touch_calibration_key "${saved_value}"; then
		set_kwin_input_calibration "${sysname}" "${live_matrix}" >/dev/null 2>&1 || true
		log "ERROR: Could not preserve the saved KWin touch configuration"
		return 1
	fi
	if [[ "$(kwin_input_string_property "${sysname}" calibrationMatrix || true)" != "${UPPER_TOUCH_KWIN_MATRIX}" ]]; then
		log "ERROR: Upper-touch calibration verification failed for ${sysname}"
		return 1
	fi
	log "Applied 180-degree base calibration to upper touchscreen ${sysname} on ${TOP_OUTPUT}"
}

restore_upper_touch_calibration()
{
	local sysname saved_value restore_matrix

	sysname="$(find_upper_touch_sysname || true)"
	[[ -n "${sysname}" ]] || return 0
	saved_value="$(read_saved_upper_touch_calibration || true)"
	[[ -n "${saved_value}" ]] || saved_value="${MISSING_KCONFIG_VALUE}"
	if [[ "${saved_value}" == "${MISSING_KCONFIG_VALUE}" ]]; then
		restore_matrix="${IDENTITY_KWIN_MATRIX}"
	else
		restore_matrix="${saved_value}"
	fi
	set_kwin_input_calibration "${sysname}" "${restore_matrix}" || return 1
	restore_saved_upper_touch_calibration_key "${saved_value}" || return 1
	log "Restored upper touchscreen ${sysname} calibration for uninstall"
}

run_plasma_script()
{
	local script_source="$1"

	if [[ "${EUID}" -eq "${SESSION_UID}" ]]; then
		env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}" "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}" \
			gdbus call --session \
			--dest org.kde.plasmashell \
			--object-path /PlasmaShell \
			--method org.kde.PlasmaShell.evaluateScript \
			"${script_source}"
	else
		runuser -u "${SESSION_USER}" -- env \
			"XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}" \
			"DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}" \
			gdbus call --session \
			--dest org.kde.plasmashell \
			--object-path /PlasmaShell \
			--method org.kde.PlasmaShell.evaluateScript \
			"${script_source}"
	fi
}

builtin_output_geometries()
{
	local config_json="$1"

	jq -c --arg top "${TOP_OUTPUT}" --arg bottom "${BOTTOM_OUTPUT}" '
		[.outputs[]
		| select((.name == $top or .name == $bottom) and .connected == true and .enabled == true)
		| . as $output
		| ([.modes[] | select(.id == $output.currentModeId)][0]) as $mode
		| select($mode != null and (.scale | numbers) > 0)
		| (($mode.size.width / .scale) | round) as $width
		| (($mode.size.height / .scale) | round) as $height
		| {
			x: (.pos.x | round),
			y: (.pos.y | round),
			width: (if .rotation == 2 or .rotation == 8 then $height else $width end),
			height: (if .rotation == 2 or .rotation == 8 then $width else $height end)
		}]' <<< "${config_json}"
}

backup_plasma_icon_layout()
{
	local marker config_file timestamp backup_dir

	[[ -n "${SESSION_UID}" && -n "${SESSION_HOME}" ]] || return 1
	config_file="${SESSION_HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"
	[[ -f "${config_file}" ]] || {
		log "ERROR: Plasma desktop configuration not found for icon-layout backup"
		return 1
	}
	marker="${ICON_LAYOUT_STATE_DIR}/duo-display-control-icon-layout-backup-${SESSION_UID}"
	[[ -f "${marker}" ]] && return 0

	timestamp="$(date +%Y%m%d-%H%M%S)"
	backup_dir="${ICON_LAYOUT_BACKUP_ROOT}/duo-display-control-icon-layout-pre-v2.8-${timestamp}-${SESSION_UID}"
	install -d -m 700 "${backup_dir}" "${ICON_LAYOUT_STATE_DIR}"
	install -m 600 "${config_file}" "${backup_dir}/plasma-org.kde.plasma.desktop-appletsrc"
	printf '%s\n' "${backup_dir}" > "${marker}"
	chmod 600 "${marker}"
	log "Saved pre-v2.8 Plasma icon-layout backup: ${backup_dir}"
}

run_icon_layout_phase()
{
	local phase="$1"
	local orientation="$2"
	local geometries="$3"
	local dry_run="${4:-false}"
	local prefix script_body output

	[[ -r "${ICON_LAYOUT_SCRIPT}" ]] || {
		log "ERROR: Icon-layout helper is missing: ${ICON_LAYOUT_SCRIPT}"
		return 1
	}
	jq -e 'type == "array" and all(.[]; (.x | numbers) and (.y | numbers) and (.width | numbers) and (.height | numbers))' \
		<<< "${geometries}" >/dev/null || {
		log "ERROR: Invalid built-in output geometry for icon-layout phase=${phase}"
		return 1
	}
	if [[ "${dry_run}" != "true" ]]; then
		backup_plasma_icon_layout || return 1
	fi

	prefix="var ZENBOOK_PHASE=$(jq -Rn --arg value "${phase}" '$value');"
	prefix+="var ZENBOOK_ORIENTATION=$(jq -Rn --arg value "${orientation}" '$value');"
	prefix+="var ZENBOOK_TARGET_GEOMETRIES=${geometries};"
	prefix+="var ZENBOOK_DRY_RUN=${dry_run};"
	script_body="$(<"${ICON_LAYOUT_SCRIPT}")"
	output="$(run_plasma_script "${prefix}${script_body}" 2>&1)" || {
		log "ERROR: Plasma icon-layout script failed to execute: ${output}"
		return 1
	}
	if [[ "${output}" == *'"status":"ok"'* ]]; then
		log "Icon-layout phase=${phase} orientation=${orientation}: ${output}"
		return 0
	fi
	if [[ "${output}" == *'"status":"waiting"'* ]]; then
		return 3
	fi
	log "ERROR: Plasma icon-layout phase=${phase} failed: ${output}"
	return 1
}

prepare_icon_layout()
{
	local orientation="$1"
	local geometries="$2"
	local dry_run="${3:-false}"

	[[ "$(jq 'length' <<< "${geometries}")" -eq 2 ]] || return 0
	run_icon_layout_phase prepare "${orientation}" "${geometries}" "${dry_run}"
}

fit_icon_layout()
{
	local orientation="$1"
	local geometries="$2"
	local dry_run="${3:-false}"
	local attempt result

	case "${orientation}" in
		left-up|right-up) ;;
		*) return 0 ;;
	esac
	for attempt in $(seq 1 "${ICON_LAYOUT_RETRY_COUNT}"); do
		if run_icon_layout_phase fit "${orientation}" "${geometries}" "${dry_run}"; then
			return 0
		else
			result=$?
		fi
		[[ "${result}" -eq 3 ]] || return "${result}"
		sleep "${ICON_LAYOUT_RETRY_DELAY_SECONDS}"
	done
	log "ERROR: Plasma did not expose both portrait Folder View geometries in time"
	return 1
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
	local config_json connected_bottom enabled_top enabled_bottom target_bottom_enabled current_primary
	local state_label saved_state primary_preference target_primary attempt current_geometries target_geometries
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
	else
		# Sensor events and explicit syncs enforce the same physical invariant.
		# This prevents a resume-time rotation from recording a disabled lower
		# panel as the desired detached state before the USB sync can enable it.
		requested_mode="detached"
	fi

	wait_for_graphical_session_ready || return 1
	if ! ensure_upper_touch_calibration; then
		log "WARNING: Display reconciliation will continue without the upper-touch calibration"
	fi
	config_json="$(run_kscreen -j 2>/dev/null)" || {
		log "ERROR: Failed to read KScreen configuration"
		return 1
	}
	connected_bottom="$(jq -r --arg name "${BOTTOM_OUTPUT}" '[.outputs[] | select(.name == $name and .connected == true)] | length > 0' <<< "${config_json}")"
	enabled_top="$(jq -r --arg name "${TOP_OUTPUT}" '[.outputs[] | select(.name == $name and .connected == true and .enabled == true)] | length > 0' <<< "${config_json}")"
	enabled_bottom="$(jq -r --arg name "${BOTTOM_OUTPUT}" '[.outputs[] | select(.name == $name and .connected == true and .enabled == true)] | length > 0' <<< "${config_json}")"
	if [[ "${requested_mode}" == "detached" ]]; then
		target_bottom_enabled="${connected_bottom}"
	else
		target_bottom_enabled=false
	fi
	primary_preference="$(read_primary_display_preference)"
	current_primary="$(primary_output_from_json <<< "${config_json}")"
	target_primary="${TOP_OUTPUT}"
	if [[ "${requested_mode}" == detached && "${primary_preference}" == lower &&
		"${connected_bottom}" == true ]]
	then
		target_primary="${BOTTOM_OUTPUT}"
	fi
	state_label="${requested_mode}:${orientation}:${enabled_top}:${target_bottom_enabled}:${primary_preference}"
	saved_state="$(cat "${STATE_FILE}" 2>/dev/null || true)"
	if [[ "${requested_mode}" != "docked" && "${saved_state}" == "${state_label}" &&
		"${current_primary}" == "${target_primary}" ]]
	then
		current_geometries="$(builtin_output_geometries "${config_json}")"
		if ! prepare_icon_layout "${orientation}" "${current_geometries}"; then
			log "WARNING: Could not isolate the unchanged portrait and landscape icon profiles"
		fi
		if ! fit_icon_layout "${orientation}" "${current_geometries}" false; then
			log "WARNING: Display state is unchanged, but portrait icon fitting failed"
		fi
		log "Skipping unchanged state=${state_label}"
		return 0
	fi
	current_geometries="$(builtin_output_geometries "${config_json}")"
	if ! prepare_icon_layout "${orientation}" "${current_geometries}"; then
		log "WARNING: Could not clear cross-orientation icon changes before display update"
	fi

	set_orientation_geometry "${orientation}"
	if [[ "${enabled_top}" == "true" ]]; then
		args+=("output.${TOP_OUTPUT}.rotation.${TOP_ROTATION}" "output.${TOP_OUTPUT}.position.${TOP_POSITION}")
	fi

	if [[ "${requested_mode}" == "docked" ]]; then
		if [[ "${enabled_bottom}" == "true" ]]; then
			args+=("output.${BOTTOM_OUTPUT}.rotation.none" "output.${BOTTOM_OUTPUT}.position.0,1125" "output.${BOTTOM_OUTPUT}.disable")
		fi
	else
		if [[ "${connected_bottom}" == "true" ]]; then
			args+=("output.${BOTTOM_OUTPUT}.enable" "output.${BOTTOM_OUTPUT}.rotation.${BOTTOM_ROTATION}" "output.${BOTTOM_OUTPUT}.position.${BOTTOM_POSITION}")
		fi
	fi
	if [[ "${target_primary}" == "${TOP_OUTPUT}" && "${enabled_top}" == true ]] ||
		[[ "${target_primary}" == "${BOTTOM_OUTPUT}" && ("${connected_bottom}" == true || "${enabled_bottom}" == true) ]]
	then
		args+=("output.${target_primary}.primary")
	fi

	if [[ ${#args[@]} -eq 0 ]]; then
		log "No applicable built-in outputs; skipping state=${requested_mode}:${orientation}"
		return 0
	fi

	for attempt in $(seq 1 "${KSCREEN_RETRY_COUNT}"); do
		if run_kscreen "${args[@]}" >/dev/null 2>&1; then
			if [[ "${requested_mode}" == "docked" ]]; then
				printf '%s\n' "docked:normal:${enabled_top}:false:${primary_preference}" > "${STATE_FILE}"
			else
				printf '%s\n' "detached:${orientation}:${enabled_top}:${connected_bottom}:${primary_preference}" > "${STATE_FILE}"
			fi
			log "SUCCESS: mode=${requested_mode}, orientation=${orientation}, top=${enabled_top}, bottom=${connected_bottom}, primary=${target_primary}, preference=${primary_preference}, user=${SESSION_USER}, attempt=${attempt}"
			if [[ "${requested_mode}" != "docked" ]]; then
				config_json="$(run_kscreen -j 2>/dev/null || true)"
				if [[ -n "${config_json}" ]]; then
					target_geometries="$(builtin_output_geometries "${config_json}")"
					if ! prepare_icon_layout "${orientation}" "${target_geometries}"; then
						log "WARNING: Could not isolate the portrait and landscape icon profiles"
					fi
					if ! fit_icon_layout "${orientation}" "${target_geometries}" false; then
						log "WARNING: Display rotation succeeded, but portrait icon fitting failed"
					fi
				else
					log "WARNING: Display rotation succeeded, but KScreen geometry could not be refreshed for icon fitting"
				fi
			fi
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

fit_icons_now()
(
	local orientation="${1:-}"
	local config_json geometries dry_run="${ICON_LAYOUT_DRY_RUN:-false}"

	exec 9>"${LOCK_FILE}"
	if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
		log "ERROR: Failed to acquire display-control lock for icon fitting"
		return 1
	fi
	if is_keyboard_physically_docked; then
		echo "Icon fitting is inactive while the physical keyboard is docked."
		return 1
	fi
	if [[ -z "${orientation}" ]]; then
		orientation="$(read_sensor_orientation || true)"
	fi
	orientation_is_valid "${orientation}" || {
		log "ERROR: Invalid orientation for icon fitting: ${orientation:-unknown}"
		return 2
	}
	wait_for_graphical_session_ready || return 1
	config_json="$(run_kscreen -j 2>/dev/null)" || {
		log "ERROR: Failed to read KScreen configuration for icon fitting"
		return 1
	}
	geometries="$(builtin_output_geometries "${config_json}")"
	if [[ "$(jq 'length' <<< "${geometries}")" -ne 2 ]]; then
		echo "Icon fitting requires both built-in displays to be enabled."
		return 1
	fi
	prepare_icon_layout "${orientation}" "${geometries}" "${dry_run}" || {
		log "ERROR: Could not isolate portrait and landscape icon profiles"
		return 1
	}
	fit_icon_layout "${orientation}" "${geometries}" "${dry_run}" || return 1
	if [[ "${orientation}" == "left-up" || "${orientation}" == "right-up" ]]; then
		echo "Portrait desktop icons were fitted to the visible grids."
	else
		echo "Landscape layout is preserved; no icon fitting was needed."
	fi
)

restore_touch_for_uninstall()
(
	exec 9>"${LOCK_FILE}"
	if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
		log "ERROR: Failed to acquire display-control lock for touch restoration"
		return 1
	fi
	if ! resolve_active_graphical_session || ! check_graphical_session_ready; then
		log "Upper-touch live restoration deferred; no ready graphical session"
		return 0
	fi
	build_kscreen_environment
	restore_upper_touch_calibration
)

show_touch_calibration_status()
{
	local sysname udev_matrix live_matrix output_name

	sysname="$(find_upper_touch_sysname || true)"
	if [[ -z "${sysname}" ]]; then
		echo "Upper touchscreen: not found (${UPPER_TOUCH_VENDOR_HEX}:${UPPER_TOUCH_PRODUCT_HEX})"
		return
	fi
	udev_matrix="$(udevadm info --query=property --name="/dev/input/${sysname}" 2>/dev/null |
		awk -F= '/^LIBINPUT_CALIBRATION_MATRIX=/{print substr($0, index($0, "=") + 1)}')"
	if [[ "${udev_matrix}" == "${UPPER_TOUCH_UDEV_MATRIX}" ]]; then
		echo "Upper touchscreen: ${sysname}; persistent 180-degree base calibration active"
	else
		echo "Upper touchscreen: ${sysname}; persistent base calibration missing"
	fi
	if resolve_active_graphical_session && check_graphical_session_ready; then
		build_kscreen_environment
		output_name="$(kwin_input_string_property "${sysname}" outputName || true)"
		live_matrix="$(kwin_input_string_property "${sysname}" calibrationMatrix || true)"
		if [[ "${output_name}" == "${TOP_OUTPUT}" && "${live_matrix}" == "${UPPER_TOUCH_KWIN_MATRIX}" ]]; then
			echo "Upper touchscreen live mapping: calibrated on ${TOP_OUTPUT}"
		else
			echo "Upper touchscreen live mapping: not calibrated (${output_name:-unmapped})"
		fi
	else
		echo "Upper touchscreen live mapping: graphical session unavailable"
	fi
}

show_status()
{
	local firmware="/usr/lib/firmware/updates/intel/ish/ish_ptl.bin"
	local found_accel=false dev name orientation rotation_delay primary_preference config_json active_primary

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
	primary_preference="$(read_primary_display_preference)"
	echo "Current orientation: ${orientation:-unavailable}"
	echo "Rotation stability delay: ${rotation_delay} second(s)"
	if [[ "${primary_preference}" == lower ]]; then
		echo "Primary display preference (detached): Lower screen (${BOTTOM_OUTPUT})"
	else
		echo "Primary display preference (detached): Upper screen (${TOP_OUTPUT})"
	fi
	active_primary="unavailable"
	if resolve_active_graphical_session && check_graphical_session_ready; then
		build_kscreen_environment
		config_json="$(run_kscreen -j 2>/dev/null || true)"
		if [[ -n "${config_json}" ]]; then
			active_primary="$(primary_output_from_json <<< "${config_json}")"
		fi
	fi
	echo "Active KDE primary display: ${active_primary}"
	if [[ -r "${ICON_LAYOUT_SCRIPT}" ]]; then
		echo "Portrait icon fitting: installed; icon and label sizes are preserved"
	else
		echo "Portrait icon fitting: helper missing"
	fi
	show_touch_calibration_status
	if is_keyboard_physically_docked; then
		echo "Keyboard policy: docked; eDP-2 disabled and rotation suspended"
	else
		echo "Keyboard policy: detached; eDP-2 enabled and rotation active"
	fi
}

main()
{
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
		fit-icons)
			[[ -z "${REQUESTED_ORIENTATION}" ]] || orientation_is_valid "${REQUESTED_ORIENTATION}" || { usage; exit 2; }
			fit_icons_now "${REQUESTED_ORIENTATION}"
			;;
		uninstall-touch-restore) restore_touch_for_uninstall ;;
		status) show_status ;;
		*) usage; exit 2 ;;
	esac
}

if [[ "${ZENBOOK_DUO_DISPLAY_CONTROL_SOURCE_ONLY:-false}" != true ]]; then
	main "$@"
fi
