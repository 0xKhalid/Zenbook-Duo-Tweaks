#!/usr/bin/env bash
set -euo pipefail

TARGET_BACKLIGHT="${TARGET_BACKLIGHT:-card0-eDP-2-backlight}"
TARGET_BRIGHTNESS="${TARGET_BRIGHTNESS:-100}"
DEBUG_LOG="${DEBUG_LOG:-0}"
BACKLIGHT_PATH=""

log()
{
	logger -t zenbook-duo-brightness-lock "$*"
}

debug_log()
{
	if [[ "${DEBUG_LOG}" == "1" ]]; then
		log "$*"
	fi
}

resolve_backlight_device()
{
	if [[ "${TARGET_BACKLIGHT}" == /* ]]; then
		BACKLIGHT_PATH="${TARGET_BACKLIGHT}"
	else
		BACKLIGHT_PATH="/sys/class/backlight/${TARGET_BACKLIGHT}"
	fi

	if [[ ! -d "${BACKLIGHT_PATH}" ]]; then
		debug_log "WARNING: Backlight device not found: ${BACKLIGHT_PATH}"
		return 1
	fi

	if [[ ! -r "${BACKLIGHT_PATH}/max_brightness" || ! -r "${BACKLIGHT_PATH}/brightness" ]]; then
		debug_log "WARNING: Backlight brightness files unavailable: ${BACKLIGHT_PATH}"
		return 1
	fi
}

apply_brightness_lock()
{
	local max_brightness
	local current_brightness
	local target_percent
	local target_value

	if ! [[ "${TARGET_BRIGHTNESS}" =~ ^[0-9]+$ ]]; then
		log "ERROR: TARGET_BRIGHTNESS must be an integer percentage from 0 to 100"
		return 1
	fi

	target_percent=$((10#${TARGET_BRIGHTNESS}))
	if (( target_percent > 100 )); then
		log "ERROR: TARGET_BRIGHTNESS must be an integer percentage from 0 to 100"
		return 1
	fi

	max_brightness="$(<"${BACKLIGHT_PATH}/max_brightness")"
	current_brightness="$(<"${BACKLIGHT_PATH}/brightness")"

	if ! [[ "${max_brightness}" =~ ^[0-9]+$ && "${current_brightness}" =~ ^[0-9]+$ ]] || (( max_brightness <= 0 )); then
		log "ERROR: Invalid backlight values from ${BACKLIGHT_PATH}"
		return 1
	fi

	target_value=$((max_brightness * target_percent / 100))
	if (( target_percent > 0 && target_value == 0 )); then
		target_value=1
	fi

	if (( current_brightness == target_value )); then
		return 0
	fi

	if ! printf '%s\n' "${target_value}" > "${BACKLIGHT_PATH}/brightness"; then
		log "ERROR: Failed to set ${BACKLIGHT_PATH}/brightness to ${target_value}"
		return 1
	fi

	debug_log "Set ${TARGET_BACKLIGHT} brightness to ${target_value}/${max_brightness}"
	return 0
}

if ! resolve_backlight_device; then
	# Not an error: eDP-2 may be unavailable while disabled or during shutdown.
	exit 0
fi

if ! apply_brightness_lock; then
	exit 1
fi
