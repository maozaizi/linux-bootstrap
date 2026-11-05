"""Time-service decisions without installing packages or changing the host clock."""
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TimeSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='time-sync-test-')
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.calls = self.folder / 'calls'
        self.enabled = self.folder / 'enabled'
        self.source = (ROOT / 'bootstrap-debian.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        self.base = f'''
CALLS={shlex.quote(str(self.calls))}
ENABLED={shlex.quote(str(self.enabled))}
require_root() {{ :; }}
check_supported_os() {{ :; }}
apt() {{
  echo "apt $*" >> "$CALLS"
  [[ "${{FAIL_APT:-0}}" == 0 ]]
}}
systemctl() {{
  case "$1" in
    is-active)
      [[ "$3" == "${{ACTIVE_PROVIDER:-none}}" ]] ||
        {{ [[ -f "$ENABLED" && "$3" == systemd-timesyncd.service ]]; }} ;;
    enable)
      echo "systemctl $*" >> "$CALLS"
      [[ "${{FAIL_START:-0}}" == 0 ]] || return 1
      if [[ "$2" == --now ]]; then touch "$ENABLED"; fi ;;
    daemon-reload) echo "systemctl $*" >> "$CALLS" ;;
    *) return 1 ;;
  esac
}}
timedatectl() {{
  case "$*" in
    'show -p CanNTP --value') echo "${{AVAILABLE:-no}}" ;;
    'set-ntp true')
      echo 'timedatectl set-ntp true' >> "$CALLS"
      [[ "${{FAIL_START:-0}}" == 0 ]] || return 1
      touch "$ENABLED" ;;
    'show -p NTP --value') [[ -f "$ENABLED" ]] && echo yes || echo no ;;
    'show -p NTPSynchronized --value') echo "${{SYNCED:-yes}}" ;;
    *) return 1 ;;
  esac
}}
'''

    def run_shell(self, code, success=True):
        r = subprocess.run(['bash', '-c', self.source + self.base + code],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, success, r.stdout + r.stderr)
        return r

    def test_active_chrony_is_preserved_without_installation(self):
        self.run_shell('ACTIVE_PROVIDER=chrony.service; step_time_sync')
        self.assertEqual(self.calls.read_text(), 'systemctl enable chrony.service\n')

    def test_existing_available_provider_is_enabled(self):
        self.run_shell('AVAILABLE=yes; step_time_sync')
        self.assertEqual(self.calls.read_text(), 'timedatectl set-ntp true\n')

    def test_missing_provider_is_installed_and_repeat_does_not_reinstall(self):
        self.run_shell('step_time_sync; step_time_sync')
        calls = self.calls.read_text()
        self.assertEqual(calls.count('apt install'), 1)
        self.assertIn('apt install --no-remove -y systemd-timesyncd\n', calls)
        self.assertIn('systemctl daemon-reload\n', calls)
        self.assertIn('systemctl enable --now systemd-timesyncd.service\n', calls)
        self.assertIn('systemctl enable systemd-timesyncd.service\n', calls)
        self.assertNotIn('timedatectl set-ntp', calls)

    def test_install_failure_prevents_enable(self):
        self.run_shell('FAIL_APT=1; step_time_sync', success=False)
        self.assertNotIn('set-ntp', self.calls.read_text())
        self.assertFalse(self.enabled.exists())

    def test_enable_failure_is_not_reported_as_success(self):
        r = self.run_shell('AVAILABLE=yes; FAIL_START=1; step_time_sync', success=False)
        self.assertNotIn('自动校时已启用', r.stdout)
        self.assertIn('启用自动校时失败', r.stderr)

    def test_new_service_start_failure_is_not_reported_as_success(self):
        r = self.run_shell('FAIL_START=1; step_time_sync', success=False)
        self.assertNotIn('自动校时已启用', r.stdout)
        self.assertIn('启用 systemd-timesyncd 失败', r.stderr)

    def test_pending_sync_is_reported_without_waiting(self):
        r = self.run_shell('AVAILABLE=yes; SYNCED=no; step_time_sync')
        self.assertIn('[待办]', r.stdout)
        self.assertNotIn('系统时间已同步', r.stdout)

    def test_unknown_provider_state_stops_before_installing(self):
        self.run_shell('AVAILABLE=unknown; step_time_sync', success=False)
        self.assertFalse(self.calls.exists())

    def test_time_sync_only_needs_no_key_or_package_manifest(self):
        r = self.run_shell('BOOTSTRAP_PUBKEY=""; SOFT_LIST_FILE=/nonexistent; '
                           'AVAILABLE=yes; main --time-sync-only')
        self.assertIn('系统时间已同步', r.stdout)
        self.assertEqual(self.calls.read_text(), 'timedatectl set-ntp true\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
