"""Package manifest contracts without apt or host configuration changes."""
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackageListTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='package-list-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.manifest = self.root / 'soft-list'
        self.state = self.root / 'state'
        self.calls = self.root / 'apt-calls'
        self.source = (ROOT / 'bootstrap-debian.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        self.base = f'''
SOFT_LIST_FILE={shlex.quote(str(self.manifest))}
STATE_DIR={shlex.quote(str(self.state))}
DONE_FILE="$STATE_DIR/done"
require_root() {{ :; }}
check_supported_os() {{ :; }}
log() {{ :; }}
apt_get() {{ printf '%s\\n' "$@" >> {shlex.quote(str(self.calls))}; }}
'''

    def run_shell(self, code, success=True):
        r = subprocess.run(['bash', '-c', self.source + self.base + code],
                           capture_output=True, text=True)
        if success:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def test_comments_crlf_whitespace_and_last_line_without_newline(self):
        self.manifest.write_bytes(b'# test\r\n  curl  # comment\r\n\r\nlibssl-dev\r\nlibc6:amd64')
        r = self.run_shell('load_package_list; printf "%s\\n" "${CORE_PKGS[@]}"')
        self.assertEqual(r.stdout.splitlines(), ['curl', 'libssl-dev', 'libc6:amd64'])

    def test_invalid_or_empty_list_stops_before_mutations(self):
        for content in ('', '# only comments\n', '--allow-unauthenticated\n',
                        'curl wget\n', 'curl=1.0\n', 'sudo-\n',
                        'sudo-:amd64\n', 'libc6:amd64-\n'):
            with self.subTest(content=content):
                self.manifest.write_text(content)
                self.run_shell('main --packages-only', success=False)
                self.assertFalse(self.state.exists())
                self.assertFalse(self.calls.exists())

    def test_missing_list_stops_before_mutations(self):
        self.run_shell('main --packages-only', success=False)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.calls.exists())

    def test_manifest_is_never_executed_as_code(self):
        sentinel = self.root / 'unexpected'
        self.manifest.write_text('$(touch ' + str(sentinel) + ')\n')
        self.run_shell('main --packages-only', success=False)
        self.assertFalse(sentinel.exists())

    def test_changed_list_is_applied_despite_completion_markers(self):
        self.state.mkdir()
        (self.state / 'install_pkgs.done').touch()
        (self.state / 'done').touch()
        self.manifest.write_text('curl\n')
        self.run_shell('main --packages-only')
        self.manifest.write_text('curl\njq\n')
        self.run_shell('main --packages-only')
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['update', 'install', '--no-remove', '-y', 'curl',
                          'update', 'install', '--no-remove', '-y', 'curl', 'jq'])

    def test_real_compiler_package_names_remain_supported(self):
        self.manifest.write_text('g++\nlibstdc++6\n')
        self.run_shell('main --packages-only')
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['update', 'install', '--no-remove', '-y', 'g++', 'libstdc++6'])

    def test_ping_keeps_installed_provider_and_defaults_to_iputils(self):
        for status, expected in [('installed', 'inetutils-ping'),
                                 ('config-files', 'iputils-ping'),
                                 ('', 'iputils-ping')]:
            with self.subTest(status=status):
                self.manifest.write_text('ping\ncurl\n')
                self.calls.write_text('')
                self.run_shell(f'''
dpkg-query() {{
    [[ "$*" == '-W -f=${{db:Status-Status}} inetutils-ping' ]] || return 2
    [[ -n {shlex.quote(status)} ]] || return 1
    printf '%s' {shlex.quote(status)}
}}
main --packages-only
''')
                self.assertEqual(self.calls.read_text().splitlines(),
                                 ['update', 'install', '--no-remove', '-y', expected, 'curl'])

    def test_explicit_ping_package_is_passed_through(self):
        self.manifest.write_text('iputils-ping\n')
        self.run_shell('dpkg-query() { printf installed; }; main --packages-only')
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['update', 'install', '--no-remove', '-y', 'iputils-ping'])

    def test_install_refreshes_sources_even_when_upgrade_marker_exists(self):
        self.state.mkdir()
        (self.state / 'apt_upgrade.done').touch()
        self.manifest.write_text('curl\n')
        self.run_shell('load_package_list; step_apt_upgrade; step_install_pkgs')
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['update', 'install', '--no-remove', '-y', 'curl'])

    def test_sources_are_refreshed_once_per_run(self):
        self.state.mkdir()
        self.manifest.write_text('curl\n')
        self.run_shell('load_package_list; step_apt_upgrade; step_install_pkgs')
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['update', 'upgrade', '-y', '--with-new-pkgs',
                          'install', '--no-remove', '-y', 'curl'])

    def test_apt_waits_for_lock_and_keeps_existing_config_files(self):
        script = shlex.quote(str(ROOT / 'bootstrap-debian.sh'))
        r = self.run_shell('apt-get() { printf "%s\\n" "$DEBIAN_FRONTEND" "$@"; }; '
                           'eval "$(sed -n \'/^apt_get() {/,/^}/p\' ' + script + ')"; '
                           'APT_LOCK_TIMEOUT=42; apt_get install -y curl')
        self.assertEqual(r.stdout.splitlines(),
                         ['noninteractive', '-o', 'DPkg::Lock::Timeout=42',
                          '-o', 'Dpkg::Options::=--force-confdef',
                          '-o', 'Dpkg::Options::=--force-confold', 'install', '-y', 'curl'])

    def test_invalid_lock_timeout_stops_before_apt(self):
        self.manifest.write_text('curl\n')
        self.run_shell('APT_LOCK_TIMEOUT=abc; main --packages-only', success=False)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.state.exists())

    def test_default_list_resolves_from_script_location(self):
        r = subprocess.run(['bash', str(ROOT / 'bootstrap-debian.sh'), '--help'],
                           cwd=self.root, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(str(ROOT / 'soft-list'), r.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
