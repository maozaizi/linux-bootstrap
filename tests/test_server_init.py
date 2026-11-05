"""Dispatch and workflow checks; component commands are replaced by temporary scripts."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServerInitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='server-init-test-')
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.calls = self.folder / 'calls'
        self.envfile = self.folder / 'env'
        self.source = (ROOT / 'server-init.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        self.source = self.source.replace('/run/lock/linux-bootstrap.lock', str(self.folder / 'lock'))
        self.source = self.source.replace('/var/log/server-init-', str(self.folder / 'log-'))
        for name in ('bootstrap-debian', 'setup-swap', 'enable-bbr', 'ipv6-manager',
                     'ufw-manager', 'server-security-audit', 'install-docker'):
            script = self.folder / (name + '.sh')
            script.write_text(f'''#!/bin/bash
printf '%s' {shlex.quote(name)} >> {shlex.quote(str(self.calls))}
printf ' [%s]' "$@" >> {shlex.quote(str(self.calls))}
printf '\\n' >> {shlex.quote(str(self.calls))}
if [[ {shlex.quote(name)} == bootstrap-debian ]]; then
  printf '%s|%s|%s\\n' "${{FORCE_RUN:-}}" "${{HARDEN_SSH:-}}" "${{SET_ROOT_SHELL_ZSH:-}}" > {shlex.quote(str(self.envfile))}
fi
if [[ "${{FAIL_COMPONENT:-}}" == {shlex.quote(name)} ]]; then exit 17; fi
''')
        self.base = '\nSCRIPT_DIR=' + shlex.quote(str(self.folder)) + '\n'

    def run_shell(self, code, *, stdin='', success=True):
        result = subprocess.run(['bash', '-c', self.source + self.base + code],
                                input=stdin, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def workflow(self):
        return f'''
preflight() {{ :; }}
collect_key() {{ export BOOTSTRAP_PUBKEY='test key'; }}
confirm() {{ return 0; }}
flock() {{ return 0; }}
setup_swap() {{ echo swap >> {shlex.quote(str(self.calls))}; }}
setup_firewall() {{ echo firewall >> {shlex.quote(str(self.calls))}; }}
'''

    def test_help_and_version_need_no_root_or_linux(self):
        for arg in ('--help', '--version'):
            result = subprocess.run(['bash', str(ROOT / 'server-init.sh'), arg], capture_output=True)
            self.assertEqual(result.returncode, 0)

    def test_every_component_dispatches_independently(self):
        mapping = {'bootstrap': 'bootstrap-debian', 'swap': 'setup-swap', 'bbr': 'enable-bbr',
                   'ipv6': 'ipv6-manager', 'firewall': 'ufw-manager',
                   'audit': 'server-security-audit', 'docker': 'install-docker'}
        for action, script in mapping.items():
            with self.subTest(action=action):
                self.calls.write_text('')
                self.run_shell('main ' + action + ' --comment "two words"')
                self.assertEqual(self.calls.read_text(), script + ' [--comment] [two words]\n')

    def test_complete_workflow_and_environment(self):
        self.run_shell(self.workflow() + 'main init', stdin='verified\n')
        self.assertEqual(self.calls.read_text().splitlines(), [
            'bootstrap-debian [--check]', 'swap', 'bootstrap-debian []',
            'enable-bbr []', 'ipv6-manager [disable]',
            'firewall', 'server-security-audit [--audit-only]', 'server-security-audit [--yes]'])
        self.assertEqual(self.envfile.read_text(), '1|0|1\n')
        self.assertNotIn('install-docker', self.calls.read_text())

    def test_preserve_ipv6_and_defer_security(self):
        self.run_shell(self.workflow() + 'main init --keep-ipv6 --defer-ssh-lockdown')
        calls = self.calls.read_text()
        self.assertNotIn('ipv6-manager', calls)
        self.assertNotIn('[--yes]', calls)
        self.assertIn('[--audit-only]', calls)

    def test_unverified_login_never_closes_password_auth(self):
        result = self.run_shell(self.workflow() + 'main init', stdin='\n')
        self.assertNotIn('[--yes]', self.calls.read_text())
        self.assertIn('收口尚未完成', result.stdout)

    def test_failure_stops_later_components(self):
        result = self.run_shell(self.workflow() +
                                'export FAIL_COMPONENT=enable-bbr; main init', success=False)
        self.assertEqual(result.returncode, 17)
        calls = self.calls.read_text()
        self.assertNotIn('ipv6-manager', calls)
        self.assertNotIn('server-security-audit', calls)
        self.assertIn('enable-bbr.sh', result.stderr + result.stdout)

    def test_preflight_failure_prevents_swap_and_install(self):
        self.run_shell(self.workflow() +
                       'export FAIL_COMPONENT=bootstrap-debian; main init', success=False)
        self.assertEqual(self.calls.read_text(), 'bootstrap-debian [--check]\n')

    def test_existing_firewall_is_not_reset(self):
        self.run_shell('ufw() { echo "Status: active"; }; setup_firewall')
        self.assertEqual(self.calls.read_text(), 'ufw-manager [check]\n')

    def test_fresh_firewall_is_initialized(self):
        self.run_shell('ufw() { if [[ "$1" == status ]]; then echo "Status: inactive"; fi; }; setup_firewall')
        self.assertEqual(self.calls.read_text(), 'ufw-manager [init] [--yes]\n')

    def test_inactive_existing_rules_require_operator(self):
        self.run_shell('ufw() { if [[ "$1" == status ]]; then echo "Status: inactive"; '
                       'else echo "ufw allow 8080/tcp"; fi; }; setup_firewall', success=False)
        self.assertEqual(self.calls.read_text(), 'ufw-manager [check]\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
