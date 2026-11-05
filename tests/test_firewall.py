"""UFW state transitions are simulated; host firewall commands are never called."""
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FirewallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ufw-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'ufw'
        self.config.mkdir()
        (self.config / 'user.rules').write_text('original rules\n')
        (self.config / 'ufw.conf').write_text('ENABLED=yes\n')
        self.defaults = self.root / 'default-ufw'
        self.defaults.write_text('original defaults\n')
        self.state = self.root / 'runtime-state'
        self.state.write_text('active')
        self.calls = self.root / 'calls'
        self.backups = self.root / 'backups'
        self.source = (ROOT / 'ufw-manager.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        for before, after in (('/etc/default/ufw', self.defaults),
                              ('/etc/ufw', self.config),
                              ('/var/backups/ufw-manager', self.backups)):
            self.source = self.source.replace(before, str(after))
        self.base = f'''
OPT_YES=1
TEST_STATE={shlex.quote(str(self.state))}
TEST_CALLS={shlex.quote(str(self.calls))}
detect_ssh_ports() {{ SSH_PORTS=(22); SSH_PORT_SOURCES=test; }}
ufw() {{
  printf '%s\\n' "$*" >> "$TEST_CALLS"
  case "$*" in
    status|'status numbered') printf 'Status: %s\\n' "$(cat "$TEST_STATE")" ;;
    '--force reset')
      printf inactive > "$TEST_STATE"
      printf 'reset rules\\n' > "$UFW_CONFIG_DIR/user.rules"
      printf 'reset defaults\\n' > "$UFW_DEFAULTS_FILE"
      if [[ "${{FAIL_AT:-}}" == reset ]]; then return 1; fi ;;
    'default deny incoming')
      if [[ "${{FAIL_AT:-}}" == default ]]; then return 1; fi
      printf 'deny incoming\\n' > "$UFW_DEFAULTS_FILE" ;;
    'default allow outgoing') return 0 ;;
    'allow 22/tcp'|'allow 443/tcp')
      if [[ "${{FAIL_AT:-}}" == allow ]]; then echo 'ERROR: rule failure'; return 1; fi
      printf '%s\\n' "$*" >> "$UFW_CONFIG_DIR/user.rules" ;;
    '--force enable')
      if [[ "${{FAIL_AT:-}}" == enable && ! -f "$TEST_STATE.failed" ]]; then
        touch "$TEST_STATE.failed"; return 1
      fi
      if [[ "${{FAIL_RESTORE:-0}}" == 1 ]]; then return 1; fi
      printf active > "$TEST_STATE" ;;
    reload) return 0 ;;
    '--force disable') printf inactive > "$TEST_STATE" ;;
    *) echo "Unexpected ufw command: $*" >&2; return 1 ;;
  esac
}}
'''

    def run_shell(self, code, success=True):
        r = subprocess.run(['bash', '-c', self.source + self.base + code],
                           capture_output=True, text=True)
        if success:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def assert_original_restored(self, state='active'):
        self.assertEqual((self.config / 'user.rules').read_text(), 'original rules\n')
        self.assertEqual(self.defaults.read_text(), 'original defaults\n')
        self.assertEqual(self.state.read_text(), state)
        snapshots = list(self.backups.glob('backup.*'))
        self.assertEqual(len(snapshots), 1)
        self.assertEqual((snapshots[0] / 'config/user.rules').read_text(), 'original rules\n')

    def test_reset_default_rule_and_enable_failures_restore_active_state(self):
        for stage in ('reset', 'default', 'allow', 'enable'):
            with self.subTest(stage=stage):
                # Each failure uses an independent snapshot and runtime state.
                for old in self.backups.glob('backup.*'):
                    shutil.rmtree(old)
                self.run_shell('FAIL_AT=' + stage + '; init_ufw', success=False)
                self.assert_original_restored()

    def test_failure_restores_previously_inactive_state(self):
        self.state.write_text('inactive')
        (self.config / 'ufw.conf').write_text('ENABLED=no\n')
        self.run_shell('FAIL_AT=allow; init_ufw', success=False)
        self.assert_original_restored('inactive')
        self.assertEqual((self.config / 'ufw.conf').read_text(), 'ENABLED=no\n')

    def test_success_keeps_backup_and_enables_new_rules(self):
        self.run_shell('init_ufw')
        self.assertEqual(self.state.read_text(), 'active')
        rules = (self.config / 'user.rules').read_text()
        self.assertIn('allow 22/tcp', rules)
        self.assertIn('allow 443/tcp', rules)
        snapshot = next(self.backups.glob('backup.*'))
        self.assertEqual((snapshot / 'config/user.rules').read_text(), 'original rules\n')

    def test_restore_failure_is_reported_and_backup_is_kept(self):
        r = self.run_shell('FAIL_AT=allow; FAIL_RESTORE=1; init_ufw', success=False)
        self.assertIn('自动恢复未全部完成', r.stderr)
        self.assertEqual(len(list(self.backups.glob('backup.*'))), 1)
        self.assertEqual((self.config / 'user.rules').read_text(), 'original rules\n')

    def test_symlinked_rules_are_rejected_before_reset(self):
        external = self.root / 'external.rules'
        external.write_text('external rules\n')
        rules = self.config / 'user.rules'
        rules.unlink()
        rules.symlink_to(external)
        self.run_shell('init_ufw', success=False)
        self.assertEqual(external.read_text(), 'external rules\n')
        self.assertEqual(self.state.read_text(), 'active')
        self.assertFalse(self.calls.exists())

    def test_deletion_failure_propagates(self):
        r = self.run_shell('ufw_delete() { return 1; }; remove_exact_public_rules 2222 tcp', success=False)
        self.assertIn('收紧未完成', r.stderr)

    def test_missing_rule_is_not_a_deletion_failure(self):
        self.run_shell('ufw_delete() { return 2; }; remove_exact_public_rules 2222 tcp')

    def test_remaining_public_coverage_cannot_report_restrict_success(self):
        # The comment reader shim allows this flow test on macOS Bash 3 as well.
        r = self.run_shell('''
mapfile() { extra=(''); }
guard_restrict_ssh() { :; }
ufw_run() { :; }
ufw_delete() { return 2; }
matching_allow_rules() { echo 'allow|any|allow 1000:9000/tcp'; }
show_rules() { echo UNEXPECTED_SUCCESS; }
restrict_rule_to_source 198.51.100.1 2222 tcp
''', success=False)
        self.assertNotIn('UNEXPECTED_SUCCESS', r.stdout)
        self.assertIn('收紧未完成', r.stderr)

    def test_inventory_failure_never_reports_clean_rules(self):
        for check in ('check_public_allow_for_port 2222 tcp',
                      'report_port_coverage SSH 22 tcp', 'check_high_risk_rules'):
            with self.subTest(check=check):
                r = self.run_shell('ufw() { return 1; }; ' + check, success=False)
                self.assertIn('无法读取防火墙规则', r.stderr)
                self.assertNotIn('未检测到', r.stdout)

    def test_application_lookup_failure_is_not_empty_coverage(self):
        r = self.run_shell('''
ufw() {
  if [[ "$*" == 'show added' ]]; then echo 'ufw allow OpenSSH'; else return 1; fi
}
check_public_allow_for_port 22 tcp
''', success=False)
        self.assertIn('无法读取防火墙规则', r.stderr)

    def test_empty_inventory_is_valid(self):
        r = self.run_shell('ufw() { return 0; }; check_public_allow_for_port 2222 tcp')
        self.assertIn('未检测到', r.stdout)

    def test_restrict_stops_when_inventory_cannot_be_read(self):
        r = self.run_shell('''
mapfile() { extra=(''); }
guard_restrict_ssh() { :; }
ufw_run() { :; }
ufw_delete() { return 2; }
ufw() { return 1; }
show_rules() { echo UNEXPECTED_SUCCESS; }
restrict_rule_to_source 198.51.100.1 2222 tcp
''', success=False)
        self.assertIn('无法读取防火墙规则', r.stderr)
        self.assertNotIn('公网放行已移除', r.stdout)
        self.assertNotIn('UNEXPECTED_SUCCESS', r.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
