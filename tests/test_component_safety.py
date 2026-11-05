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

    def run_shell(self, code, success=True):
        r = subprocess.run(['bash', '-c', self.source + code], text=True, capture_output=True,
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
