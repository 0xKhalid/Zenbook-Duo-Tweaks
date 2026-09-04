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
[[ "$(grep -c 'ATTRS{phys}=="input-remapper/\*"' "${RULE}")" == 4 ]]
grep -q 'ATTRS{id/product}=="1cd7".*ATTRS{name}=="Primax Electronics Ltd. ASUS Zenbook Duo Keyboard".*ID_INPUT_KEYBOARD' "${RULE}"
grep -q 'ATTRS{id/product}=="1cd8".*ATTRS{name}=="ASUS Zenbook Duo Keyboard".*ID_INPUT_KEYBOARD' "${RULE}"
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
export KBD_BACKLIGHT_ACTIVITY_HELPER="${ACTIVITY_DAEMON}"
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
assert_contains "${status}" "Adaptive ambient lighting: disabled; thresholds=10/75/300 lux"
assert_contains "${status}" "Ambient sensor: unavailable"
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

# Ambient targets are silent, survive idle as the preferred level, yield to a
# manual override, and regain control only after a new connection or login.
${SCRIPT} _configure 1 900 1 10 75 300
before_osd="$(wc -l < "${MOCK_ROOT}/osd")"
${SCRIPT} _auto-target 3 ambient
grep -qxF 'preferred_level=3' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'preference_source=ambient' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} _auto-idle
${SCRIPT} _auto-target 2 ambient
grep -qxF 'preferred_level=2' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'effective_level=0' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'idle_suppressed=1' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} _auto-resume
[[ "$(cat "${MOCK_ROOT}/level")" == 2 ]]
${SCRIPT} set 0 >/dev/null
assert_contains "$(${SCRIPT} _auto-target 3 ambient)" 'result=manual-override'
[[ "$(cat "${MOCK_ROOT}/level")" == 0 ]]
connection_three="$(printf 'f%.0s' {1..64})"
${SCRIPT} _auto-connect "${session_token}" "${connection_three}"
grep -qxF 'preference_source=default' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} _auto-target 0 ambient
grep -qxF 'preference_source=ambient' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
[[ "$(cat "${MOCK_ROOT}/level")" == 0 ]]
${SCRIPT} _auto-target 1 fallback
grep -qxF 'preferred_level=1' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'preference_source=default' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
[[ "$(cat "${MOCK_ROOT}/level")" == 1 ]]
${SCRIPT} _auto-target 3 ambient
${SCRIPT} _configure 1 900 0 10 75 300
${SCRIPT} _auto-fixed
grep -qxF 'preferred_level=1' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF 'preference_source=default' "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
[[ "$(cat "${MOCK_ROOT}/level")" == 1 ]]
[[ "$(wc -l < "${MOCK_ROOT}/osd")" == $((before_osd + 1)) ]]

# Invalid or non-increasing ambient thresholds are rejected.
if ${SCRIPT} _configure 1 900 1 75 10 300 >/dev/null 2>&1; then
	echo "FAIL: non-increasing ambient thresholds were accepted" >&2
	exit 1
fi
if ${SCRIPT} _configure 1 900 1 10 75 100001 >/dev/null 2>&1; then
	echo "FAIL: out-of-range ambient threshold was accepted" >&2
	exit 1
fi

# Existing v1 config and v2 state migrate without enabling ambient control or
# changing the remembered manual preference.
printf 'version=1\nenabled=1\nidle_timeout_seconds=600\n' > \
	"${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
chmod 600 "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
printf 'version=2\npreferred_level=2\neffective_level=2\ntransport=bluetooth\npreference_source=manual\nidle_suppressed=0\n' > \
	"${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
chmod 600 "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
${SCRIPT} _migrate
grep -qxF version=2 "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
grep -qxF ambient_enabled=0 "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
grep -qxF ambient_dark_lux=10 "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
grep -qxF version=3 "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"
grep -qxF preferred_level=2 "${STATE_ROOT}/zenbook-tweaks/kbd-backlight/state"

# Source-aware health accepts only the v3 ambient schema and reports fixed,
# privacy-safe bands rather than sensor paths or input contents.
(
	export KBD_BACKLIGHT_SOURCE_ONLY=true
	# shellcheck source=/dev/null
	source "${SCRIPT}"
	WATCHER_HEALTH_FILE="${TEST_ROOT}/watcher-health"
	printf 'version=3\ntransport=bluetooth\nkeyboard=event25\nkeyboard_source=forwarded\ntouchpad=event7\ntouchpad_source=physical\nambient_status=available\nambient_lux=4\nambient_band=dark\nambient_target=3\n' > \
		"${WATCHER_HEALTH_FILE}"
	chmod 600 "${WATCHER_HEALTH_FILE}"
	DEVICE_TRANSPORT=bluetooth
	ACTIVITY_KEYBOARD=event25
	ACTIVITY_KEYBOARD_SOURCE=forwarded
	ACTIVITY_TOUCHPAD=event7
	ACTIVITY_TOUCHPAD_SOURCE=physical
	AMBIENT_ENABLED=1
	health_status="$(watcher_health_status active)"
	assert_contains "${health_status}" "Watcher selection consistent: yes"
	assert_contains "${health_status}" "Ambient watcher: status=available; sampled_lux=4; band=dark; target=High (3)"
)

# Disabling automatic management leaves manual Fn+F4 behavior intact.
${SCRIPT} _configure 0 900 0 10 75 300
${SCRIPT} set 2 >/dev/null
${SCRIPT} _auto-idle
[[ "$(cat "${MOCK_ROOT}/level")" == 2 ]]
grep -qxF 'enabled=0' "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
${SCRIPT} _configure 1 900 0 10 75 300

# Hostile configuration and session-marker symlinks are never followed.
rm -f -- "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
printf 'config-sentinel\n' > "${TEST_ROOT}/config-sentinel"
ln -s "${TEST_ROOT}/config-sentinel" "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
if ${SCRIPT} _configure 1 900 0 10 75 300 >/dev/null 2>&1; then
	echo "FAIL: configuration symlink was accepted" >&2
	exit 1
fi
grep -qxF config-sentinel "${TEST_ROOT}/config-sentinel"
rm -f -- "${CONFIG_ROOT}/zenbook-tweaks/kbd-backlight.conf"
${SCRIPT} _configure 1 900 0 10 75 300
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
case "$1" in
	_auto-connect) echo 'result=initialized' ;;
	_auto-idle) echo 'result=idled' ;;
	_auto-resume) echo 'result=resumed' ;;
esac
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
DAEMON_LOG="${TEST_ROOT}/daemon-log"
KBD_BACKLIGHT_SESSION_TOKEN="$(printf 'd%.0s' {1..64})" \
KBD_BACKLIGHT_ACTIVITY_SOURCE="${ACTIVITY_SOURCE}" \
	"${ACTIVITY_DAEMON}" "${DAEMON_CONTROLLER}" 1 0 10 75 300 2> "${DAEMON_LOG}"
grep -q '^_auto-connect d\{64\} 0\{63\}1$' "${DAEMON_CALLS}"
grep -qxF '_auto-idle' "${DAEMON_CALLS}"
grep -qxF '_auto-resume' "${DAEMON_CALLS}"
grep -q '^_auto-connect d\{64\} 0\{63\}2$' "${DAEMON_CALLS}"
grep -qxF 'kbd-backlight activity: idle-off timeout=1' "${DAEMON_LOG}"
grep -qxF 'kbd-backlight activity: activity-restored source=keyboard-test' "${DAEMON_LOG}"

# The ALS reader accepts exactly one canonical sensor, applies offset/scale,
# rejects unsafe or malformed inputs, and uses deterministic band hysteresis.
PYTHONDONTWRITEBYTECODE=1 KBD_BACKLIGHT_SESSION_TOKEN="$(printf '9%.0s' {1..64})" python3 - \
	"${ACTIVITY_DAEMON}" <<'PY'
import importlib.machinery
import importlib.util
import pathlib
import shutil
import tempfile
import sys

loader = importlib.machinery.SourceFileLoader("kbd_ambient", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

temporary = pathlib.Path(tempfile.mkdtemp())
root = temporary / "sys"
device = root / "devices/platform/als/iio:device0"
links = root / "bus/iio/devices"
device.mkdir(parents=True)
links.mkdir(parents=True)
(links / "iio:device0").symlink_to(device)
(device / "name").write_text("als\n")
(device / "in_illuminance_raw").write_text("100\n")
(device / "in_illuminance_scale").write_text("0.1\n")
(device / "in_illuminance_offset").write_text("10\n")

sensor = module.discover_ambient_sensor(root)
assert sensor is not None
assert module.read_ambient_lux(sensor) == 11.0
thresholds = (10, 75, 300)
assert [module.base_ambient_band(value, thresholds) for value in (9.9, 10, 74, 75, 299, 300)] == [0, 1, 1, 2, 2, 3]
assert module.ambient_band(11, thresholds, 0) == 0
assert module.ambient_band(12, thresholds, 0) == 1
assert module.ambient_band(9, thresholds, 1) == 1
assert module.ambient_band(7.9, thresholds, 1) == 0
assert module.ambient_band(350, thresholds, 2) == 2
assert module.ambient_band(360, thresholds, 2) == 3
assert module.ambient_band(250, thresholds, 3) == 3
assert module.ambient_band(239, thresholds, 3) == 2

(device / "in_illuminance_raw").write_text("nan\n")
assert module.read_ambient_lux(sensor) is None
(device / "in_illuminance_raw").unlink()
(device / "raw-target").write_text("5\n")
(device / "in_illuminance_raw").symlink_to(device / "raw-target")
assert module.read_ambient_lux(sensor) is None
(device / "in_illuminance_raw").unlink()
(device / "in_illuminance_raw").write_text("5\n")

second = root / "devices/platform/als/iio:device1"
second.mkdir(parents=True)
(second / "name").write_text("als\n")
(second / "in_illuminance_raw").write_text("20\n")
(second / "in_illuminance_scale").write_text("1\n")
(links / "iio:device1").symlink_to(second)
assert module.discover_ambient_sensor(root) is None
(links / "iio:device1").unlink()
shutil.rmtree(second)

calls = []
module.controller_call = lambda _controller, *args: calls.append(args) or "result=ambient-updated"
(device / "in_illuminance_offset").write_text("0\n")
(device / "in_illuminance_scale").write_text("0.001\n")
(device / "in_illuminance_raw").write_text("5000\n")
watcher = module.Watcher("/bin/true", 900, True, 10, 75, 300, root, temporary / "dev")
watcher.connection_token = "1" * 64
watcher.write_health("bluetooth", "event25", "forwarded", "event7", "physical")
for _ in range(3):
    watcher.poll_ambient()
assert calls[-1] == ("_auto-target", "3", "ambient")
assert watcher.ambient_band == 0

(device / "in_illuminance_raw").write_text("400000\n")
for _ in range(3):
    watcher.poll_ambient()
assert calls[-1] == ("_auto-target", "0", "ambient")
assert watcher.ambient_band == 3

(device / "in_illuminance_raw").write_text("bad\n")
for _ in range(3):
    watcher.poll_ambient()
assert calls[-1] == ("_auto-target", "1", "fallback")
assert watcher.ambient_status == "unavailable"
health = watcher.health_file.read_text()
assert "ambient_status=unavailable\n" in health
assert "ambient_target=1\n" in health

(device / "in_illuminance_raw").write_text("100000\n")
for _ in range(3):
    watcher.poll_ambient()
assert calls[-1] == ("_auto-target", "1", "ambient")
assert watcher.ambient_status == "available"
assert watcher.ambient_band == 2
watcher.remove_health()
shutil.rmtree(temporary)
PY

# Exact input-remapper copies replace only the grabbed activity class. Wrong
# virtual devices are ignored, and ambiguous forwarded copies fail closed.
PYTHONDONTWRITEBYTECODE=1 python3 - "${ACTIVITY_DAEMON}" <<'PY'
import importlib.machinery
import importlib.util
import os
import pathlib
import shutil
import tempfile
import sys

loader = importlib.machinery.SourceFileLoader("kbd_activity", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

temporary = pathlib.Path(tempfile.mkdtemp())
root = temporary / "sys"
dev_root = temporary / "dev"
(root / "class/input").mkdir(parents=True)
(root / "devices/virtual/input").mkdir(parents=True)
(root / "devices/physical").mkdir(parents=True)
(dev_root / "input").mkdir(parents=True)
properties = {}

def add_event(event, device, kind):
    event_dir = device / event
    event_dir.mkdir(parents=True)
    (event_dir / "device").symlink_to("..")
    (root / "class/input" / event).symlink_to(event_dir)
    (dev_root / "input" / event).symlink_to("/dev/null")
    properties[event] = {f"ID_INPUT_{kind.upper()}": "1"}

def add_physical(event, identity, kind, suffix):
    hid = root / "devices/physical" / f"hid-{suffix}"
    device = hid / "input" / f"input-{suffix}"
    device.mkdir(parents=True)
    (hid / "uevent").write_text(f"HID_ID={identity}\n")
    add_event(event, device, kind)

def add_forwarded(event, identity, kind, suffix, *, name=None, vendor="0b05", product=None):
    expected = module.FORWARDED_IDENTITIES[identity]
    device = root / "devices/virtual/input" / f"input-{suffix}"
    (device / "id").mkdir(parents=True)
    (device / "phys").write_text("input-remapper/forwarded\n")
    (device / "name").write_text((name or expected[kind]) + "\n")
    (device / "id/bustype").write_text(expected["bus"] + "\n")
    (device / "id/vendor").write_text(vendor + "\n")
    (device / "id/product").write_text((product or expected["product"]) + "\n")
    add_event(event, device, kind)

def remove_event(event):
    device = (root / "class/input" / event / "device").resolve()
    (root / "class/input" / event).unlink()
    (dev_root / "input" / event).unlink()
    shutil.rmtree(device)
    properties.pop(event)

def selected(identity):
    nodes = module.activity_nodes(root, dev_root, identity)
    result = {(kind, name, source) for _, kind, name, source in nodes}
    for descriptor, _, _, _ in nodes:
        os.close(descriptor)
    return result

module.read_properties = lambda path: properties.get(path.name, {})

add_physical("event4", module.BLUETOOTH_ID, "keyboard", "bt-kbd")
add_physical("event7", module.BLUETOOTH_ID, "touchpad", "bt-touch")
add_forwarded("event25", module.BLUETOOTH_ID, "keyboard", "bt-forward")
add_forwarded(
    "event30",
    module.BLUETOOTH_ID,
    "keyboard",
    "unrelated",
    name="Logitech MX Ergo Multi-Device Trackball",
    vendor="046d",
    product="b02f",
)
assert selected(module.BLUETOOTH_ID) == {
    ("keyboard", "event25", "forwarded"),
    ("touchpad", "event7", "physical"),
}
remove_event("event25")
assert selected(module.BLUETOOTH_ID) == {
    ("keyboard", "event4", "physical"),
    ("touchpad", "event7", "physical"),
}
add_forwarded("event25", module.BLUETOOTH_ID, "keyboard", "bt-forward-recreated")

add_forwarded("event26", module.BLUETOOTH_ID, "touchpad", "bt-touch-forward")
assert selected(module.BLUETOOTH_ID) == {
    ("keyboard", "event25", "forwarded"),
    ("touchpad", "event26", "forwarded"),
}
remove_event("event26")

add_forwarded("event27", module.BLUETOOTH_ID, "keyboard", "bt-duplicate")
assert selected(module.BLUETOOTH_ID) == set()
remove_event("event27")

add_forwarded(
    "event27",
    module.BLUETOOTH_ID,
    "keyboard",
    "bt-wrong-name",
    name="ASUS Zenbook Duo Keyboard Copy",
)
assert selected(module.BLUETOOTH_ID) == {
    ("keyboard", "event25", "forwarded"),
    ("touchpad", "event7", "physical"),
}

add_physical("event40", module.USB_ID, "keyboard", "usb-kbd")
add_physical("event41", module.USB_ID, "touchpad", "usb-touch")
add_forwarded("event42", module.USB_ID, "keyboard", "usb-forward")
assert selected(module.USB_ID) == {
    ("keyboard", "event42", "forwarded"),
    ("touchpad", "event41", "physical"),
}
remove_event("event42")
assert selected(module.USB_ID) == {
    ("keyboard", "event40", "physical"),
    ("touchpad", "event41", "physical"),
}

shutil.rmtree(temporary)
PY

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
        source = "forwarded" if kind == "keyboard" else "physical"
        result.append((reader, kind, name, source))
    return result

module.selected_backlight = selected
module.activity_nodes = nodes
def controller(_controller, *args):
    calls.append(args)
    return "result=unchanged" if args[0] == "_auto-connect" else "result=resumed"

module.controller_call = controller
watcher = module.Watcher(
    "/bin/true", 900, False, 10, 75, 300, "/nonexistent", "/nonexistent"
)
watcher.rescan()
forwarded_descriptor = next(
    descriptor
    for descriptor, kind in watcher.input_descriptors.items()
    if kind == "keyboard"
)
watcher.idled = True
os.write(writers[0], module.EVENT.pack(0, 0, module.EV_KEY, 30, 1))
watcher.input_ready(forwarded_descriptor)
assert ("_auto-resume",) in calls
assert not watcher.idled
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
assert "keyboard_source=forwarded\n" in health
assert "touchpad=event6\n" in health
assert "touchpad_source=physical\n" in health
assert "ambient_status=disabled\n" in health
watcher.close_inputs()
watcher.remove_health()
for writer in writers:
    os.close(writer)
PY

echo "kbd-backlight runtime tests passed"
