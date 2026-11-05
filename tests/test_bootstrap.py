"""Isolated bootstrap regression checks; never change host configuration."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bootstrap-debian.sh'
SSHD = shutil.which('sshd') or '/usr/sbin/sshd'


@unittest.skipUnless(Path(SSHD).is_file() and shutil.which('ssh-keygen'), 'OpenSSH required')
class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix='bootstrap-keys-')
        cls.keydir = Path(cls.keys.name)
        for kind in ('ed25519', 'ecdsa', 'rsa'):
            subprocess.run(['ssh-keygen', '-q', '-t', kind, '-N', '', '-f',
                            str(cls.keydir / kind)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bootstrap-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.dropins = self.root / 'sshd_config.d'
        self.dropins.mkdir()
        self.state = self.root / 'state'
        self.state.mkdir()
        self.socket = self.root / 'socket/99-bootstrap-port.conf'
        self.socket.parent.mkdir()
        self.config = self.root / 'sshd_config'
        self.config.write_text(f'HostKey {self.keydir}/ed25519\nInclude {self.dropins}/*.conf\n')
        self.wrapper = self.root / 'sshd'
        self.wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(SSHD) + ' -f ' +
                                shlex.quote(str(self.config)) + ' "$@"\n')
        self.wrapper.chmod(0o755)
        self.source = SCRIPT.read_text().rsplit('\nmain "$@"', 1)[0]
        self.source = self.source.replace('/etc/ssh/sshd_config.d', str(self.dropins))
        self.source = self.source.replace('/run/sshd', str(self.root / 'run-sshd'))
        self.base = f'''
STATE_DIR={shlex.quote(str(self.state))}
DONE_FILE="$STATE_DIR/done"
SOFT_LIST_FILE={shlex.quote(str(SCRIPT.parent / 'soft-list'))}
SSH_SOCKET_DROPIN_FILE={shlex.quote(str(self.socket))}
SSH_SOCKET_DROPIN_DIR={shlex.quote(str(self.socket.parent))}
get_sshd_bin() {{ printf '%s' {shlex.quote(str(self.wrapper))}; }}
id() {{ if [[ "$1" == -nG ]]; then echo sudo; else echo 1000; fi; }}
systemctl() {{
  printf '%s\\n' "$*" >> {shlex.quote(str(self.root / 'systemctl.log'))}
  case "$1" in
    cat) [[ "$2" == ssh.service || "${{SOCKET_ENABLED:-0}}" == 1 ]] ;;
    is-enabled|is-active) [[ "${{SOCKET_ENABLED:-0}}" == 1 ]] ;;
    reload) [[ "${{FAIL_RELOAD:-0}}" == 0 ]] ;;
    restart)
      if [[ "$2" == ssh.socket ]]; then
        [[ "${{FAIL_SOCKET:-0}}" == 0 ]]
      else
        [[ "${{FAIL_RESTART:-0}}" == 0 ]]
      fi ;;
    daemon-reload) return 0 ;;
    *) return 1 ;;
  esac
}}
'''

    def run_shell(self, code, success=True):
        result = subprocess.run(['bash', '-c', self.source + '\n' + self.base + '\n' + code],
                                text=True, capture_output=True,
                                env={**os.environ, 'SSH_CONNECTION': ''})
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def key(self, kind='ed25519'):
        return (self.keydir / (kind + '.pub')).read_text().strip()

    def test_valid_public_key_types(self):
        for kind in ('ed25519', 'ecdsa', 'rsa'):
            with self.subTest(kind=kind):
                self.run_shell('BOOTSTRAP_PUBKEY=' + shlex.quote(self.key(kind)) +
                               '; [[ "$(get_pubkey)" == "$BOOTSTRAP_PUBKEY" ]]')

    def test_invalid_and_multiple_keys_rejected(self):
        for key in ('ssh-ed25519 NOT_A_REAL_KEY', self.key() + '\n' + self.key('ecdsa'),
                    (self.keydir / 'ed25519').read_text()):
            self.run_shell('BOOTSTRAP_PUBKEY=' + shlex.quote(key) + '; get_pubkey', success=False)

    def test_preflight_caches_key_and_rejects_invalid_port(self):
        self.run_shell('check_supported_os() { :; }; BOOTSTRAP_PUBKEY=' +
                       shlex.quote(self.key()) + '; preflight_check; '
                       '[[ "$VALIDATED_PUBKEY" == "$BOOTSTRAP_PUBKEY" ]]')
        self.run_shell('check_supported_os() { :; }; BOOTSTRAP_PUBKEY=' +
                       shlex.quote(self.key()) + '; SSH_PORT=65536; preflight_check', success=False)
        self.assertEqual(list(self.state.iterdir()), [])

    def test_check_mode_validates_without_installing_or_marking(self):
        self.run_shell('require_root() { :; }; check_supported_os() { :; }; '
                       'apt() { echo "unexpected apt" >&2; return 1; }; '
                       'BOOTSTRAP_PUBKEY=' + shlex.quote(self.key()) + '; main --check')
        self.assertEqual(list(self.state.iterdir()), [])

    def test_authorized_keys_without_newline_and_repeat(self):
        home = self.root / 'home'
        auth = home / '.ssh/authorized_keys'
        auth.parent.mkdir(parents=True)
        auth.write_text(self.key('ecdsa'))
        self.run_shell(f'''
VALIDATED_PUBKEY={shlex.quote(self.key())}
getent() {{ printf 'maozaizi:x:1000:1000::{home}:/bin/bash\\n'; }}
ensure_sudo_installed() {{ :; }}; ensure_sudo_group() {{ :; }}
chown() {{ :; }}
install() {{ mkdir -p "${{@: -1}}"; }}
step_create_user
step_create_user
''')
        self.assertEqual(auth.read_text().splitlines(), [self.key('ecdsa'), self.key()])

    def test_reload_failure_is_propagated(self):
        self.run_shell('FAIL_RELOAD=1; FAIL_RESTART=1; '
                       'reload_ssh_service || die "reload failed"', success=False)
        self.run_shell('FAIL_RELOAD=1; reload_ssh_service')

    def test_existing_user_with_different_primary_group(self):
        home = self.root / 'existing-user'
        home.mkdir()
        ownership = self.root / 'ownership.log'
        self.run_shell(f'''
BOOTSTRAP_USER=ops
VALIDATED_PUBKEY={shlex.quote(self.key())}
id() {{ case "$1" in -gn) echo users ;; -nG) echo sudo ;; *) echo 1000 ;; esac; }}
getent() {{ printf 'ops:x:1000:100::{home}:/bin/bash\\n'; }}
ensure_sudo_installed() {{ :; }}; ensure_sudo_group() {{ :; }}
useradd() {{ echo UNEXPECTED_USERADD >&2; return 1; }}
install() {{
  [[ "$*" == *'-g users '* ]] || return 1
  mkdir -p "${{@: -1}}"
}}
chown() {{
  [[ "$1" == ops:users ]] || return 1
  printf '%s\\n' "$*" >> {shlex.quote(str(ownership))}
}}
step_create_user
step_shell_alias
''')
        self.assertEqual((home / '.ssh/authorized_keys').read_text().strip(), self.key())
        self.assertEqual(len(ownership.read_text().splitlines()), 4)
        for name in ('.shell_aliases', '.bashrc', '.zshrc'):
            self.assertTrue((home / name).is_file())

    def test_cloud_config_precedence_and_legacy_migration(self):
        (self.dropins / '50-cloud-init.conf').write_text('PasswordAuthentication yes\n')
        legacy = self.dropins / '99-bootstrap.conf'
        legacy.write_text('PubkeyAuthentication yes\n')
        self.run_shell('step_harden_ssh')
        self.assertTrue((self.dropins / '10-bootstrap.conf').is_file())
        self.assertFalse(legacy.exists())
        self.assertTrue((self.state / 'harden_ssh.done').is_file())
        self.assertEqual(list(self.dropins.glob('.bootstrap.*')), [])

    def test_all_root_policies(self):
        for options in ('DISABLE_ROOT_SSH=1', 'DISABLE_ROOT_SSH_PASSWORD=1',
                        'DISABLE_SSH_PASSWORD=0'):
            with self.subTest(options=options):
                self.run_shell(options + '; step_harden_ssh')

    def test_policy_conflict_restores_legacy_without_reload(self):
        (self.dropins / '00-custom.conf').write_text('PasswordAuthentication yes\n')
        legacy = self.dropins / '99-bootstrap.conf'
        original = 'PubkeyAuthentication yes\n'
        legacy.write_text(original)
        self.run_shell('step_harden_ssh', success=False)
        self.assertEqual(legacy.read_text(), original)
        self.assertFalse((self.dropins / '10-bootstrap.conf').exists())
        self.assertFalse((self.state / 'harden_ssh.done').exists())
        calls = (self.root / 'systemctl.log').read_text()
        self.assertNotIn('reload ssh\n', calls)

    def test_syntax_failure_restores_previous_file(self):
        target = self.dropins / '10-bootstrap.conf'
        original = 'PubkeyAuthentication yes\n'
        target.write_text(original)
        self.run_shell('SSH_PORT=invalid; step_harden_ssh', success=False)
        self.assertEqual(target.read_text(), original)
        self.assertFalse((self.state / 'harden_ssh.done').exists())

    def test_service_failure_restores_files_and_removes_marker(self):
        target = self.dropins / '10-bootstrap.conf'
        original = 'PubkeyAuthentication yes\n'
        target.write_text(original)
        self.socket.write_text('original socket settings\n')
        (self.state / 'harden_ssh.done').touch()
        self.run_shell('FAIL_RELOAD=1; FAIL_RESTART=1; step_harden_ssh', success=False)
        self.assertEqual(target.read_text(), original)
        self.assertEqual(self.socket.read_text(), 'original socket settings\n')
        self.assertFalse((self.state / 'harden_ssh.done').exists())

    def test_socket_failure_restores_previous_socket_file(self):
        self.socket.write_text('original socket settings\n')
        self.run_shell('SOCKET_ENABLED=1; FAIL_SOCKET=1; SSH_PORT=2222; '
                       'step_harden_ssh', success=False)
        self.assertEqual(self.socket.read_text(), 'original socket settings\n')
        self.assertFalse((self.dropins / '10-bootstrap.conf').exists())
        self.assertFalse((self.state / 'harden_ssh.done').exists())

    def test_termination_restores_configuration(self):
        target = self.dropins / '10-bootstrap.conf'
        original = 'PubkeyAuthentication yes\n'
        target.write_text(original)
        result = self.run_shell('''
reload_ssh_service() {
  if [[ "${SIGNAL_SENT:-0}" == 0 ]]; then
    SIGNAL_SENT=1
    python3 -c 'import os, signal; os.kill(os.getppid(), signal.SIGTERM)'
  fi
}
step_harden_ssh
''', success=False)
        self.assertEqual(result.returncode, 143)
        self.assertEqual(target.read_text(), original)
        self.assertFalse((self.state / 'harden_ssh.done').exists())

    def test_main_marks_completion_only_after_ssh_success(self):
        setup = '''
require_root() { :; }; check_supported_os() { :; }
password_step_needed() { return 1; }
for name in step_apt_upgrade step_apt_cleanup step_timezone step_ensure_sudo \\
            step_install_pkgs step_create_user step_set_password step_shell_alias \\
            step_configure_system_shell step_root_shell_zsh; do
  eval "$name() { :; }"
done
BOOTSTRAP_PUBKEY=''' + shlex.quote(self.key()) + '\n'
        self.run_shell(setup + 'FAIL_RELOAD=1; FAIL_RESTART=1; main', success=False)
        self.assertFalse((self.state / 'done').exists())
        self.run_shell(setup + 'main')
        self.assertTrue((self.state / 'done').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
