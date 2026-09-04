#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/tweaks/kbd-backlight/kbd-backlight.sh"
RULE="${REPO_ROOT}/tweaks/kbd-backlight/70-asus-kbd-backlight.rules"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

SYSFS_ROOT="${TEST_ROOT}/sys"
DEV_ROOT="${TEST_ROOT}/dev"
HOME_ROOT="${TEST_ROOT}/home"
RUNTIME_ROOT="${TEST_ROOT}/run"
STATE_ROOT="${TEST_ROOT}/state"
CONFIG_ROOT="${TEST_ROOT}/config"
MOCK_ROOT="${TEST_ROOT}/mock"
IO_HELPER="${TEST_ROOT}/hid-io"
OSD_HELPER="${TEST_ROOT}/osd"
ACTIVITY_DAEMON="${REPO_ROOT}/tweaks/kbd-backlight/kbd-backlight-activity"

mkdir -p "${SYSFS_ROOT}/bus/hid/devices" "${SYSFS_ROOT}/class/hidraw" \
	"${SYSFS_ROOT}/drivers/hid-generic" "${SYSFS_ROOT}/drivers/hid-multitouch" \
	"${DEV_ROOT}" "${HOME_ROOT}" "${RUNTIME_ROOT}" "${STATE_ROOT}" "${MOCK_ROOT}" \
	"${CONFIG_ROOT}"
chmod 700 "${HOME_ROOT}" "${RUNTIME_ROOT}" "${STATE_ROOT}" "${CONFIG_ROOT}"
printf '1\n' > "${MOCK_ROOT}/level"

[[ "$(basename "${RULE}")" < 73-seat-late.rules ]]
grep -q 'TAGS=="asus-kbd-backlight"' "${RULE}"
grep -q 'OWNER="root", GROUP="root", MODE="0660", TAG+="uaccess"' "${RULE}"
if grep -q 'GROUP="input"' "${RULE}"; then
	echo "FAIL: udev rule still grants the broad input group" >&2
	exit 1
fi

export HOME="${HOME_ROOT}"
export XDG_RUNTIME_DIR="${RUNTIME_ROOT}"
export XDG_STATE_HOME="${STATE_ROOT}"
export XDG_CONFIG_HOME="${CONFIG_ROOT}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${TEST_ROOT}/no-session-bus"
export KBD_BACKLIGHT_SYSFS_ROOT="${SYSFS_ROOT}"
export KBD_BACKLIGHT_DEV_ROOT="${DEV_ROOT}"
export KBD_BACKLIGHT_IO_HELPER="${IO_HELPER}"
export KBD_BACKLIGHT_OSD_HELPER="${OSD_HELPER}"
export KBD_BACKLIGHT_LOCK_WAIT_SECONDS=5
export MOCK_ROOT

cat > "${IO_HELPER}" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
action="$1"
path="$2"
bus="$3"
vendor="$4"
product="$5"
requested="${6:-}"
active="${MOCK_ROOT}/active"
if ! mkdir "${active}" 2>/dev/null; then
	touch "${MOCK_ROOT}/overlap"
	exit 1
fi
trap 'rmdir "${active}" 2>/dev/null || true' EXIT
sleep 0.02
current="$(cat "${MOCK_ROOT}/level")"
case "${MOCK_MODE:-ok}" in
	fail|writefail|readbackfail) echo "simulated ${MOCK_MODE} HID failure" >&2; exit 1 ;;
	disconnect) rm -f -- "${path}"; echo 'keyboard disconnected during operation' >&2; exit 1 ;;
	malformed) echo 'not-a-report'; exit 0 ;;
	uninitialized)
		if [[ "${action}" == get ]]; then
			echo 'invalid report 0x5A response' >&2
			exit 1
		fi
		;;
esac
[[ "${vendor}" == 2821 ]]
case "${bus}:${product}" in 3:7383|5:7384) ;; *) exit 1 ;; esac
case "${action}" in
	get) printf 'level=%s\n' "${current}" ;;
	probe)
		if [[ "${bus}" == 5 ]]; then printf 'level=%s verification=verified\n' "${current}"; else echo 'verification=unavailable'; fi
		;;
	cycle)
		if [[ "${MOCK_MODE:-ok}" == uninitialized ]]; then
			next="${requested}"; prior=unavailable
		else
			next=$(( (current + 1) % 4 )); prior="${current}"
		fi
		printf '%s\n' "${next}" > "${MOCK_ROOT}/level"
		printf 'before=%s after=%s verification=verified\n' "${prior}" "${next}"
		;;
	set)
		[[ "${requested}" =~ ^[0-3]$ ]]; printf '%s\n' "${requested}" > "${MOCK_ROOT}/level"
		if [[ "${bus}" == 5 ]]; then prior="${current}"; else prior=unavailable; fi
		printf 'before=%s after=%s verification=verified\n' "${prior}" "${requested}"
		;;
	*) exit 1 ;;
esac
MOCK
cat > "${OSD_HELPER}" <<'MOCK'
#!/usr/bin/env bash
printf '%s:%s\n' "$1" "$2" >> "${MOCK_ROOT}/osd"
MOCK
chmod 755 "${IO_HELPER}" "${OSD_HELPER}"

assert_contains()
{
	local haystack="$1"
	local needle="$2"
	[[ "${haystack}" == *"${needle}"* ]] || {
		echo "FAIL: expected output to contain: ${needle}" >&2
		echo "${haystack}" >&2
		exit 1
	}
}

assert_absent()
{
	[[ ! -e "$1" && ! -L "$1" ]] || { echo "FAIL: expected $1 to be absent" >&2; exit 1; }
}

write_descriptor()
{
	printf '\x06\x31\xff\x85\x5a\x09\x76\x75\x08\x95\x0f\xb1\x02\xc0' > "$1"
}

make_hid()
{
	local transport="$1"
	local suffix="$2"
	local node="$3"
	local driver="$4"
	local real bus_name hid_id hid_phys interface_dir
	case "${transport}" in
		bluetooth)
			bus_name="0005:0B05:1CD8.${suffix}"
			real="${SYSFS_ROOT}/devices/virtual/uhid/${bus_name}"
			hid_id="0005:00000B05:00001CD8"
			hid_phys="radio/input0"
			;;
		usb)
			bus_name="0003:0B05:1CD7.${suffix}"
			interface_dir="${SYSFS_ROOT}/devices/usb/3-6/3-6:1.4"
			real="${interface_dir}/${bus_name}"
			hid_id="0003:00000B05:00001CD7"
			hid_phys="usb-0000:00:14.0-6/input4"
			mkdir -p "${interface_dir}"
			printf '04\n' > "${interface_dir}/bInterfaceNumber"
			;;
	esac
	mkdir -p "${real}/hidraw/${node}"
	printf 'HID_ID=%s\nHID_NAME=ASUS Zenbook Duo Keyboard\nHID_PHYS=%s\n' \
		"${hid_id}" "${hid_phys}" > "${real}/uevent"
	write_descriptor "${real}/report_descriptor"
	ln -s "${SYSFS_ROOT}/drivers/${driver}" "${real}/driver"
	ln -s "${real}" "${SYSFS_ROOT}/bus/hid/devices/${bus_name}"
	mkdir -p "${SYSFS_ROOT}/class/hidraw/${node}"
	ln -s "${real}" "${SYSFS_ROOT}/class/hidraw/${node}/device"
	ln -s /dev/null "${DEV_ROOT}/${node}"
}

remove_hid()
{
	local bus_name="$1"
	local node="$2"
	rm -f -- "${SYSFS_ROOT}/bus/hid/devices/${bus_name}" "${DEV_ROOT}/${node}"
	rm -rf -- "${SYSFS_ROOT}/class/hidraw/${node}"
}

make_hid bluetooth 0001 hidraw0 hid-generic
make_hid bluetooth 0002 hidraw1 hid-multitouch

export MOCK_MODE=uninitialized
status="$(${SCRIPT} status)"
assert_contains "${status}" "Connection: Bluetooth (0B05:1CD8)"
assert_contains "${status}" "Selected interface: hidraw0; driver=hid-generic"
assert_contains "${status}" "Verified hardware level: unavailable"
assert_contains "${status}" "Preferred session level: none"
output="$(${SCRIPT})"
assert_contains "${output}" "Keyboard backlight: Low (1) [verified]"
unset MOCK_MODE

status="$(${SCRIPT} status)"
assert_contains "${status}" "Verified hardware level: Low (1)"
assert_contains "${status}" "Preferred session level: Low (1); source=manual"

output="$(${SCRIPT})"
assert_contains "${output}" "Keyboard backlight: Medium (2) [verified]"
grep -qxF 'Medium:2' "${MOCK_ROOT}/osd"
grep -qxF 'preferred_level=2' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
[[ "$(stat -c %a "${STATE_ROOT}/zenbook-tweaks/kbd-backlight")" == 700 ]]
[[ "$(stat -c %a "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state")" == 600 ]]

${SCRIPT} set 3 >/dev/null
grep -qxF 'preferred_level=3' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
before_state="$(sha256sum "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state")"
before_osd="$(wc -l < "${MOCK_ROOT}/osd")"
export MOCK_MODE=fail
if ${SCRIPT} set 0 >/dev/null 2>&1; then
	echo "FAIL: HID failure was reported as success" >&2
	exit 1
fi
[[ "$(sha256sum "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state")" == "${before_state}" ]]
[[ "$(wc -l < "${MOCK_ROOT}/osd")" == "${before_osd}" ]]

export MOCK_MODE=malformed
if ${SCRIPT} cycle >/dev/null 2>&1; then
	echo "FAIL: malformed HID response was accepted" >&2
	exit 1
fi
[[ "$(sha256sum "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state")" == "${before_state}" ]]
unset MOCK_MODE

for MOCK_MODE in writefail readbackfail; do
	export MOCK_MODE
	if ${SCRIPT} set 0 >/dev/null 2>&1; then
		echo "FAIL: ${MOCK_MODE} was reported as success" >&2
		exit 1
	fi
	[[ "$(sha256sum "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state")" == "${before_state}" ]]
	[[ "$(wc -l < "${MOCK_ROOT}/osd")" == "${before_osd}" ]]
done
unset MOCK_MODE

# A disconnect during I/O leaves both state and success feedback untouched.
export MOCK_MODE=disconnect
if ${SCRIPT} cycle >/dev/null 2>&1; then
	echo "FAIL: disconnect race was accepted" >&2
	exit 1
fi
unset MOCK_MODE
[[ "$(sha256sum "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state")" == "${before_state}" ]]
[[ "$(wc -l < "${MOCK_ROOT}/osd")" == "${before_osd}" ]]
ln -s /dev/null "${DEV_ROOT}/hidraw0"

# USB wins when both transports expose one valid interface.
make_hid usb 0003 hidraw2 hid-generic
export MOCK_MODE=uninitialized
status="$(${SCRIPT} status)"
assert_contains "${status}" "Connection: USB (0B05:1CD7)"
assert_contains "${status}" "Selected interface: hidraw2"
assert_contains "${status}" "Verified hardware level: unavailable"
assert_contains "${status}" "Preferred session level: High (3); source=manual"
output="$(${SCRIPT} cycle)"
assert_contains "${output}" "Keyboard backlight: Off (0) [verified]"
grep -qxF 'preferred_level=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
unset MOCK_MODE
assert_contains "$(${SCRIPT} get)" "Verified hardware level: Off (0)"

# A successful explicit USB write is read back before updating the cache.
output="$(${SCRIPT} set 2)"
assert_contains "${output}" "Keyboard backlight: Medium (2) [verified]"
grep -qxF 'preferred_level=2' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} set 3 >/dev/null

# Two otherwise valid USB interfaces are rejected rather than selected arbitrarily.
make_hid usb 0004 hidraw3 hid-generic
if ${SCRIPT} get >/dev/null 2>&1; then
	echo "FAIL: ambiguous USB interfaces were accepted" >&2
	exit 1
fi
remove_hid 0003:0B05:1CD7.0004 hidraw3

# Wrong identity, driver, descriptor, character type, and write access fail safely.
usb_real="$(readlink -f "${SYSFS_ROOT}/bus/hid/devices/0003:0B05:1CD7.0003")"
cp "${usb_real}/uevent" "${TEST_ROOT}/usb.uevent"
sed 's/00001CD7/0000DEAD/' "${TEST_ROOT}/usb.uevent" > "${usb_real}/uevent"
remove_hid 0005:0B05:1CD8.0001 hidraw0
if ${SCRIPT} get >/dev/null 2>&1; then
	echo "FAIL: wrong HID identity was accepted" >&2
	exit 1
fi
cp "${TEST_ROOT}/usb.uevent" "${usb_real}/uevent"
printf '\x85\x5a\x95\x01\xb1\x02' > "${usb_real}/report_descriptor"
if ${SCRIPT} get >/dev/null 2>&1; then
	echo "FAIL: wrong report descriptor was accepted" >&2
	exit 1
fi
write_descriptor "${usb_real}/report_descriptor"

(
	export KBD_BACKLIGHT_SOURCE_ONLY=true
	# shellcheck source=/dev/null
	source "${SCRIPT}"
	node_is_character() { return 1; }
	if discover_device true; then
		echo "FAIL: non-character device was accepted" >&2
		exit 1
	fi
)
(
	export KBD_BACKLIGHT_SOURCE_ONLY=true
	# shellcheck source=/dev/null
	source "${SCRIPT}"
	node_is_writable() { return 1; }
	if discover_device true; then
		echo "FAIL: unwritable device was accepted" >&2
		exit 1
	fi
)

# Cached data is clearly separated from unavailable hardware state.
remove_hid 0003:0B05:1CD7.0003 hidraw2
status="$(${SCRIPT} status)"
assert_contains "${status}" "Connection: connected, but no safe backlight interface is available"
assert_contains "${status}" "Verified hardware level: unavailable"
assert_contains "${status}" "Preferred session level: High (3); source=manual"

# Restore one valid transport and prove queued rapid presses advance exactly once each.
remove_hid 0005:0B05:1CD8.0002 hidraw1
status="$(${SCRIPT} status)"
assert_contains "${status}" "Connection: disconnected"
assert_contains "${status}" "Preferred session level: High (3); source=manual"
make_hid bluetooth 0005 hidraw4 hid-generic
printf '0\n' > "${MOCK_ROOT}/level"
rm -f -- "${MOCK_ROOT}/overlap"
rapid_outputs=()
for i in $(seq 1 12); do
	output_file="${TEST_ROOT}/rapid-${i}"
	rapid_outputs+=("${output_file}")
	${SCRIPT} cycle > "${output_file}" 2>&1 &
done
wait
[[ "$(cat "${MOCK_ROOT}/level")" == 3 ]]
assert_absent "${MOCK_ROOT}/overlap"
for output_file in "${rapid_outputs[@]}"; do
	grep -q '\[verified\]' "${output_file}"
done
grep -qxF 'preferred_level=3' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"

# Automatic idle is transient: it preserves the manual preference, never shows
# success OSD, and restores exactly that preference on activity.
${SCRIPT} set 2 >/dev/null
before_osd="$(wc -l < "${MOCK_ROOT}/osd")"
${SCRIPT} _auto-idle
grep -qxF 'preferred_level=2' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'effective_level=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'idle_suppressed=1' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
[[ "$(cat "${MOCK_ROOT}/level")" == 0 ]]

[[ "$(wc -l < "${MOCK_ROOT}/osd")" == "${before_osd}" ]]
${SCRIPT} _auto-resume
grep -qxF 'preferred_level=2' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'effective_level=2' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'idle_suppressed=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
[[ "$(cat "${MOCK_ROOT}/level")" == 2 ]]
[[ "$(wc -l < "${MOCK_ROOT}/osd")" == "${before_osd}" ]]

# A manual command racing with resume wins permanently in either order.
${SCRIPT} _auto-idle
${SCRIPT} set 3 >/dev/null
${SCRIPT} _auto-resume
grep -qxF 'preferred_level=3' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'effective_level=3' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'idle_suppressed=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} _auto-idle
${SCRIPT} _auto-resume
${SCRIPT} cycle >/dev/null
grep -qxF 'preferred_level=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"

# Manual Off is a preference, not an idle state, and never auto-restores.
${SCRIPT} set 0 >/dev/null
${SCRIPT} _auto-idle
${SCRIPT} _auto-resume
grep -qxF 'preferred_level=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'idle_suppressed=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
[[ "$(cat "${MOCK_ROOT}/level")" == 0 ]]

# Each new session/connection initializes Low once; service restarts with the
# same tokens preserve the manual preference.
session_token="$(printf 'a%.0s' {1..64})"
connection_one="$(printf 'b%.0s' {1..64})"
connection_two="$(printf 'c%.0s' {1..64})"
${SCRIPT} _auto-connect "${session_token}" "${connection_one}"
grep -qxF 'preferred_level=1' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'preference_source=default' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} set 3 >/dev/null
${SCRIPT} _auto-connect "${session_token}" "${connection_one}"
grep -qxF 'preferred_level=3' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} _auto-connect "${session_token}" "${connection_two}"
grep -qxF 'preferred_level=1' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"

# Disabling automatic management leaves manual Fn+F4 behavior intact.
${SCRIPT} _configure 0 900
${SCRIPT} set 2 >/dev/null
${SCRIPT} _auto-idle
[[ "$(cat "${MOCK_ROOT}/level")" == 2 ]]
grep -qxF 'enabled=0' "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
${SCRIPT} _configure 1 900

# Hostile configuration and session-marker symlinks are never followed.
rm -f -- "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
printf 'config-sentinel\n' > "${TEST_ROOT}/config-sentinel"
ln -s "${TEST_ROOT}/config-sentinel" "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
if ${SCRIPT} _configure 1 900 >/dev/null 2>&1; then
	echo "FAIL: configuration symlink was accepted" >&2
	exit 1
fi
grep -qxF config-sentinel "${TEST_ROOT}/config-sentinel"
rm -f -- "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
${SCRIPT} _configure 1 900
rm -f -- "${RUNTIME_ROOT}/zenbook-tweaks/kbd-backlight-session"
printf 'session-sentinel\n' > "${TEST_ROOT}/session-sentinel"
ln -s "${TEST_ROOT}/session-sentinel" "${RUNTIME_ROOT}/zenbook-tweaks/kbd-backlight-session"
if ${SCRIPT} _auto-connect "${session_token}" "${connection_one}" >/dev/null 2>&1; then
	echo "FAIL: session-marker symlink was accepted" >&2
	exit 1
fi
grep -qxF session-sentinel "${TEST_ROOT}/session-sentinel"
rm -f -- "${RUNTIME_ROOT}/zenbook-tweaks/kbd-backlight-session"

# A hostile lock symlink is rejected before discovery or HID I/O.
rm -f -- "${RUNTIME_ROOT}/zenbook-tweaks/kbd-backlight.lock"
printf 'lock-sentinel\n' > "${TEST_ROOT}/lock-sentinel"
ln -s "${TEST_ROOT}/lock-sentinel" "${RUNTIME_ROOT}/zenbook-tweaks/kbd-backlight.lock"
if ${SCRIPT} status >/dev/null 2>&1; then
	echo "FAIL: lock symlink was accepted" >&2
	exit 1
fi
grep -qxF lock-sentinel "${TEST_ROOT}/lock-sentinel"
rm -f -- "${RUNTIME_ROOT}/zenbook-tweaks/kbd-backlight.lock"

# A hostile state symlink is rejected and never produces success feedback.
rm -f -- "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
printf 'sentinel\n' > "${TEST_ROOT}/sentinel"
ln -s "${TEST_ROOT}/sentinel" "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
before_osd="$(wc -l < "${MOCK_ROOT}/osd")"
if ${SCRIPT} set 1 >/dev/null 2>&1; then
	echo "FAIL: state symlink was accepted" >&2
	exit 1
fi
grep -qxF sentinel "${TEST_ROOT}/sentinel"
[[ "$(wc -l < "${MOCK_ROOT}/osd")" == "${before_osd}" ]]

# The event-driven daemon handles connect, timeout, keyboard resume, touchpad
# activity, disconnect, and reconnect without exposing raw event contents.
DAEMON_CONTROLLER="${TEST_ROOT}/daemon-controller"
ACTIVITY_SOURCE="${TEST_ROOT}/activity-source"
DAEMON_CALLS="${TEST_ROOT}/daemon-calls"
cat > "${DAEMON_CONTROLLER}" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DAEMON_CALLS}"
MOCK
cat > "${ACTIVITY_SOURCE}" <<'MOCK'
#!/usr/bin/env bash
printf 'connect %064d\n' 1
sleep 1.2
echo keyboard
sleep 0.1
echo touchpad
echo disconnect
printf 'connect %064d\n' 2
MOCK
chmod 755 "${DAEMON_CONTROLLER}" "${ACTIVITY_SOURCE}"
export DAEMON_CALLS
KBD_BACKLIGHT_SESSION_TOKEN="$(printf 'd%.0s' {1..64})" \
KBD_BACKLIGHT_ACTIVITY_SOURCE="${ACTIVITY_SOURCE}" \
	"${ACTIVITY_DAEMON}" "${DAEMON_CONTROLLER}" 1
grep -q '^_auto-connect d\{64\} 0\{63\}1$' "${DAEMON_CALLS}"
grep -qxF '_auto-idle' "${DAEMON_CALLS}"
grep -qxF '_auto-resume' "${DAEMON_CALLS}"
grep -q '^_auto-connect d\{64\} 0\{63\}2$' "${DAEMON_CALLS}"

# EOF on detached Bluetooth descriptors must unregister them immediately. A
# pending rescan cannot be postponed, and the next scan adopts the USB nodes.
PYTHONDONTWRITEBYTECODE=1 KBD_BACKLIGHT_SESSION_TOKEN="$(printf 'e%.0s' {1..64})" python3 - \
	"${ACTIVITY_DAEMON}" <<'PY'
import importlib.machinery
import importlib.util
import os
import pathlib
import time
import sys

loader = importlib.machinery.SourceFileLoader("kbd_activity", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

mode = ["bluetooth"]
writers = []
calls = []

def selected(_root):
    if mode[0] == "bluetooth":
        return ("bluetooth", module.BLUETOOTH_ID, "1" * 64)
    return ("usb", module.USB_ID, "2" * 64)

def nodes(_sysfs, _dev, _identity):
    names = ("event4", "event7") if mode[0] == "bluetooth" else ("event28", "event6")
    result = []
    for kind, name in zip(("keyboard", "touchpad"), names):
        reader, writer = os.pipe()
        writers.append(writer)
        result.append((reader, kind, name))
    return result

module.selected_backlight = selected
module.activity_nodes = nodes
module.controller_call = lambda _controller, *args: calls.append(args) or True
watcher = module.Watcher("/bin/true", 900, "/nonexistent", "/nonexistent")
watcher.rescan()
old_descriptors = list(watcher.input_descriptors)
for writer in writers:
    os.close(writer)
writers.clear()
for descriptor in old_descriptors:
    watcher.input_ready(descriptor)
assert not watcher.input_descriptors
first_due = watcher.rescan_due
assert first_due > time.monotonic()
watcher.schedule_rescan(0.25)
assert watcher.rescan_due == first_due
for descriptor in old_descriptors:
    try:
        os.fstat(descriptor)
    except OSError:
        pass
    else:
        raise AssertionError("detached descriptor remained open")
mode[0] = "usb"
watcher.rescan()
assert watcher.connection_token == "2" * 64
assert set(watcher.input_names.values()) == {"event28", "event6"}
health = watcher.health_file.read_text()
assert "transport=usb\n" in health
assert "keyboard=event28\n" in health
assert "touchpad=event6\n" in health
watcher.close_inputs()
watcher.remove_health()
for writer in writers:
    os.close(writer)
PY

echo "kbd-backlight runtime tests passed"
