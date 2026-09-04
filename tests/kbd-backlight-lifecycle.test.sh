#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
export SUDO_USER="${CURRENT_USER}"
export STATE_DIR="${TEST_ROOT}/manager-state"
export BACKUP_DIR="${TEST_ROOT}/manager-backups"
export KBD_TWEAK_SCRIPT_DEST="${TEST_ROOT}/system/usr/local/bin/kbd-backlight"
export KBD_TWEAK_RULE_DEST="${TEST_ROOT}/system/etc/udev/rules.d/70-asus-kbd-backlight.rules"
export KBD_TWEAK_ACTIVITY_DEST="${TEST_ROOT}/system/usr/local/libexec/kbd-backlight-activity"
export KBD_TWEAK_UNIT_DEST="${TEST_ROOT}/system/usr/local/lib/systemd/user/zenbook-duo-kbd-backlight-activity.service"
export KBD_TWEAK_LEGACY_RULE="${TEST_ROOT}/system/etc/udev/rules.d/99-asus-kbd-backlight.rules"
export KBD_TWEAK_LEGACY_TMP="${TEST_ROOT}/legacy/kbd-backlight-level"
export KBD_TWEAK_STATE_OWNER_UID="${CURRENT_UID}"
export KBD_TWEAK_STATE_OWNER_GID="${CURRENT_GID}"
export KBD_TWEAK_SYSTEM_OWNER="${CURRENT_USER}"
export KBD_TWEAK_SYSTEM_GROUP="$(id -gn)"
export KBD_TWEAK_SYSTEM_UID="${CURRENT_UID}"
export KBD_TWEAK_SYSTEM_GID="${CURRENT_GID}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/tweaks/kbd-backlight/tweak.conf"

TARGET_HOME="${TEST_ROOT}/home"
SHORTCUT_VALUE_FILE="${TEST_ROOT}/shortcut-value"
SHORTCUT_KEYS_FILE="${TEST_ROOT}/shortcut-keys"
SHORTCUT_RUNTIME_FILE="${TEST_ROOT}/shortcut-runtime"
INPUT_MEMBER_FILE="${TEST_ROOT}/input-member"
UNRELATED_SHORTCUT_FILE="${TEST_ROOT}/unrelated-shortcut"
FAIL_SHORTCUT_FILE="${TEST_ROOT}/fail-shortcut"
mkdir -p "${TARGET_HOME}/.local/share/applications" "$(dirname "${_KBL_SCRIPT_DEST}")" \
	"$(dirname "${_KBL_RULE_DEST}")" "$(dirname "${_KBL_LEGACY_TMP}")"
printf 'Meta+Shift+U\n' > "${UNRELATED_SHORTCUT_FILE}"

_kbl_load_target()
{
	_KBL_TARGET_USER="${CURRENT_USER}"
	_KBL_TARGET_UID="${CURRENT_UID}"
	_KBL_TARGET_GID="${CURRENT_GID}"
	_KBL_TARGET_HOME="${TARGET_HOME}"
}

_kbl_session_active() { return 0; }
_kbl_f4_available() { [[ ! -e "${TEST_ROOT}/f4-conflict" ]]; }
_kbl_apply_udev_access() { return 0; }
_kbl_reload_udev() { return 0; }
_kbl_trigger_target_hidraw() { return 0; }
_kbl_verify_uaccess() { return 0; }
_kbl_verify_activity_uaccess() { return 0; }
_kbl_start_activity_service() { return 0; }
_kbl_revoke_managed_device_access() { return 0; }
_kbl_reenumerate_target_devices() { return 0; }
_kbl_as_user()
{
	if [[ "${1:-}" == test ]]; then
		shift
		command test "$@"
	fi
	if [[ "${1:-}" == "${_KBL_SCRIPT_DEST}" && "${2:-}" == status ]]; then
		echo "Watcher selection consistent: yes"
	fi
	return 0
}
_kbl_user_in_input() { [[ "$(cat "${INPUT_MEMBER_FILE}" 2>/dev/null || echo 0)" == 1 ]]; }
_kbl_remove_input_membership() { printf '0\n' > "${INPUT_MEMBER_FILE}"; }
_kbl_add_input_membership() { printf '1\n' > "${INPUT_MEMBER_FILE}"; }
_kbl_shortcut_value()
{
	[[ -f "${SHORTCUT_VALUE_FILE}" ]] && cat "${SHORTCUT_VALUE_FILE}" || echo __KBL_ABSENT__
}
_kbl_shortcut_runtime_present()
{
	[[ "$(cat "${SHORTCUT_RUNTIME_FILE}" 2>/dev/null || echo 0)" == 1 ]]
}
_kbl_shortcut_keys() { cat "${SHORTCUT_KEYS_FILE}"; }
_kbl_set_shortcut_f4()
{
	[[ ! -e "${FAIL_SHORTCUT_FILE}" ]] || return 1
	printf 'F4\n' > "${SHORTCUT_VALUE_FILE}"
	printf '[([16777267,0,0,0],)]\n' > "${SHORTCUT_KEYS_FILE}"
	printf '1\n' > "${SHORTCUT_RUNTIME_FILE}"
}
_kbl_restore_shortcut()
{
	if [[ "$(_kbl_manifest_value shortcut_present)" == 1 ]]; then
		_kbl_decode "$(_kbl_manifest_value shortcut_value_b64)" > "${SHORTCUT_VALUE_FILE}"
	else
		rm -f -- "${SHORTCUT_VALUE_FILE}"
	fi
	if [[ "$(_kbl_manifest_value shortcut_runtime_present)" == 1 ]]; then
		_kbl_decode "$(_kbl_manifest_value shortcut_keys_b64)" > "${SHORTCUT_KEYS_FILE}"
		printf '1\n' > "${SHORTCUT_RUNTIME_FILE}"
	else
		rm -f -- "${SHORTCUT_KEYS_FILE}"
		printf '0\n' > "${SHORTCUT_RUNTIME_FILE}"
	fi
}
_kbl_import_legacy_cache()
{
	local state_dir="${TARGET_HOME}/.local/state/zenbook-tweaks/kbd-backlight"
	mkdir -p "${state_dir}"
	chmod 700 "${state_dir}"
	printf 'version=1\nlevel=%s\ntransport=legacy\n' "$1" > "${state_dir}/state"
	chmod 600 "${state_dir}/state"
}

assert_file() { [[ -f "$1" ]] || { echo "FAIL: expected file $1" >&2; exit 1; }; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || { echo "FAIL: expected absent $1" >&2; exit 1; }; }
assert_same() { cmp -s "$1" "$2" || { echo "FAIL: expected $1 and $2 to match" >&2; exit 1; }; }

reset_initial_state()
{
	rm -rf -- "${STATE_DIR}" "${BACKUP_DIR}" "${TEST_ROOT}/system" "${TARGET_HOME}"
	mkdir -p "${TARGET_HOME}/.local/share/applications" "$(dirname "${_KBL_SCRIPT_DEST}")" \
		"$(dirname "${_KBL_RULE_DEST}")" "$(dirname "${_KBL_LEGACY_TMP}")"
	printf '#!/usr/bin/env bash\necho legacy-controller\n' > "${_KBL_SCRIPT_DEST}"
	printf '# legacy input-group rule\n' > "${_KBL_LEGACY_RULE}"
	chmod 755 "${_KBL_SCRIPT_DEST}"
	_KBL_LEGACY_SCRIPT_SHA256="$(_kbl_sha256 "${_KBL_SCRIPT_DEST}")"
	_KBL_LEGACY_RULE_SHA256="$(_kbl_sha256 "${_KBL_LEGACY_RULE}")"
	cp "${_KBL_LAUNCHER_SOURCE}" "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
	chmod 600 "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
	printf 'F4\n' > "${SHORTCUT_VALUE_FILE}"
	printf '[([16777267,0,0,0],)]\n' > "${SHORTCUT_KEYS_FILE}"
	printf '1\n' > "${SHORTCUT_RUNTIME_FILE}"
	printf '1\n' > "${INPUT_MEMBER_FILE}"
	printf '2\n' > "${_KBL_LEGACY_TMP}"
	rm -f -- "${FAIL_SHORTCUT_FILE}" "${TEST_ROOT}/f4-conflict"
}

reset_initial_state
original_launcher="${TEST_ROOT}/original-launcher"
cp -a "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop" "${original_launcher}"

# The preflight refuses an unrelated F4 owner without changing anything.
touch "${TEST_ROOT}/f4-conflict"
if tweak_pre_install >/dev/null 2>&1; then
	echo "FAIL: unrelated F4 conflict was accepted" >&2
	exit 1
fi
assert_same "${original_launcher}" "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
rm -f -- "${TEST_ROOT}/f4-conflict"
tweak_pre_install >/dev/null

# A partial post-install failure restores every captured artifact and leaves no record.
touch "${FAIL_SHORTCUT_FILE}"
if tweak_post_install >/dev/null 2>&1; then
	echo "FAIL: simulated shortcut failure was reported as success" >&2
	exit 1
fi
assert_same "${original_launcher}" "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
grep -qxF F4 "${SHORTCUT_VALUE_FILE}"
grep -qxF 1 "${INPUT_MEMBER_FILE}"
grep -qxF 2 "${_KBL_LEGACY_TMP}"
[[ "$(_kbl_sha256 "${_KBL_SCRIPT_DEST}")" == "${_KBL_LEGACY_SCRIPT_SHA256}" ]]
[[ "$(_kbl_sha256 "${_KBL_LEGACY_RULE}")" == "${_KBL_LEGACY_RULE_SHA256}" ]]
assert_absent "${_KBL_MANIFEST}"
assert_absent "${_KBL_AUTO_MANIFEST}"
assert_absent "${_KBL_BACKUP_ROOT}"
assert_absent "${_KBL_ACTIVITY_DEST}"
assert_absent "${_KBL_UNIT_DEST}"
assert_absent "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"
rm -f -- "${FAIL_SHORTCUT_FILE}"

# A complete migration adopts the launcher, retires legacy state, and tracks group removal.
tweak_pre_install >/dev/null
tweak_post_install >/dev/null
_kbl_manifest_valid
_kbl_auto_manifest_valid
grep -qxF phase=installed "${_KBL_MANIFEST}"
grep -qxF phase=installed "${_KBL_AUTO_MANIFEST}"
grep -qxF input_removed=1 "${_KBL_MANIFEST}"
grep -qxF 0 "${INPUT_MEMBER_FILE}"
assert_absent "${_KBL_LEGACY_RULE}"
assert_absent "${_KBL_LEGACY_TMP}"
assert_same "${_KBL_SCRIPT_SOURCE}" "${_KBL_SCRIPT_DEST}"
assert_same "${_KBL_RULE_SOURCE}" "${_KBL_RULE_DEST}"
assert_same "${_KBL_LAUNCHER_SOURCE}" "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
assert_same "${_KBL_ACTIVITY_SOURCE}" "${_KBL_ACTIVITY_DEST}"
assert_same "${_KBL_UNIT_SOURCE}" "${_KBL_UNIT_DEST}"
grep -qxF enabled=1 "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"
grep -qxF idle_timeout_seconds=900 "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"
[[ "$(stat -c %a "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf")" == 600 ]]
[[ "$(stat -c %a "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop")" == 644 ]]
grep -qxF 'Meta+Shift+U' "${UNRELATED_SHORTCUT_FILE}"
[[ "$(tweak_status_check)" == installed ]]

# Corrupted rollback content is detected before reinstall or uninstall.
printf '\ncorrupt\n' >> "${_KBL_BACKUP_LAUNCHER}"
if _kbl_manifest_valid; then
	echo "FAIL: corrupted launcher backup was accepted" >&2
	exit 1
fi
cp -a "${original_launcher}" "${_KBL_BACKUP_LAUNCHER}"
_kbl_manifest_valid

# An already-installed v2.13 baseline without automatic-lighting records is
# extended in place without recapturing the original launcher/shortcut/group.
baseline_launcher_sha="$(_kbl_sha256 "${_KBL_BACKUP_LAUNCHER}")"
rm -f -- "${_KBL_AUTO_MANIFEST}" "${_KBL_ACTIVITY_DEST}" "${_KBL_UNIT_DEST}" \
	"${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"
tweak_pre_install >/dev/null
tweak_post_install >/dev/null
_kbl_auto_manifest_valid
[[ "$(_kbl_sha256 "${_KBL_BACKUP_LAUNCHER}")" == "${baseline_launcher_sha}" ]]

# Reinstall keeps the first-install backup and does not repeat legacy/group migration.
launcher_backup_sha="$(_kbl_sha256 "${_KBL_BACKUP_LAUNCHER}")"
tweak_pre_install >/dev/null
tweak_post_install >/dev/null
[[ "$(_kbl_sha256 "${_KBL_BACKUP_LAUNCHER}")" == "${launcher_backup_sha}" ]]
grep -qxF 0 "${INPUT_MEMBER_FILE}"

# A failed reinstall leaves the already-managed installation and first baseline intact.
touch "${FAIL_SHORTCUT_FILE}"
tweak_pre_install >/dev/null
if tweak_post_install >/dev/null 2>&1; then
	echo "FAIL: simulated reinstall failure was reported as success" >&2
	exit 1
fi
rm -f -- "${FAIL_SHORTCUT_FILE}"
_kbl_manifest_valid
_kbl_managed_files_pristine
[[ "$(_kbl_sha256 "${_KBL_BACKUP_LAUNCHER}")" == "${launcher_backup_sha}" ]]
grep -qxF 0 "${INPUT_MEMBER_FILE}"

# Unknown user edits block destructive uninstall.
printf '\n# user edit\n' >> "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
if tweak_pre_uninstall >/dev/null 2>&1; then
	echo "FAIL: modified managed launcher was removed" >&2
	exit 1
fi
sed -i '$d' "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
sed -i '$d' "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
assert_same "${_KBL_LAUNCHER_SOURCE}" "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
printf '%s\n' '# user edit' >> "${_KBL_ACTIVITY_DEST}"
if tweak_pre_uninstall >/dev/null 2>&1; then
	echo "FAIL: modified activity daemon was removed" >&2
	exit 1
fi
cp "${_KBL_ACTIVITY_SOURCE}" "${_KBL_ACTIVITY_DEST}"
chmod 755 "${_KBL_ACTIVITY_DEST}"

# Uninstall restores the exact prior launcher/shortcut/group and removes only owned files.
tweak_pre_uninstall >/dev/null
tweak_post_uninstall >/dev/null
assert_same "${original_launcher}" "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
[[ "$(stat -c %a "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop")" == 600 ]]
grep -qxF F4 "${SHORTCUT_VALUE_FILE}"
grep -qxF '[([16777267,0,0,0],)]' "${SHORTCUT_KEYS_FILE}"
grep -qxF 1 "${INPUT_MEMBER_FILE}"
grep -qxF 'Meta+Shift+U' "${UNRELATED_SHORTCUT_FILE}"
assert_absent "${_KBL_SCRIPT_DEST}"
assert_absent "${_KBL_RULE_DEST}"
assert_absent "${_KBL_LEGACY_RULE}"
assert_absent "${_KBL_MANIFEST}"
assert_absent "${_KBL_AUTO_MANIFEST}"
assert_absent "${_KBL_BACKUP_ROOT}"
assert_absent "${_KBL_ACTIVITY_DEST}"
assert_absent "${_KBL_UNIT_DEST}"
assert_absent "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"

# Foreign system files at the managed paths are restored exactly, not deleted.
reset_initial_state
printf '#!/usr/bin/env bash\necho foreign\n' > "${_KBL_SCRIPT_DEST}"
chmod 700 "${_KBL_SCRIPT_DEST}"
printf '# foreign new-name rule\n' > "${_KBL_RULE_DEST}"
chmod 600 "${_KBL_RULE_DEST}"
printf '# foreign legacy-name rule\n' > "${_KBL_LEGACY_RULE}"
chmod 640 "${_KBL_LEGACY_RULE}"
mkdir -p "$(dirname "${_KBL_ACTIVITY_DEST}")" "$(dirname "${_KBL_UNIT_DEST}")" \
	"${TARGET_HOME}/.config/zenbook-tweaks"
printf '#!/usr/bin/env bash\necho foreign-activity\n' > "${_KBL_ACTIVITY_DEST}"
printf '[Service]\nExecStart=/bin/true\n' > "${_KBL_UNIT_DEST}"
printf 'version=1\nenabled=0\nidle_timeout_seconds=600\n' > "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"
chmod 700 "${_KBL_ACTIVITY_DEST}"
chmod 600 "${_KBL_UNIT_DEST}" "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"
cp -a "${_KBL_SCRIPT_DEST}" "${TEST_ROOT}/foreign-script"
cp -a "${_KBL_RULE_DEST}" "${TEST_ROOT}/foreign-rule"
cp -a "${_KBL_LEGACY_RULE}" "${TEST_ROOT}/foreign-legacy-rule"
cp -a "${_KBL_ACTIVITY_DEST}" "${TEST_ROOT}/foreign-activity"
cp -a "${_KBL_UNIT_DEST}" "${TEST_ROOT}/foreign-unit"
cp -a "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf" "${TEST_ROOT}/foreign-config"
tweak_pre_install >/dev/null
tweak_post_install >/dev/null
tweak_pre_uninstall >/dev/null
assert_same "${TEST_ROOT}/foreign-script" "${_KBL_SCRIPT_DEST}"
assert_same "${TEST_ROOT}/foreign-rule" "${_KBL_RULE_DEST}"
assert_same "${TEST_ROOT}/foreign-legacy-rule" "${_KBL_LEGACY_RULE}"
assert_same "${TEST_ROOT}/foreign-activity" "${_KBL_ACTIVITY_DEST}"
assert_same "${TEST_ROOT}/foreign-unit" "${_KBL_UNIT_DEST}"
assert_same "${TEST_ROOT}/foreign-config" "${TARGET_HOME}/.config/zenbook-tweaks/kbd-backlight.conf"
[[ "$(stat -c %a "${_KBL_SCRIPT_DEST}")" == 700 ]]
[[ "$(stat -c %a "${_KBL_RULE_DEST}")" == 600 ]]
[[ "$(stat -c %a "${_KBL_LEGACY_RULE}")" == 640 ]]

# An originally absent launcher/shortcut stays absent after a full cycle.
reset_initial_state
rm -f -- "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop" \
	"${SHORTCUT_VALUE_FILE}" "${SHORTCUT_KEYS_FILE}"
printf '0\n' > "${SHORTCUT_RUNTIME_FILE}"
printf '0\n' > "${INPUT_MEMBER_FILE}"
tweak_pre_install >/dev/null
tweak_post_install >/dev/null
tweak_pre_uninstall >/dev/null
assert_absent "${TARGET_HOME}/.local/share/applications/net.local.kbd-backlight.desktop"
assert_absent "${SHORTCUT_VALUE_FILE}"
grep -qxF 0 "${INPUT_MEMBER_FILE}"

# Offline rollback updates only the target KConfig key and does not require D-Bus.
(
	export STATE_DIR="${TEST_ROOT}/offline-state"
	export BACKUP_DIR="${TEST_ROOT}/offline-backups"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tweaks/kbd-backlight/tweak.conf"
	_KBL_MANIFEST="${TEST_ROOT}/offline-manifest"
	printf 'shortcut_present=1\nshortcut_value_b64=RjQ=\nshortcut_runtime_present=1\nshortcut_keys_b64=WyhbMTY3NzcyNjcsMCwwLDBdLCld\n' > "${_KBL_MANIFEST}"
	_kbl_session_active() { return 1; }
	_kbl_as_user() { printf '%s\n' "$*" >> "${TEST_ROOT}/offline-calls"; }
	_kbl_shortcut_value() { echo F4; }
	_kbl_restore_shortcut
	grep -q 'kwriteconfig6 --file kglobalshortcutsrc --group services --group net.local.kbd-backlight.desktop --key _launch F4' \
		"${TEST_ROOT}/offline-calls"
)

# The targeted KGlobalAccel calls use the existing component/action only.
(
	export STATE_DIR="${TEST_ROOT}/dbus-state"
	export BACKUP_DIR="${TEST_ROOT}/dbus-backups"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tweaks/kbd-backlight/tweak.conf"
	_kbl_as_user() { printf '%s\n' "$*" >> "${TEST_ROOT}/dbus-calls"; }
	_kbl_shortcut_value() { echo F4; }
	_kbl_shortcut_keys() { echo '[([16777267,0,0,0],)]'; }
	_kbl_set_shortcut_f4
	grep -q 'org.kde.KGlobalAccel.doRegister' "${TEST_ROOT}/dbus-calls"
	grep -q 'org.kde.KGlobalAccel.setForeignShortcutKeys' "${TEST_ROOT}/dbus-calls"
	grep -q 'net.local.kbd-backlight.desktop' "${TEST_ROOT}/dbus-calls"
	grep -q '16777267' "${TEST_ROOT}/dbus-calls"
)

# Empty or self-owned F4 mappings are accepted; an unrelated owner is refused.
(
	export STATE_DIR="${TEST_ROOT}/conflict-state"
	export BACKUP_DIR="${TEST_ROOT}/conflict-backups"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tweaks/kbd-backlight/tweak.conf"
	KGLOBAL_OUTPUT='(@a(ssssssaiai) [],)'
	_kbl_as_user() { printf '%s\n' "${KGLOBAL_OUTPUT}"; }
	_kbl_f4_available
	KGLOBAL_OUTPUT="([('_launch', 'ASUS Keyboard Backlight Toggle', 'net.local.kbd-backlight.desktop', 'ASUS Keyboard Backlight Toggle', 'default', 'Default Context', [16777267], [0])],)"
	_kbl_f4_available
	KGLOBAL_OUTPUT="([('_launch', 'Unrelated', 'org.example.unrelated.desktop', 'Unrelated', 'default', 'Default Context', [16777267], [0])],)"
	if _kbl_f4_available; then
		echo "FAIL: unrelated KGlobalAccel owner was accepted" >&2
		exit 1
	fi
)

echo "kbd-backlight lifecycle tests passed"
