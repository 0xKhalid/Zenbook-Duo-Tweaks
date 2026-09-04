#!/usr/bin/env bash
set -euo pipefail

# ASUS Zenbook Duo UX8407AA detachable-keyboard backlight control.
# The keyboard accepts HID feature report 0x5A:
#   5A BA C5 C4 <level> 00 00 00 00 00 00 00 00 00 00 00
# A newly connected keyboard can return an all-zero feature buffer over either
# transport until the first write. A cycle may seed that write from the private
# cache, but every change still requires matching post-write hardware readback.

umask 077

SYSFS_ROOT="${KBD_BACKLIGHT_SYSFS_ROOT:-/sys}"
DEV_ROOT="${KBD_BACKLIGHT_DEV_ROOT:-/dev}"
PYTHON_BIN="${KBD_BACKLIGHT_PYTHON_BIN:-python3}"
LOCK_WAIT_SECONDS="${KBD_BACKLIGHT_LOCK_WAIT_SECONDS:-10}"
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE_BASE="${XDG_STATE_HOME:-${HOME}/.local/state}"
RUNTIME_DIR="${KBD_BACKLIGHT_RUNTIME_DIR:-${RUNTIME_BASE}/zenbook-tweaks}"
STATE_DIR="${KBD_BACKLIGHT_STATE_DIR:-${STATE_BASE}/zenbook-tweaks/kbd-backlight}"
LOCK_FILE="${RUNTIME_DIR}/kbd-backlight.lock"
SESSION_FILE="${RUNTIME_DIR}/kbd-backlight-session"
WATCHER_HEALTH_FILE="${RUNTIME_DIR}/kbd-backlight-watcher"
STATE_FILE="${STATE_DIR}/state"
CONFIG_DIR="${KBD_BACKLIGHT_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/zenbook-tweaks}"
CONFIG_FILE="${KBD_BACKLIGHT_CONFIG_FILE:-${CONFIG_DIR}/kbd-backlight.conf}"
LAUNCHER_FILE="${HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
ACTIVITY_SERVICE="zenbook-duo-kbd-backlight-activity.service"
ACTIVITY_HELPER="${KBD_BACKLIGHT_ACTIVITY_HELPER:-/usr/local/libexec/kbd-backlight-activity}"

ASUS_VENDOR=0x0b05
USB_PRODUCT=0x1cd7
BLUETOOTH_PRODUCT=0x1cd8

DEVICE_TRANSPORT=""
DEVICE_NODE=""
DEVICE_BASENAME=""
DEVICE_DIR=""
DEVICE_DRIVER=""
DEVICE_BUS=0
DEVICE_PRODUCT=0
DEVICE_ERROR=""
STATE_PREFERRED=""
STATE_EFFECTIVE=""
STATE_TRANSPORT=""
STATE_SOURCE=""
STATE_IDLE_SUPPRESSED=0
AUTO_ENABLED=1
IDLE_TIMEOUT_SECONDS=900
AMBIENT_ENABLED=0
AMBIENT_DARK_LUX=10
AMBIENT_DIM_LUX=75
AMBIENT_BRIGHT_LUX=300
ACTIVITY_KEYBOARD=missing
ACTIVITY_TOUCHPAD=missing
ACTIVITY_KEYBOARD_SOURCE=missing
ACTIVITY_TOUCHPAD_SOURCE=missing
WATCHER_AMBIENT_STATUS=unavailable
WATCHER_AMBIENT_LUX=none
WATCHER_AMBIENT_BAND=none
WATCHER_AMBIENT_TARGET=none

level_name()
{
	case "$1" in
		0) echo "Off" ;;
		1) echo "Low" ;;
		2) echo "Medium" ;;
		3) echo "High" ;;
		*) echo "Unknown" ;;
	esac
}

uevent_value()
{
	local path="$1"
	local key="$2"
	awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' \
		"${path}/uevent" 2>/dev/null
}

driver_name()
{
	local path="$1"
	local target
	target="$(readlink -f -- "${path}/driver" 2>/dev/null || true)"
	[[ -n "${target}" ]] && basename -- "${target}"
}

usb_interface_number()
{
	local path
	path="$(readlink -f -- "$1" 2>/dev/null || true)"
	while [[ -n "${path}" && "${path}" == "${SYSFS_ROOT}"/* ]]; do
		if [[ -r "${path}/bInterfaceNumber" ]]; then
			tr '[:lower:]' '[:upper:]' < "${path}/bInterfaceNumber"
			return 0
		fi
		path="$(dirname -- "${path}")"
	done
	return 1
}

descriptor_has_backlight_report()
{
	local descriptor="$1"
	[[ -f "${descriptor}" && -r "${descriptor}" ]] || return 1
	"${PYTHON_BIN}" - "${descriptor}" <<'PY'
import pathlib
import sys

try:
    data = pathlib.Path(sys.argv[1]).read_bytes()
except OSError:
    raise SystemExit(1)

# The report descriptor exposes report 0x5A as a 15-byte feature payload.
for offset in range(max(0, len(data) - 1)):
    if data[offset:offset + 2] != b"\x85\x5a":
        continue
    window = data[offset:offset + 64]
    if b"\x95\x0f" in window and b"\xb1" in window:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

candidate_node()
{
	local devdir="$1"
	local transport="$2"
	local bus="$3"
	local product="$4"
	local require_writable="$5"
	local rawdir node devnode class_target canonical_devdir
	local nodes=()

	for rawdir in "${devdir}"/hidraw/hidraw*; do
		[[ -e "${rawdir}" ]] || continue
		nodes+=("${rawdir}")
	done
	[[ "${#nodes[@]}" -eq 1 ]] || return 1

	node="$(basename -- "${nodes[0]}")"
	[[ "${node}" =~ ^hidraw[0-9]+$ ]] || return 1
	devnode="${DEV_ROOT}/${node}"
	node_is_character "${devnode}" || return 1
	if [[ "${require_writable}" == true ]] && ! node_is_writable "${devnode}"; then
		return 1
	fi

	canonical_devdir="$(readlink -f -- "${devdir}")"
	class_target="$(readlink -f -- "${SYSFS_ROOT}/class/hidraw/${node}/device" 2>/dev/null || true)"
	[[ -n "${class_target}" && "${class_target}" == "${canonical_devdir}" ]] || return 1

	printf '%s|%s|%s|%s|%s|%s|%s\n' \
		"${transport}" "${devnode}" "${node}" "${canonical_devdir}" \
		"$(driver_name "${devdir}")" "${bus}" "${product}"
}

node_is_character()
{
	[[ -c "$1" ]]
}

node_is_writable()
{
	[[ -w "$1" ]]
}

collect_candidates()
{
	local transport="$1"
	local require_writable="$2"
	local devdir hid_id hid_phys driver interface candidate
	local pattern expected_id bus product

	case "${transport}" in
		usb)
			pattern="${SYSFS_ROOT}/bus/hid/devices/0003:0B05:1CD7.*"
			expected_id="0003:00000B05:00001CD7"
			bus=3
			product=$((USB_PRODUCT))
			;;
		bluetooth)
			pattern="${SYSFS_ROOT}/bus/hid/devices/0005:0B05:1CD8.*"
			expected_id="0005:00000B05:00001CD8"
			bus=5
			product=$((BLUETOOTH_PRODUCT))
			;;
		*) return 1 ;;
	esac

	for devdir in ${pattern}; do
		[[ -d "${devdir}" ]] || continue
		hid_id="$(uevent_value "${devdir}" HID_ID | tr '[:lower:]' '[:upper:]')"
		[[ "${hid_id}" == "${expected_id}" ]] || continue
		driver="$(driver_name "${devdir}")"
		[[ "${driver}" == "hid-generic" ]] || continue
		if [[ "${transport}" == usb ]]; then
			hid_phys="$(uevent_value "${devdir}" HID_PHYS)"
			interface="$(usb_interface_number "${devdir}" 2>/dev/null || true)"
			[[ "${hid_phys}" == */input4 && "${interface}" == 04 ]] || continue
		fi
		descriptor_has_backlight_report "${devdir}/report_descriptor" || continue
		candidate="$(candidate_node "${devdir}" "${transport}" "${bus}" "${product}" "${require_writable}" || true)"
		[[ -n "${candidate}" ]] && printf '%s\n' "${candidate}"
	done
}

target_hid_present()
{
	compgen -G "${SYSFS_ROOT}/bus/hid/devices/0003:0B05:1CD7.*" >/dev/null ||
		compgen -G "${SYSFS_ROOT}/bus/hid/devices/0005:0B05:1CD8.*" >/dev/null
}

discover_device()
{
	local require_writable="${1:-true}"
	local transport selected
	local candidates=()

	DEVICE_TRANSPORT=""
	DEVICE_NODE=""
	DEVICE_BASENAME=""
	DEVICE_DIR=""
	DEVICE_DRIVER=""
	DEVICE_BUS=0
	DEVICE_PRODUCT=0
	DEVICE_ERROR=""

	for transport in usb bluetooth; do
		mapfile -t candidates < <(collect_candidates "${transport}" "${require_writable}")
		if [[ "${#candidates[@]}" -gt 1 ]]; then
			DEVICE_ERROR="Ambiguous ${transport} backlight interfaces"
			return 1
		fi
		if [[ "${#candidates[@]}" -eq 1 ]]; then
			selected="${candidates[0]}"
			IFS='|' read -r DEVICE_TRANSPORT DEVICE_NODE DEVICE_BASENAME DEVICE_DIR \
				DEVICE_DRIVER DEVICE_BUS DEVICE_PRODUCT <<< "${selected}"
			return 0
		fi
	done

	if target_hid_present; then
		DEVICE_ERROR="Keyboard found, but no safe backlight hidraw interface is available"
	else
		DEVICE_ERROR="ASUS Zenbook Duo Keyboard is disconnected"
	fi
	return 1
}

hid_operation()
{
	local action="$1"
	local level="${2:-}"
	if [[ -n "${KBD_BACKLIGHT_IO_HELPER:-}" ]]; then
		"${KBD_BACKLIGHT_IO_HELPER}" "${action}" "${DEVICE_NODE}" \
			"${DEVICE_BUS}" "$((ASUS_VENDOR))" "${DEVICE_PRODUCT}" "${level}"
		return
	fi

	"${PYTHON_BIN}" - "${action}" "${DEVICE_NODE}" "${DEVICE_BUS}" \
		"$((ASUS_VENDOR))" "${DEVICE_PRODUCT}" "${level}" <<'PY'
import array
import fcntl
import os
import stat
import struct
import sys

action, path = sys.argv[1], sys.argv[2]
expected_bus = int(sys.argv[3])
expected_vendor = int(sys.argv[4])
expected_product = int(sys.argv[5])
requested = sys.argv[6]
report_size = 16
hid_get_feature = 0xC0004807 | (report_size << 16)
hid_set_feature = 0xC0004806 | (report_size << 16)
hid_get_raw_info = 0x80084803

def read_level(fd):
    report = array.array("B", [0x5A] + [0] * 15)
    fcntl.ioctl(fd, hid_get_feature, report, True)
    if list(report[:4]) != [0x5A, 0xBA, 0xC5, 0xC4] or report[4] not in range(4):
        raise RuntimeError("invalid report 0x5A response")
    return int(report[4])

try:
    fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISCHR(opened.st_mode):
            raise RuntimeError("selected node is not a character device")

        raw_info = bytearray(8)
        fcntl.ioctl(fd, hid_get_raw_info, raw_info, True)
        bus, vendor, product = struct.unpack("=Ihh", raw_info)
        vendor &= 0xFFFF
        product &= 0xFFFF
        if (bus, vendor, product) != (expected_bus, expected_vendor, expected_product):
            raise RuntimeError("opened hidraw identity changed")

        if action == "probe":
            try:
                print(f"level={read_level(fd)} verification=verified")
            except (OSError, RuntimeError):
                print("verification=unavailable")
            raise SystemExit(0)
        if action == "get":
            print(f"level={read_level(fd)}")
            raise SystemExit(0)

        before = None
        if action == "cycle":
            try:
                before = read_level(fd)
            except (OSError, RuntimeError):
                if requested not in {"0", "1", "2", "3"}:
                    raise
            after = (before + 1) % 4 if before is not None else int(requested)
        elif action == "set" and requested in {"0", "1", "2", "3"}:
            after = int(requested)
        else:
            raise RuntimeError("invalid HID operation")

        report = array.array("B", [0x5A, 0xBA, 0xC5, 0xC4, after] + [0] * 11)
        fcntl.ioctl(fd, hid_set_feature, report, True)

        current_path = os.stat(path)
        if current_path.st_rdev != opened.st_rdev:
            raise RuntimeError("keyboard disconnected during operation")
        verified = read_level(fd)
        if verified != after:
            raise RuntimeError("hardware readback did not match requested level")
        prior = "unavailable" if before is None else str(before)
        print(f"before={prior} after={after} verification=verified")
    finally:
        os.close(fd)
except SystemExit:
    raise
except (OSError, RuntimeError) as error:
    print(str(error), file=sys.stderr)
    raise SystemExit(1)
PY
}

ensure_private_directory()
{
	local path="$1"
	local owner
	if [[ -e "${path}" || -L "${path}" ]]; then
		[[ -d "${path}" && ! -L "${path}" ]] || return 1
		owner="$(stat -Lc '%u' -- "${path}")"
		[[ "${owner}" == "$(id -u)" ]] || return 1
	else
		mkdir -p -- "${path}"
	fi
	chmod 700 -- "${path}"
}

prepare_lock()
{
	[[ -d "${RUNTIME_BASE}" && ! -L "${RUNTIME_BASE}" ]] || {
		echo "Error: private user runtime directory is unavailable" >&2
		return 1
	}
	[[ "$(stat -Lc '%u' -- "${RUNTIME_BASE}")" == "$(id -u)" ]] || {
		echo "Error: user runtime directory has the wrong owner" >&2
		return 1
	}
	ensure_private_directory "${RUNTIME_DIR}" || {
		echo "Error: unsafe keyboard-backlight runtime directory" >&2
		return 1
	}
	if [[ -e "${LOCK_FILE}" || -L "${LOCK_FILE}" ]]; then
		[[ -f "${LOCK_FILE}" && ! -L "${LOCK_FILE}" &&
			"$(stat -Lc '%u' -- "${LOCK_FILE}")" == "$(id -u)" ]] || {
			echo "Error: unsafe keyboard-backlight lock file" >&2
			return 1
		}
	fi
	exec 9>"${LOCK_FILE}"
	chmod 600 -- "${LOCK_FILE}"
	flock -w "${LOCK_WAIT_SECONDS}" 9 || {
		echo "Error: another keyboard-backlight operation is still running" >&2
		return 1
	}
}

prepare_state_directory()
{
	local managed_parent="${STATE_BASE}/zenbook-tweaks"
	if [[ "${STATE_DIR}" == "${managed_parent}/kbd-backlight" ]]; then
		if [[ -e "${STATE_BASE}" || -L "${STATE_BASE}" ]]; then
			[[ -d "${STATE_BASE}" && ! -L "${STATE_BASE}" &&
				"$(stat -Lc '%u' -- "${STATE_BASE}")" == "$(id -u)" ]] || return 1
		else
			mkdir -p -- "${STATE_BASE}"
			chmod 700 -- "${STATE_BASE}"
		fi
		ensure_private_directory "${managed_parent}" || return 1
	fi
	ensure_private_directory "${STATE_DIR}"
}

state_value()
{
	local key="$1"
	awk -F= -v key="${key}" '$1 == key {print substr($0, index($0, "=") + 1); exit}' \
		"${STATE_FILE}" 2>/dev/null
}

load_state()
{
	local version level mode owner
	STATE_PREFERRED=""
	STATE_EFFECTIVE=""
	STATE_TRANSPORT=""
	STATE_SOURCE=""
	STATE_IDLE_SUPPRESSED=0
	[[ -f "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || return 1
	owner="$(stat -Lc '%u' -- "${STATE_FILE}" 2>/dev/null || true)"
	mode="$(stat -Lc '%a' -- "${STATE_FILE}" 2>/dev/null || true)"
	[[ "${owner}" == "$(id -u)" && "${mode}" == 600 ]] || return 1
	version="$(state_value version)"
	if [[ "${version}" == 1 ]]; then
		awk -F= '
			BEGIN {expected["version"]=1; expected["level"]=1; expected["transport"]=1}
			NF != 2 || !($1 in expected) || seen[$1]++ {bad=1}
			END {for (key in expected) if (seen[key] != 1) bad=1; exit bad}
		' "${STATE_FILE}" || return 1
		level="$(state_value level)"
		[[ "${level}" =~ ^[0-3]$ ]] || return 1
		STATE_PREFERRED="${level}"
		STATE_EFFECTIVE="${level}"
		STATE_TRANSPORT="$(state_value transport)"
		STATE_SOURCE=manual
		[[ "${STATE_TRANSPORT}" == legacy ]] && STATE_SOURCE=legacy
		[[ "${STATE_TRANSPORT}" == usb || "${STATE_TRANSPORT}" == bluetooth || "${STATE_TRANSPORT}" == legacy ]] || return 1
		return 0
	fi
	[[ "${version}" == 2 || "${version}" == 3 ]] || return 1
	awk -F= '
		BEGIN {
			expected["version"]=1; expected["preferred_level"]=1
			expected["effective_level"]=1; expected["transport"]=1
			expected["preference_source"]=1; expected["idle_suppressed"]=1
		}
		NF != 2 || !($1 in expected) || seen[$1]++ {bad=1}
		END {for (key in expected) if (seen[key] != 1) bad=1; exit bad}
	' "${STATE_FILE}" || return 1
	STATE_PREFERRED="$(state_value preferred_level)"
	STATE_EFFECTIVE="$(state_value effective_level)"
	STATE_TRANSPORT="$(state_value transport)"
	STATE_SOURCE="$(state_value preference_source)"
	STATE_IDLE_SUPPRESSED="$(state_value idle_suppressed)"
	[[ "${STATE_PREFERRED}" =~ ^[0-3]$ && "${STATE_EFFECTIVE}" =~ ^[0-3]$ ]] || return 1
	[[ "${STATE_TRANSPORT}" == usb || "${STATE_TRANSPORT}" == bluetooth || "${STATE_TRANSPORT}" == legacy ]] || return 1
	if [[ "${version}" == 2 ]]; then
		[[ "${STATE_SOURCE}" == default || "${STATE_SOURCE}" == manual || "${STATE_SOURCE}" == legacy ]] || return 1
	else
		[[ "${STATE_SOURCE}" == default || "${STATE_SOURCE}" == manual ||
			"${STATE_SOURCE}" == legacy || "${STATE_SOURCE}" == ambient ]] || return 1
	fi
	[[ "${STATE_IDLE_SUPPRESSED}" == 0 || "${STATE_IDLE_SUPPRESSED}" == 1 ]] || return 1
}

write_state()
{
	local preferred="$1" effective="$2" transport="$3" source="$4" suppressed="$5"
	local temporary
	[[ "${preferred}" =~ ^[0-3]$ && "${effective}" =~ ^[0-3]$ ]] || return 1
	[[ "${transport}" == usb || "${transport}" == bluetooth || "${transport}" == legacy ]] || return 1
	[[ "${source}" == default || "${source}" == manual ||
		"${source}" == legacy || "${source}" == ambient ]] || return 1
	[[ "${suppressed}" == 0 || "${suppressed}" == 1 ]] || return 1
	prepare_state_directory || {
		echo "Error: unsafe keyboard-backlight state directory" >&2
		return 1
	}
	if [[ -e "${STATE_FILE}" || -L "${STATE_FILE}" ]]; then
		[[ -f "${STATE_FILE}" && ! -L "${STATE_FILE}" &&
			"$(stat -Lc '%u' -- "${STATE_FILE}")" == "$(id -u)" ]] || {
			echo "Error: unsafe keyboard-backlight state file" >&2
			return 1
		}
	fi
	temporary="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
	chmod 600 -- "${temporary}"
	{
		printf 'version=3\npreferred_level=%s\neffective_level=%s\n' "${preferred}" "${effective}"
		printf 'transport=%s\npreference_source=%s\nidle_suppressed=%s\n' \
			"${transport}" "${source}" "${suppressed}"
	} > "${temporary}"
	mv -f -- "${temporary}" "${STATE_FILE}"
}

read_cached_level()
{
	load_state || return 1
	printf '%s\n' "${STATE_PREFERRED}"
}

write_cached_level()
{
	local level="$1" transport="$2" source=manual
	[[ "${transport}" == legacy ]] && source=legacy
	write_state "${level}" "${level}" "${transport}" "${source}" 0
}

load_config()
{
	local owner mode version
	AUTO_ENABLED=1
	IDLE_TIMEOUT_SECONDS=900
	AMBIENT_ENABLED=0
	AMBIENT_DARK_LUX=10
	AMBIENT_DIM_LUX=75
	AMBIENT_BRIGHT_LUX=300
	[[ -e "${CONFIG_FILE}" || -L "${CONFIG_FILE}" ]] || return 0
	[[ -f "${CONFIG_FILE}" && ! -L "${CONFIG_FILE}" ]] || return 1
	owner="$(stat -Lc '%u' -- "${CONFIG_FILE}" 2>/dev/null || true)"
	mode="$(stat -Lc '%a' -- "${CONFIG_FILE}" 2>/dev/null || true)"
	[[ "${owner}" == "$(id -u)" && "${mode}" == 600 ]] || return 1
	version="$(awk -F= '$1 == "version" {print $2}' "${CONFIG_FILE}")"
	if [[ "${version}" == 1 ]]; then
		awk -F= '
			BEGIN {expected["version"]=1; expected["enabled"]=1; expected["idle_timeout_seconds"]=1}
			NF != 2 || !($1 in expected) || seen[$1]++ {bad=1}
			END {for (key in expected) if (seen[key] != 1) bad=1; exit bad}
		' "${CONFIG_FILE}" || return 1
	elif [[ "${version}" == 2 ]]; then
		awk -F= '
			BEGIN {
				expected["version"]=1; expected["enabled"]=1; expected["idle_timeout_seconds"]=1
				expected["ambient_enabled"]=1; expected["ambient_dark_lux"]=1
				expected["ambient_dim_lux"]=1; expected["ambient_bright_lux"]=1
			}
			NF != 2 || !($1 in expected) || seen[$1]++ {bad=1}
			END {for (key in expected) if (seen[key] != 1) bad=1; exit bad}
		' "${CONFIG_FILE}" || return 1
		AMBIENT_ENABLED="$(awk -F= '$1 == "ambient_enabled" {print $2}' "${CONFIG_FILE}")"
		AMBIENT_DARK_LUX="$(awk -F= '$1 == "ambient_dark_lux" {print $2}' "${CONFIG_FILE}")"
		AMBIENT_DIM_LUX="$(awk -F= '$1 == "ambient_dim_lux" {print $2}' "${CONFIG_FILE}")"
		AMBIENT_BRIGHT_LUX="$(awk -F= '$1 == "ambient_bright_lux" {print $2}' "${CONFIG_FILE}")"
	else
		return 1
	fi
	AUTO_ENABLED="$(awk -F= '$1 == "enabled" {print $2}' "${CONFIG_FILE}")"
	IDLE_TIMEOUT_SECONDS="$(awk -F= '$1 == "idle_timeout_seconds" {print $2}' "${CONFIG_FILE}")"
	[[ "${AUTO_ENABLED}" == 0 || "${AUTO_ENABLED}" == 1 ]] || return 1
	[[ "${AMBIENT_ENABLED}" == 0 || "${AMBIENT_ENABLED}" == 1 ]] || return 1
	[[ "${IDLE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || return 1
	(( IDLE_TIMEOUT_SECONDS >= 60 && IDLE_TIMEOUT_SECONDS <= 7200 )) || return 1
	ambient_thresholds_valid "${AMBIENT_DARK_LUX}" "${AMBIENT_DIM_LUX}" "${AMBIENT_BRIGHT_LUX}"
}

ambient_thresholds_valid()
{
	local dark="$1" dim="$2" bright="$3"
	[[ "${dark}" =~ ^[0-9]+$ && "${dim}" =~ ^[0-9]+$ && "${bright}" =~ ^[0-9]+$ ]] || return 1
	(( dark >= 1 && dark < dim && dim < bright && bright <= 100000 ))
}

write_config()
{
	local enabled="$1" seconds="$2" ambient="$3" dark="$4" dim="$5" bright="$6" temporary
	[[ "${enabled}" == 0 || "${enabled}" == 1 ]] || return 1
	[[ "${ambient}" == 0 || "${ambient}" == 1 ]] || return 1
	[[ "${seconds}" =~ ^[0-9]+$ ]] && (( seconds >= 60 && seconds <= 7200 )) || return 1
	ambient_thresholds_valid "${dark}" "${dim}" "${bright}" || return 1
	ensure_private_directory "${CONFIG_DIR}" || {
		echo "Error: unsafe keyboard-backlight configuration directory" >&2
		return 1
	}
	if [[ -e "${CONFIG_FILE}" || -L "${CONFIG_FILE}" ]]; then
		[[ -f "${CONFIG_FILE}" && ! -L "${CONFIG_FILE}" &&
			"$(stat -Lc '%u' -- "${CONFIG_FILE}")" == "$(id -u)" ]] || return 1
	fi
	temporary="$(mktemp "${CONFIG_DIR}/.kbd-backlight.conf.XXXXXX")"
	chmod 600 -- "${temporary}"
	{
		printf 'version=2\nenabled=%s\nidle_timeout_seconds=%s\n' "${enabled}" "${seconds}"
		printf 'ambient_enabled=%s\nambient_dark_lux=%s\n' "${ambient}" "${dark}"
		printf 'ambient_dim_lux=%s\nambient_bright_lux=%s\n' "${dim}" "${bright}"
	} > "${temporary}"
	mv -f -- "${temporary}" "${CONFIG_FILE}"
}

session_marker_valid()
{
	[[ -f "${SESSION_FILE}" && ! -L "${SESSION_FILE}" &&
		"$(stat -Lc '%u:%a' -- "${SESSION_FILE}" 2>/dev/null)" == "$(id -u):600" ]] || return 1
	awk -F= '
		BEGIN {expected["version"]=1; expected["session_token"]=1; expected["connection_token"]=1}
		NF != 2 || !($1 in expected) || seen[$1]++ {bad=1}
		END {for (key in expected) if (seen[key] != 1) bad=1; exit bad}
	' "${SESSION_FILE}" || return 1
	[[ "$(awk -F= '$1 == "version" {print $2}' "${SESSION_FILE}")" == 1 ]] || return 1
	[[ "$(awk -F= '$1 == "session_token" {print $2}' "${SESSION_FILE}")" =~ ^[0-9a-f]{64}$ &&
		"$(awk -F= '$1 == "connection_token" {print $2}' "${SESSION_FILE}")" =~ ^[0-9a-f]{64}$ ]]
}

session_marker_matches()
{
	local session_token="$1" connection_token="$2"
	session_marker_valid || return 1
	[[ "$(awk -F= '$1 == "session_token" {print $2}' "${SESSION_FILE}")" == "${session_token}" &&
		"$(awk -F= '$1 == "connection_token" {print $2}' "${SESSION_FILE}")" == "${connection_token}" ]]
}

write_session_marker()
{
	local session_token="$1" connection_token="$2" temporary
	[[ "${session_token}" =~ ^[0-9a-f]{64}$ && "${connection_token}" =~ ^[0-9a-f]{64}$ ]] || return 1
	if [[ -e "${SESSION_FILE}" || -L "${SESSION_FILE}" ]]; then
		[[ -f "${SESSION_FILE}" && ! -L "${SESSION_FILE}" &&
			"$(stat -Lc '%u' -- "${SESSION_FILE}")" == "$(id -u)" ]] || return 1
	fi
	temporary="$(mktemp "${RUNTIME_DIR}/.kbd-backlight-session.XXXXXX")"
	chmod 600 -- "${temporary}"
	printf 'version=1\nsession_token=%s\nconnection_token=%s\n' \
		"${session_token}" "${connection_token}" > "${temporary}"
	mv -f -- "${temporary}" "${SESSION_FILE}"
}

show_osd()
{
	local level="$1"
	local label
	label="$(level_name "${level}")"
	[[ "${KBD_BACKLIGHT_DISABLE_OSD:-0}" == 1 ]] && return 0
	if [[ -n "${KBD_BACKLIGHT_OSD_HELPER:-}" ]]; then
		"${KBD_BACKLIGHT_OSD_HELPER}" "${label}" "${level}" >/dev/null 2>&1 || true
		return 0
	fi
	if command -v gdbus >/dev/null 2>&1 && \
		gdbus call --session --dest org.kde.plasmashell --object-path /org/kde/osdService \
			--method org.kde.osdService.showText input-keyboard-brightness \
			"Keyboard backlight: ${label}" >/dev/null 2>&1
	then
		return 0
	fi
	command -v notify-send >/dev/null 2>&1 && \
		notify-send --transient --expire-time=1200 --app-name="Zenbook Duo Tweaks" \
			--icon=input-keyboard-brightness "Keyboard backlight" "${label}" >/dev/null 2>&1 || true
}

run_change()
{
	local action="$1"
	local requested="${2:-}"
	local result after
	prepare_lock
	discover_device true || {
		echo "Error: ${DEVICE_ERROR}" >&2
		return 1
	}
	if [[ "${action}" == cycle ]]; then
		if load_state 2>/dev/null; then
			requested=$(( (STATE_PREFERRED + 1) % 4 ))
			action=set
		else
			# With no readable level or prior request, make the first key press
			# useful and request Low rather than guessing that hardware is on.
			requested=1
		fi
	fi
	if ! result="$(hid_operation "${action}" "${requested}" 2>&1)"; then
		echo "Error: keyboard backlight change failed: ${result}" >&2
		return 1
	fi
	[[ "${result}" =~ ^before=([0-3]|unavailable)[[:space:]]after=([0-3])[[:space:]]verification=verified$ ]] || {
		echo "Error: invalid keyboard response" >&2
		return 1
	}
	after="${BASH_REMATCH[2]}"
	write_state "${after}" "${after}" "${DEVICE_TRANSPORT}" manual 0
	show_osd "${after}"
	echo "Keyboard backlight: $(level_name "${after}") (${after}) [verified]"
}

run_auto_connect()
{
	local session_token="$1" connection_token="$2" result
	[[ "${session_token}" =~ ^[0-9a-f]{64}$ && "${connection_token}" =~ ^[0-9a-f]{64}$ ]] || return 2
	prepare_lock
	load_config || return 1
	if [[ "${AUTO_ENABLED}" != 1 ]]; then
		echo "result=disabled"
		return 0
	fi
	if [[ -e "${SESSION_FILE}" || -L "${SESSION_FILE}" ]]; then
		session_marker_valid || {
			echo "Error: unsafe keyboard-backlight session marker" >&2
			return 1
		}
	fi
	if session_marker_matches "${session_token}" "${connection_token}"; then
		echo "result=unchanged"
		return 0
	fi
	discover_device true || return 1
	result="$(hid_operation set 1 2>&1)" || {
		echo "Error: automatic Low initialization failed: ${result}" >&2
		return 1
	}
	[[ "${result}" =~ ^before=([0-3]|unavailable)[[:space:]]after=1[[:space:]]verification=verified$ ]] || return 1
	write_state 1 1 "${DEVICE_TRANSPORT}" default 0
	write_session_marker "${session_token}" "${connection_token}"
	echo "result=initialized"
}

run_auto_idle()
{
	local result
	prepare_lock
	load_config || return 1
	if [[ "${AUTO_ENABLED}" != 1 ]]; then
		echo "result=disabled"
		return 0
	fi
	if ! load_state; then
		echo "result=unavailable"
		return 0
	fi
	if [[ "${STATE_IDLE_SUPPRESSED}" != 0 ]]; then
		echo "result=already-idle"
		return 0
	fi
	if [[ "${STATE_PREFERRED}" == 0 ]]; then
		if [[ "${STATE_SOURCE}" == ambient ]]; then
			echo "result=ambient-off"
		else
			echo "result=manual-off"
		fi
		return 0
	fi
	if ! discover_device true; then
		echo "result=disconnected"
		return 0
	fi
	result="$(hid_operation set 0 2>&1)" || return 1
	[[ "${result}" =~ ^before=([0-3]|unavailable)[[:space:]]after=0[[:space:]]verification=verified$ ]] || return 1
	write_state "${STATE_PREFERRED}" 0 "${DEVICE_TRANSPORT}" "${STATE_SOURCE}" 1
	echo "result=idled"
}

run_auto_resume()
{
	local result preferred source
	prepare_lock
	load_config || return 1
	if [[ "${AUTO_ENABLED}" != 1 ]]; then
		echo "result=disabled"
		return 0
	fi
	if ! load_state; then
		echo "result=unavailable"
		return 0
	fi
	if [[ "${STATE_IDLE_SUPPRESSED}" != 1 ]]; then
		echo "result=active"
		return 0
	fi
	preferred="${STATE_PREFERRED}"
	source="${STATE_SOURCE}"
	if [[ "${preferred}" == 0 ]]; then
		write_state 0 0 "${STATE_TRANSPORT}" "${source}" 0
		echo "result=manual-off"
		return 0
	fi
	if ! discover_device true; then
		echo "result=disconnected"
		return 0
	fi
	result="$(hid_operation set "${preferred}" 2>&1)" || return 1
	[[ "${result}" =~ ^before=([0-3]|unavailable)[[:space:]]after=([0-3])[[:space:]]verification=verified$ &&
		"${BASH_REMATCH[2]}" == "${preferred}" ]] || return 1
	write_state "${preferred}" "${preferred}" "${DEVICE_TRANSPORT}" "${source}" 0
	echo "result=resumed"
}

run_auto_target()
{
	local target="$1" mode="$2" source result
	[[ "${target}" =~ ^[0-3]$ ]] || return 2
	[[ "${mode}" == ambient || "${mode}" == fallback ]] || return 2
	prepare_lock
	load_config || return 1
	if [[ "${AUTO_ENABLED}" != 1 || "${AMBIENT_ENABLED}" != 1 ]]; then
		echo "result=disabled"
		return 0
	fi
	if ! load_state; then
		echo "result=unavailable"
		return 0
	fi
	if [[ "${STATE_SOURCE}" == manual ]]; then
		echo "result=manual-override"
		return 0
	fi
	[[ "${mode}" == ambient ]] && source=ambient || source=default
	if [[ "${STATE_IDLE_SUPPRESSED}" == 1 ]]; then
		write_state "${target}" 0 "${STATE_TRANSPORT}" "${source}" 1
		echo "result=deferred-idle"
		return 0
	fi
	if ! discover_device true; then
		echo "result=disconnected"
		return 0
	fi
	if [[ "${STATE_EFFECTIVE}" == "${target}" ]]; then
		write_state "${target}" "${target}" "${DEVICE_TRANSPORT}" "${source}" 0
		echo "result=unchanged"
		return 0
	fi
	result="$(hid_operation set "${target}" 2>&1)" || return 1
	[[ "${result}" =~ ^before=([0-3]|unavailable)[[:space:]]after=([0-3])[[:space:]]verification=verified$ &&
		"${BASH_REMATCH[2]}" == "${target}" ]] || return 1
	write_state "${target}" "${target}" "${DEVICE_TRANSPORT}" "${source}" 0
	[[ "${mode}" == ambient ]] && echo "result=ambient-updated" || echo "result=fallback-low"
}

run_auto_fixed()
{
	local result
	prepare_lock
	load_config || return 1
	if ! load_state; then
		echo "result=unavailable"
		return 0
	fi
	if [[ "${STATE_SOURCE}" == manual ]]; then
		echo "result=manual-override"
		return 0
	fi
	if [[ "${STATE_SOURCE}" != ambient ]]; then
		echo "result=unchanged"
		return 0
	fi
	if [[ "${STATE_IDLE_SUPPRESSED}" == 1 ]]; then
		write_state 1 0 "${STATE_TRANSPORT}" default 1
		echo "result=deferred-idle"
		return 0
	fi
	if ! discover_device true; then
		echo "result=disconnected"
		return 0
	fi
	if [[ "${STATE_EFFECTIVE}" != 1 ]]; then
		result="$(hid_operation set 1 2>&1)" || return 1
		[[ "${result}" =~ ^before=([0-3]|unavailable)[[:space:]]after=1[[:space:]]verification=verified$ ]] || return 1
	fi
	write_state 1 1 "${DEVICE_TRANSPORT}" default 0
	echo "result=fixed-low"
}

run_migrate()
{
	prepare_lock
	load_config || return 1
	write_config "${AUTO_ENABLED}" "${IDLE_TIMEOUT_SECONDS}" "${AMBIENT_ENABLED}" \
		"${AMBIENT_DARK_LUX}" "${AMBIENT_DIM_LUX}" "${AMBIENT_BRIGHT_LUX}"
	if load_state 2>/dev/null; then
		write_state "${STATE_PREFERRED}" "${STATE_EFFECTIVE}" "${STATE_TRANSPORT}" \
			"${STATE_SOURCE}" "${STATE_IDLE_SUPPRESSED}"
	fi
}

run_daemon()
{
	load_config || {
		echo "Error: invalid keyboard-backlight automatic configuration" >&2
		return 1
	}
	[[ "${AUTO_ENABLED}" == 1 ]] || return 0
	[[ -x "${ACTIVITY_HELPER}" && ! -L "${ACTIVITY_HELPER}" ]] || {
		echo "Error: keyboard-backlight activity helper is unavailable" >&2
		return 1
	}
	exec "${ACTIVITY_HELPER}" "${0}" "${IDLE_TIMEOUT_SECONDS}" "${AMBIENT_ENABLED}" \
		"${AMBIENT_DARK_LUX}" "${AMBIENT_DIM_LUX}" "${AMBIENT_BRIGHT_LUX}"
}

run_configure()
{
	local enabled="$1" seconds="$2" ambient="$3" dark="$4" dim="$5" bright="$6"
	prepare_lock
	write_config "${enabled}" "${seconds}" "${ambient}" "${dark}" "${dim}" "${bright}"
}

run_get()
{
	local result level
	prepare_lock
	discover_device true || {
		echo "Verified hardware level: unavailable (${DEVICE_ERROR})" >&2
		return 1
	}
	if ! result="$(hid_operation get 2>&1)"; then
		echo "Verified hardware level: unavailable (${result})" >&2
		return 1
	fi
	[[ "${result}" =~ ^level=([0-3])$ ]] || {
		echo "Verified hardware level: unavailable (invalid keyboard response)" >&2
		return 1
	}
	level="${BASH_REMATCH[1]}"
	echo "Verified hardware level: $(level_name "${level}") (${level})"
}

shortcut_status()
{
	local configured="unavailable"
	local runtime="unavailable"
	if command -v kreadconfig6 >/dev/null 2>&1; then
		configured="$(kreadconfig6 --file kglobalshortcutsrc --group services \
			--group net.local.kbd-backlight.desktop --key _launch --default '<not registered>' 2>/dev/null || true)"
	fi
	if command -v gdbus >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
		if gdbus call --session --dest org.kde.kglobalaccel --object-path \
			/component/net_local_kbd_backlight_desktop \
			--method org.kde.kglobalaccel.Component.shortcutNames 2>/dev/null | grep -q "'_launch'"
		then
			runtime="registered"
		else
			runtime="not registered"
		fi
	fi
	printf 'Shortcut: configured=%s; runtime=%s\n' "${configured:-none}" "${runtime}"
}

forwarded_activity_matches()
{
	local input="$1" kind="$2" target phys bus vendor product name expected_name
	target="$(readlink -f -- "${input}/device" 2>/dev/null || true)"
	[[ "$(dirname -- "${target}")" == "${SYSFS_ROOT}/devices/virtual/input" &&
		"$(basename -- "${target}")" == input* ]] || return 1
	phys="$(sed -n '1p' "${target}/phys" 2>/dev/null || true)"
	[[ "${phys}" == input-remapper/* ]] || return 1
	bus="$(sed -n '1p' "${target}/id/bustype" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
	vendor="$(sed -n '1p' "${target}/id/vendor" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
	product="$(sed -n '1p' "${target}/id/product" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
	name="$(sed -n '1p' "${target}/name" 2>/dev/null || true)"
	case "${DEVICE_TRANSPORT}:${kind}" in
		usb:keyboard) expected_name='Primax Electronics Ltd. ASUS Zenbook Duo Keyboard' ;;
		usb:touchpad) expected_name='Primax Electronics Ltd. ASUS Zenbook Duo Keyboard Touchpad' ;;
		bluetooth:keyboard) expected_name='ASUS Zenbook Duo Keyboard' ;;
		bluetooth:touchpad) expected_name='ASUS Zenbook Duo Keyboard Touchpad' ;;
		*) return 1 ;;
	esac
	case "${DEVICE_TRANSPORT}:${bus}:${vendor}:${product}" in
		usb:0003:0b05:1cd7|bluetooth:0005:0b05:1cd8) ;;
		*) return 1 ;;
	esac
	[[ "${name}" == "${expected_name}" ]]
}

activity_pair_names()
{
	local item names=()
	for item in "$@"; do
		names+=("${item%%|*}")
	done
	local IFS=,
	printf '%s' "${names[*]}"
}

activity_pair_description()
{
	local source="$1" item name readable descriptions=()
	shift
	for item in "$@"; do
		name="${item%%|*}"
		readable="${item##*|}"
		descriptions+=("${name}(${source},readable=${readable})")
	done
	local IFS=,
	printf '%s' "${descriptions[*]}"
}

activity_access_status()
{
	local input target properties kind node source readable keyboard touchpad
	local -a physical_keyboard=() physical_touchpad=()
	local -a forwarded_keyboard=() forwarded_touchpad=()
	local -a selected_keyboard=() selected_touchpad=()
	ACTIVITY_KEYBOARD=missing
	ACTIVITY_TOUCHPAD=missing
	ACTIVITY_KEYBOARD_SOURCE=missing
	ACTIVITY_TOUCHPAD_SOURCE=missing
	for input in "${SYSFS_ROOT}"/class/input/event*; do
		[[ -e "${input}" ]] || continue
		target="$(readlink -f -- "${input}/device" 2>/dev/null || true)"
		properties="$(udevadm info --query=property --path="${input}" 2>/dev/null || true)"
		if grep -qx 'ID_INPUT_KEYBOARD=1' <<< "${properties}" &&
			! grep -qx 'ID_INPUT_TOUCHPAD=1' <<< "${properties}"
		then
			kind=keyboard
		elif grep -qx 'ID_INPUT_TOUCHPAD=1' <<< "${properties}" &&
			! grep -qx 'ID_INPUT_KEYBOARD=1' <<< "${properties}"
		then
			kind=touchpad
		else
			continue
		fi
		source=
		case "${DEVICE_TRANSPORT}:${target}" in
			usb:*0003:0B05:1CD7.*|bluetooth:*0005:0B05:1CD8.*) source=physical ;;
			*) forwarded_activity_matches "${input}" "${kind}" && source=forwarded ;;
		esac
		[[ -n "${source}" ]] || continue
		node="${DEV_ROOT}/input/$(basename -- "${input}")"
		[[ -r "${node}" ]] && readable=yes || readable=no
		case "${source}:${kind}" in
			physical:keyboard) physical_keyboard+=("$(basename -- "${input}")|${readable}") ;;
			physical:touchpad) physical_touchpad+=("$(basename -- "${input}")|${readable}") ;;
			forwarded:keyboard) forwarded_keyboard+=("$(basename -- "${input}")|${readable}") ;;
			forwarded:touchpad) forwarded_touchpad+=("$(basename -- "${input}")|${readable}") ;;
		esac
	done
	if (( ${#forwarded_keyboard[@]} > 1 )); then
		keyboard='ambiguous(forwarded)'
		ACTIVITY_KEYBOARD=unavailable
		ACTIVITY_KEYBOARD_SOURCE=unavailable
	elif (( ${#forwarded_keyboard[@]} == 1 )); then
		selected_keyboard=("${forwarded_keyboard[@]}")
		ACTIVITY_KEYBOARD_SOURCE=forwarded
	else
		selected_keyboard=("${physical_keyboard[@]}")
		ACTIVITY_KEYBOARD_SOURCE=physical
	fi
	if [[ -z "${keyboard:-}" ]]; then
		if (( ${#selected_keyboard[@]} )); then
			ACTIVITY_KEYBOARD="$(activity_pair_names "${selected_keyboard[@]}")"
			keyboard="$(activity_pair_description "${ACTIVITY_KEYBOARD_SOURCE}" "${selected_keyboard[@]}")"
		else
			keyboard=missing
			ACTIVITY_KEYBOARD=missing
			ACTIVITY_KEYBOARD_SOURCE=missing
		fi
	fi
	if (( ${#forwarded_touchpad[@]} > 1 )); then
		touchpad='ambiguous(forwarded)'
		ACTIVITY_TOUCHPAD=unavailable
		ACTIVITY_TOUCHPAD_SOURCE=unavailable
	elif (( ${#forwarded_touchpad[@]} == 1 )); then
		selected_touchpad=("${forwarded_touchpad[@]}")
		ACTIVITY_TOUCHPAD_SOURCE=forwarded
	else
		selected_touchpad=("${physical_touchpad[@]}")
		ACTIVITY_TOUCHPAD_SOURCE=physical
	fi
	if [[ -z "${touchpad:-}" ]]; then
		if (( ${#selected_touchpad[@]} )); then
			ACTIVITY_TOUCHPAD="$(activity_pair_names "${selected_touchpad[@]}")"
			touchpad="$(activity_pair_description "${ACTIVITY_TOUCHPAD_SOURCE}" "${selected_touchpad[@]}")"
		else
			touchpad=missing
			ACTIVITY_TOUCHPAD=missing
			ACTIVITY_TOUCHPAD_SOURCE=missing
		fi
	fi
	printf 'Activity interfaces: keyboard=%s; touchpad=%s\n' "${keyboard}" "${touchpad}"
}

watcher_health_status()
{
	local service_state="$1" owner mode transport keyboard keyboard_source touchpad touchpad_source consistent=no
	local ambient_status ambient_lux ambient_band ambient_target ambient_target_label ambient_consistent=no
	if [[ "${service_state}" != active ]]; then
		echo "Watcher selection: inactive"
		return
	fi
	if [[ -f "${WATCHER_HEALTH_FILE}" && ! -L "${WATCHER_HEALTH_FILE}" ]]; then
		owner="$(stat -Lc '%u' -- "${WATCHER_HEALTH_FILE}" 2>/dev/null || true)"
		mode="$(stat -Lc '%a' -- "${WATCHER_HEALTH_FILE}" 2>/dev/null || true)"
		if [[ "${owner}:${mode}" == "$(id -u):600" ]] && awk -F= '
			BEGIN {
				expected["version"]=1; expected["transport"]=1
				expected["keyboard"]=1; expected["keyboard_source"]=1
				expected["touchpad"]=1; expected["touchpad_source"]=1
				expected["ambient_status"]=1; expected["ambient_lux"]=1
				expected["ambient_band"]=1; expected["ambient_target"]=1
			}
			NF != 2 || !($1 in expected) || seen[$1]++ {bad=1}
			END {for (key in expected) if (seen[key] != 1) bad=1; exit bad}
		' "${WATCHER_HEALTH_FILE}"
		then
			[[ "$(awk -F= '$1 == "version" {print $2}' "${WATCHER_HEALTH_FILE}")" == 3 ]] || {
				printf 'Watcher selection consistent: %s\n' "${consistent}"
				return
			}
			transport="$(awk -F= '$1 == "transport" {print $2}' "${WATCHER_HEALTH_FILE}")"
			keyboard="$(awk -F= '$1 == "keyboard" {print $2}' "${WATCHER_HEALTH_FILE}")"
			keyboard_source="$(awk -F= '$1 == "keyboard_source" {print $2}' "${WATCHER_HEALTH_FILE}")"
			touchpad="$(awk -F= '$1 == "touchpad" {print $2}' "${WATCHER_HEALTH_FILE}")"
			touchpad_source="$(awk -F= '$1 == "touchpad_source" {print $2}' "${WATCHER_HEALTH_FILE}")"
			ambient_status="$(awk -F= '$1 == "ambient_status" {print $2}' "${WATCHER_HEALTH_FILE}")"
			ambient_lux="$(awk -F= '$1 == "ambient_lux" {print $2}' "${WATCHER_HEALTH_FILE}")"
			ambient_band="$(awk -F= '$1 == "ambient_band" {print $2}' "${WATCHER_HEALTH_FILE}")"
			ambient_target="$(awk -F= '$1 == "ambient_target" {print $2}' "${WATCHER_HEALTH_FILE}")"
			if [[ "${ambient_status}" =~ ^(disabled|waiting|warming|available|unavailable)$ &&
				"${ambient_lux}" =~ ^(none|[0-9]+)$ &&
				"${ambient_band}" =~ ^(none|dark|dim|normal|bright)$ &&
				"${ambient_target}" =~ ^(none|[0-3])$ ]]
			then
				WATCHER_AMBIENT_STATUS="${ambient_status}"
				WATCHER_AMBIENT_LUX="${ambient_lux}"
				WATCHER_AMBIENT_BAND="${ambient_band}"
				WATCHER_AMBIENT_TARGET="${ambient_target}"
				if [[ "${AMBIENT_ENABLED}" == 1 && "${ambient_status}" != disabled ]] ||
					[[ "${AMBIENT_ENABLED}" == 0 && "${ambient_status}" == disabled ]]
				then
					ambient_consistent=yes
				fi
			fi
			if [[ "${DEVICE_TRANSPORT}" =~ ^(usb|bluetooth)$ && "${transport}" == "${DEVICE_TRANSPORT}" &&
				"${keyboard}" == "${ACTIVITY_KEYBOARD}" &&
				"${keyboard_source}" == "${ACTIVITY_KEYBOARD_SOURCE}" &&
				"${touchpad}" == "${ACTIVITY_TOUCHPAD}" &&
				"${touchpad_source}" == "${ACTIVITY_TOUCHPAD_SOURCE}" &&
				"${ambient_consistent}" == yes ]]
			then
				consistent=yes
			elif [[ -z "${DEVICE_TRANSPORT}" && "${transport}" == disconnected &&
				"${ambient_consistent}" == yes ]]
			then
				consistent=yes
			fi
		fi
	fi
	printf 'Watcher selection consistent: %s\n' "${consistent}"
	if [[ "${WATCHER_AMBIENT_TARGET}" =~ ^[0-3]$ ]]; then
		ambient_target_label="$(level_name "${WATCHER_AMBIENT_TARGET}") (${WATCHER_AMBIENT_TARGET})"
	else
		ambient_target_label=none
	fi
	printf 'Ambient watcher: status=%s; sampled_lux=%s; band=%s; target=%s\n' \
		"${WATCHER_AMBIENT_STATUS}" "${WATCHER_AMBIENT_LUX}" \
		"${WATCHER_AMBIENT_BAND}" "${ambient_target_label}"
}

run_status()
{
	local result level permissions owner launcher transport_label service_state
	local sensor_output sensor_lux control
	prepare_lock || return 1
	if discover_device false; then
		[[ "${DEVICE_TRANSPORT}" == usb ]] && transport_label=USB || transport_label=Bluetooth
		printf 'Connection: %s (%04X:%04X)\n' \
			"${transport_label}" "$((ASUS_VENDOR))" "${DEVICE_PRODUCT}"
		printf 'Selected interface: %s; driver=%s\n' "${DEVICE_BASENAME}" "${DEVICE_DRIVER}"
		permissions="$(stat -Lc '%a' -- "${DEVICE_NODE}" 2>/dev/null || echo unavailable)"
		owner="$(stat -Lc '%U:%G' -- "${DEVICE_NODE}" 2>/dev/null || echo unavailable)"
		printf 'Permissions: mode=%s; owner=%s; writable=%s\n' \
			"${permissions}" "${owner}" "$([[ -w "${DEVICE_NODE}" ]] && echo yes || echo no)"
		activity_access_status
		if result="$(hid_operation get 2>/dev/null)" && [[ "${result}" =~ ^level=([0-3])$ ]]; then
			level="${BASH_REMATCH[1]}"
			printf 'Verified hardware level: %s (%s)\n' "$(level_name "${level}")" "${level}"
		else
			echo "Verified hardware level: unavailable"
		fi
	else
		if target_hid_present; then
			echo "Connection: connected, but no safe backlight interface is available"
		else
			echo "Connection: disconnected"
		fi
		echo "Selected interface: none"
		echo "Permissions: unavailable"
		echo "Activity interfaces: keyboard=unavailable; touchpad=unavailable"
		echo "Verified hardware level: unavailable"
	fi
	if load_state 2>/dev/null; then
		printf 'Preferred session level: %s (%s); source=%s\n' \
			"$(level_name "${STATE_PREFERRED}")" "${STATE_PREFERRED}" "${STATE_SOURCE}"
		printf 'Last verified effective level: %s (%s)\n' \
			"$(level_name "${STATE_EFFECTIVE}")" "${STATE_EFFECTIVE}"
		printf 'Temporarily off for inactivity: %s\n' "$([[ "${STATE_IDLE_SUPPRESSED}" == 1 ]] && echo yes || echo no)"
	else
		echo "Preferred session level: none"
		echo "Last verified effective level: none"
		echo "Temporarily off for inactivity: no"
	fi
	if load_config 2>/dev/null; then
		printf 'Automatic lighting: %s; timeout=%s minutes; activity=keyboard+touchpad\n' \
			"$([[ "${AUTO_ENABLED}" == 1 ]] && echo enabled || echo disabled)" \
			"$((IDLE_TIMEOUT_SECONDS / 60))"
		printf 'Adaptive ambient lighting: %s; thresholds=%s/%s/%s lux\n' \
			"$([[ "${AMBIENT_ENABLED}" == 1 ]] && echo enabled || echo disabled)" \
			"${AMBIENT_DARK_LUX}" "${AMBIENT_DIM_LUX}" "${AMBIENT_BRIGHT_LUX}"
	else
		echo "Automatic lighting: invalid configuration"
		echo "Adaptive ambient lighting: invalid configuration"
	fi
	sensor_output="$("${ACTIVITY_HELPER}" --sensor-status 2>/dev/null || true)"
	if [[ "${sensor_output}" =~ ^status=available[[:space:]]lux=([0-9]+([.][0-9]+)?)$ ]]; then
		sensor_lux="${BASH_REMATCH[1]}"
		printf 'Ambient sensor: available; current=%s lux\n' "${sensor_lux}"
	else
		echo "Ambient sensor: unavailable"
	fi
	if [[ "${STATE_IDLE_SUPPRESSED}" == 1 ]]; then
		control='idle suppression'
	elif [[ "${AMBIENT_ENABLED}" == 1 && "${STATE_SOURCE}" == manual ]]; then
		control='manual override until reconnect/login'
	elif [[ "${STATE_SOURCE}" == ambient ]]; then
		control='adaptive ambient target'
	elif [[ "${AMBIENT_ENABLED}" == 1 ]]; then
		control='adaptive warm-up or safe Low fallback'
	else
		control='fixed/manual preference'
	fi
	printf 'Effective control: %s\n' "${control}"
	service_state="$(systemctl --user is-active "${ACTIVITY_SERVICE}" 2>/dev/null || true)"
	printf 'Activity service: %s\n' "${service_state:-unavailable}"
	watcher_health_status "${service_state:-unavailable}"
	launcher=missing
	if [[ -f "${LAUNCHER_FILE}" && ! -L "${LAUNCHER_FILE}" ]] &&
		grep -qxF 'Exec=kbd-backlight' "${LAUNCHER_FILE}" &&
		grep -qxF 'X-KDE-GlobalAccel-CommandShortcut=true' "${LAUNCHER_FILE}"
	then
		launcher=present
	fi
	printf 'KDE launcher: %s (%s)\n' "${launcher}" '~/.local/share/applications/net.local.kbd-backlight.desktop'
	shortcut_status
}

usage()
{
	cat <<'EOF'
Usage: kbd-backlight [cycle|get|status|set <0-3>]

Without arguments, the command cycles Off -> Low -> Medium -> High -> Off.
EOF
}

main()
{
	case "${1:-cycle}" in
		cycle)
			[[ "$#" -le 1 ]] || { usage >&2; return 2; }
			run_change cycle
			;;
		set)
			[[ "$#" -eq 2 && "$2" =~ ^[0-3]$ ]] || { usage >&2; return 2; }
			run_change set "$2"
			;;
		get)
			[[ "$#" -eq 1 ]] || { usage >&2; return 2; }
			run_get
			;;
		status)
			[[ "$#" -eq 1 ]] || { usage >&2; return 2; }
			run_status
			;;
		daemon)
			[[ "$#" -eq 1 ]] || return 2
			run_daemon
			;;
		_auto-connect)
			[[ "$#" -eq 3 ]] || return 2
			run_auto_connect "$2" "$3"
			;;
		_auto-idle)
			[[ "$#" -eq 1 ]] || return 2
			run_auto_idle
			;;
		_auto-resume)
			[[ "$#" -eq 1 ]] || return 2
			run_auto_resume
			;;
		_auto-target)
			[[ "$#" -eq 3 ]] || return 2
			run_auto_target "$2" "$3"
			;;
		_auto-fixed)
			[[ "$#" -eq 1 ]] || return 2
			run_auto_fixed
			;;
		_migrate)
			[[ "$#" -eq 1 ]] || return 2
			run_migrate
			;;
		_configure)
			[[ "$#" -eq 7 ]] || return 2
			run_configure "$2" "$3" "$4" "$5" "$6" "$7"
			;;
		-h|--help|help)
			usage
			;;
		*)
			usage >&2
			return 2
			;;
	esac
}

if [[ "${KBD_BACKLIGHT_SOURCE_ONLY:-false}" != true ]]; then
	main "$@"
fi
