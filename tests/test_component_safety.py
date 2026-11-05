"""Runtime/configuration rollback checks in temporary directories."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SSHD = shutil.which('sshd') or '/usr/sbin/sshd'


class IPv6Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ipv6-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.proc = self.root / 'ipv6'
        self.values = {}
        for iface, value in (('all', '0'), ('default', '1'), ('eth0', '0'), ('lo', '0')):
            p = self.proc / 'conf' / iface / 'disable_ipv6'
            p.parent.mkdir(parents=True)
            p.write_text(value + '\n')
            self.values[p] = value
        self.config = self.root / '99-ipv6-manager.conf'
        self.config.write_text('# original\n')
        self.other = self.root / 'other.conf'
        self.other.write_text('net.ipv4.ip_forward=1\n')
        self.source = (ROOT / 'ipv6-manager.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        self.source = self.source.replace('/proc/sys/net/ipv6', str(self.proc))
        self.source += '\nSYSCTL_FILE=' + shlex.quote(str(self.config))
        self.source += '\nBACKUP_DIR=' + shlex.quote(str(self.root / 'backup')) + '\n'

    def run_shell(self, code, success=True, stdin=''):
        r = subprocess.run(['bash', '-c', self.source + code], text=True, capture_output=True,
                           input=stdin,
                           env={**os.environ, 'SSH_CONNECTION': ''})
        if success:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def test_disable_and_enable_only_touch_managed_settings(self):
        self.run_shell('change_ipv6 1')
        for path in self.values:
            self.assertEqual(path.read_text().strip(), '1')
        self.assertIn('disable_ipv6=1', self.config.read_text())
        self.run_shell('change_ipv6 0')
        self.assertFalse(self.config.exists())
        self.assertEqual(self.other.read_text(), 'net.ipv4.ip_forward=1\n')
        for path in self.values:
            self.assertEqual(path.read_text().strip(), '0')

    def test_partial_runtime_failure_restores_every_previous_value(self):
        self.run_shell('''
writes=0
printf() {
  if [[ "$1" == '%s\\n' && "${2:-}" == 1 ]]; then
    writes=$((writes + 1))
    if [[ "$writes" == 2 ]]; then return 1; fi
  fi
  builtin printf "$@"
}
change_ipv6 1
''', success=False)
        self.assertEqual(self.config.read_text(), '# original\n')
        for path, value in self.values.items():
            self.assertEqual(path.read_text().strip(), value)

    def test_persistence_failure_rolls_back_runtime(self):
        self.run_shell('mv() { return 1; }; change_ipv6 1', success=False)
        self.assertEqual(self.config.read_text(), '# original\n')
        for path, value in self.values.items():
            self.assertEqual(path.read_text().strip(), value)
        self.assertEqual(list(self.root.glob('99-ipv6-manager.conf.*')), [])

    def test_ipv6_ssh_session_cannot_be_disabled(self):
        self.run_shell("SSH_CONNECTION='2001:db8::1 1234 2001:db8::2 22'; change_ipv6 1", success=False)
        self.assertEqual(self.config.read_text(), '# original\n')
        for path, value in self.values.items():
            self.assertEqual(path.read_text().strip(), value)

    def test_runtime_state_uses_interfaces_instead_of_all_or_default(self):
        # default=1 affects future interfaces, not the currently enabled ones.
        self.assertEqual(self.run_shell('ipv6_runtime_state').stdout.strip(), 'enabled')
        (self.proc / 'conf/all/disable_ipv6').write_text('1\n')
        self.assertEqual(self.run_shell('ipv6_runtime_state').stdout.strip(), 'enabled')
        (self.proc / 'conf/eth0/disable_ipv6').write_text('1\n')
        self.assertEqual(self.run_shell('ipv6_runtime_state').stdout.strip(), 'mixed')
        (self.proc / 'conf/lo/disable_ipv6').write_text('1\n')
        self.assertEqual(self.run_shell('ipv6_runtime_state').stdout.strip(), 'disabled')

    def test_mixed_status_lists_actual_interface_settings(self):
        (self.proc / 'conf/eth0/disable_ipv6').write_text('1\n')
        r = self.run_shell('show_status')
        self.assertIn('混合', r.stdout)
        self.assertIn('eth0.disable_ipv6 = 1', r.stdout)
        self.assertIn('lo.disable_ipv6 = 0', r.stdout)

    def test_interactive_menu_allows_both_directions_from_mixed_state(self):
        for selection, expected in (('2\nyes\n', '0'), ('1\nyes\n', '1')):
            with self.subTest(selection=selection):
                (self.proc / 'conf/eth0/disable_ipv6').write_text('1\n')
                (self.proc / 'conf/lo/disable_ipv6').write_text('0\n')
                self.run_shell('show_status() { :; }; check_other_ipv6_configs() { :; }; '
                               'interactive_menu', stdin=selection)
                for p in self.values:
                    self.assertEqual(p.read_text().strip(), expected)

    def test_interactive_cancel_does_not_change_configuration(self):
        for selection in ('0\n', '\n', '1\nno\n', ''):
            with self.subTest(selection=selection):
                self.run_shell('show_status() { :; }; check_other_ipv6_configs() { :; }; '
                               'interactive_menu', stdin=selection)
                self.assertEqual(self.config.read_text(), '# original\n')
                for p, expected in self.values.items():
                    self.assertEqual(p.read_text().strip(), expected)


@unittest.skipUnless(Path(SSHD).is_file() and shutil.which('ssh-keygen'), 'OpenSSH required')
class AuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix='audit-key-')
        cls.keyfile = Path(cls.keys.name) / 'host'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(cls.keyfile)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='audit-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.dropins = self.root / 'sshd_config.d'
        self.dropins.mkdir()
        self.target = self.dropins / '00-key-only-auth.conf'
        self.target.write_text('PubkeyAuthentication yes\n')
        config = self.root / 'sshd_config'
        config.write_text(f'HostKey {self.keyfile}\nInclude {self.dropins}/*.conf\n')
        wrapper = self.root / 'sshd'
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(SSHD) + ' -f ' + shlex.quote(str(config)) + ' "$@"\n')
        wrapper.chmod(0o755)
        self.source = (ROOT / 'server-security-audit.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        self.source = self.source.replace('/etc/ssh/sshd_config.d', str(self.dropins))
        self.source += '\nSSHD_BIN=' + shlex.quote(str(wrapper)) + '\nLOGIN_USERS=(root maozaizi)\n'
        self.source += '''
systemctl() {
  case "$1" in
    cat) [[ "$2" == ssh.service ]] ;;
    is-active) return 0 ;;
    reload|restart) [[ "${FAIL_SERVICE:-0}" == 0 ]] ;;
    *) return 1 ;;
  esac
}
'''

    def run_shell(self, code, success=True):
        r = subprocess.run(['bash', '-c', self.source + code], capture_output=True, text=True)
        if success:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def test_key_only_policy_is_verified_and_repeatable(self):
        self.run_shell('enforce_key_only_ssh; enforce_key_only_ssh; [[ -z "$(key_only_failures)" ]]')
        self.assertIn('AuthenticationMethods publickey', self.target.read_text())
        self.assertEqual(list(self.dropins.glob('.key-only.*')), [])

    def test_existing_root_login_policy_is_preserved(self):
        for policy in ('no', 'forced-commands-only', 'prohibit-password', 'yes'):
            with self.subTest(policy=policy):
                (self.dropins / '50-root-policy.conf').write_text('PermitRootLogin ' + policy + '\n')
                self.run_shell('''
before="$(effective_sshd_config root 127.0.0.1)"
before_root="$(sshd_value "$before" permitrootlogin)"
enforce_key_only_ssh
after="$(effective_sshd_config root 127.0.0.1)"
[[ "$(sshd_value "$after" permitrootlogin)" == "$before_root" ]]
config_is_key_only "$after" root
''')
                self.assertNotIn('PermitRootLogin', self.target.read_text())

    def test_source_specific_root_deny_is_preserved(self):
        (self.dropins / '50-root-policy.conf').write_text(
            'Match User root Address 198.51.100.0/24\n PermitRootLogin no\n')
        self.run_shell('''
enforce_key_only_ssh
after="$(effective_sshd_config root 198.51.100.5)"
[[ "$(sshd_value "$after" permitrootlogin)" == no ]]
config_is_key_only "$after" root
''')

    def test_old_managed_root_policy_survives_migration_and_repeat(self):
        for policy in ('no', 'forced-commands-only', 'prohibit-password'):
            with self.subTest(policy=policy):
                self.target.write_text('PermitRootLogin ' + policy + '\n'
                                       'Match User root\n PermitRootLogin ' + policy + '\n')
                self.run_shell('''
before="$(effective_sshd_config root 127.0.0.1)"
before_root="$(sshd_value "$before" permitrootlogin)"
enforce_key_only_ssh
enforce_key_only_ssh
after="$(effective_sshd_config root 127.0.0.1)"
[[ "$(sshd_value "$after" permitrootlogin)" == "$before_root" ]]
config_is_key_only "$after" root
''')

    def test_old_managed_source_specific_root_policy_survives_migration(self):
        self.target.write_text('Match User root Address 198.51.100.0/24\n'
                               ' PermitRootLogin no\n'
                               'Match User root Address 2001:db8:1::/48\n'
                               ' PermitRootLogin forced-commands-only\n')
        self.run_shell('''
enforce_key_only_ssh
for item in '198.51.100.5 no' '2001:db8:1::5 forced-commands-only'; do
  read -r addr expected <<< "$item"
  config="$(effective_sshd_config root "$addr")"
  [[ "$(sshd_value "$config" permitrootlogin)" == "$expected" ]]
  config_is_key_only "$config" root
done
config="$(effective_sshd_config root 127.0.0.1)"
[[ "$(sshd_value "$config" permitrootlogin)" != no ]]
''')

    def test_denied_root_key_alone_cannot_pass_lockout_guard(self):
        (self.dropins / '50-root-policy.conf').write_text('PermitRootLogin no\n')
        r = self.run_shell('LOGIN_USERS=(root); user_key_status() { echo yes; }; '
                           'audit_key_readiness; guard_lockout', success=False)
        self.assertIn('不计入就绪账户', r.stdout)
        self.assertIn('拒绝执行', r.stderr)

    def test_ready_normal_user_is_kept_when_root_is_denied(self):
        (self.dropins / '50-root-policy.conf').write_text('PermitRootLogin no\n')
        self.run_shell('user_key_status() { echo yes; }; audit_key_readiness; '
                       '[[ "${READY_USERS[*]}" == maozaizi ]]; guard_lockout')

    def test_conflicting_policy_restores_file(self):
        self.run_shell('key_only_failures() { echo conflict; }; enforce_key_only_ssh', success=False)
        self.assertEqual(self.target.read_text(), 'PubkeyAuthentication yes\n')

    def test_later_source_exceptions_cannot_restore_password_login(self):
        (self.dropins / '50-source-exception.conf').write_text(
            'Match Address 198.51.100.0/24,2001:db8:1::/48\n'
            ' PasswordAuthentication yes\n KbdInteractiveAuthentication yes\n'
            ' AuthenticationMethods any\n')
        r = self.run_shell('''
SSH_CONNECTION='198.51.100.23 1234 203.0.113.9 22'
enforce_key_only_ssh
for addr in 198.51.100.23 2001:db8:1::23; do
  config="$(effective_sshd_config maozaizi "$addr")"
  config_is_key_only "$config" maozaizi || exit 1
done
''')
        self.assertIn('publickey-only', r.stdout)

    def test_verifier_includes_current_ssh_source(self):
        r = self.run_shell('''
LOGIN_USERS=(maozaizi)
SSH_CONNECTION='198.51.100.23 1234 203.0.113.9 22'
effective_sshd_config() {
  if [[ "$2" == 198.51.100.23 ]]; then
    printf 'passwordauthentication yes\nkbdinteractiveauthentication yes\npubkeyauthentication yes\nauthenticationmethods any\n'
  else
    printf 'passwordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nauthenticationmethods publickey\n'
  fi
}
key_only_failures
''')
        self.assertEqual(r.stdout.strip(), 'maozaizi@198.51.100.23')

    def test_ssh_source_can_be_recovered_after_sudo_filters_environment(self):
        proc = self.root / 'proc'
        parent = proc / str(os.getpid())
        parent.mkdir(parents=True)
        parent.joinpath('environ').write_bytes(b'SSH_CONNECTION=198.51.100.23 1234 203.0.113.9 22\0')
        parent.joinpath('status').write_text('PPid:\t1\n')
        self.source = self.source.replace('/proc/$pid', str(proc) + '/$pid')
        r = self.run_shell('SSH_CONNECTION=""; ssh_context')
        self.assertEqual(r.stdout, '198.51.100.23 1234 203.0.113.9 22')

    def test_failed_service_restores_file(self):
        self.run_shell('FAIL_SERVICE=1; enforce_key_only_ssh', success=False)
        self.assertEqual(self.target.read_text(), 'PubkeyAuthentication yes\n')

    def test_unknown_key_source_is_not_a_ready_account(self):
        self.run_shell('''
LOGIN_USERS=(maozaizi)
user_key_status() { echo unknown; }
effective_sshd_config() { echo 'allowusers maozaizi'; }
audit_key_readiness
[[ "${#READY_USERS[@]}" == 0 ]]
''')

    def test_invalid_public_key_is_not_accepted(self):
        invalid = self.root / 'invalid.pub'
        invalid.write_text('ssh-ed25519 NOT_A_REAL_KEY\n')
        self.run_shell('if has_public_key_line ' + shlex.quote(str(invalid)) + '; then exit 1; fi')


if __name__ == '__main__':
    unittest.main(verbosity=2)
