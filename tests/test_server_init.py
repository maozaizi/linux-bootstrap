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
if [[ {shlex.quote(name)} == ufw-manager && "${{1:-}}" == init ]]; then
  [[ " $* " == *' --yes '* ]] || exit 23
fi
''')
        self.base = ('\nSCRIPT_DIR=' + shlex.quote(str(self.folder)) + '\n' +
                     'timedatectl() { echo "${TEST_SYNCED:-yes}"; }\n')

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

    def test_default_menu_never_initializes_on_exit_or_eof(self):
        for stdin in ('0\n', '\n', ''):
            with self.subTest(stdin=stdin):
                r = self.run_shell('main', stdin=stdin)
                self.assertIn('请选择一项执行', r.stdout)
                self.assertFalse(self.calls.exists())

    def test_menu_runs_only_selected_component(self):
        mapping = {'2': 'setup-swap []', '3': 'enable-bbr []',
                   '4': 'ipv6-manager []', '6': 'install-docker []',
                   '7': 'server-security-audit [--audit-only]',
                   '9': 'bootstrap-debian [--time-sync-only]'}
        for choice, expected in mapping.items():
            with self.subTest(choice=choice):
                self.calls.write_text('')
                self.run_shell('main menu', stdin=choice + '\n')
                self.assertEqual(self.calls.read_text().strip(), expected)

    def test_menu_basic_environment_collects_key_and_preserves_ssh(self):
        self.run_shell('collect_key() { export BOOTSTRAP_PUBKEY="test key"; }; main',
                       stdin='1\n')
        self.assertEqual(self.calls.read_text(), 'bootstrap-debian []\n')
        self.assertEqual(self.envfile.read_text(), '1|0|1\n')

    def test_menu_firewall_defaults_to_check_and_init_keeps_confirmation(self):
        for stdin, expected in (('5\n\n', 'ufw-manager [check]\n'),
                                ('5\ninit\ny\n', 'ufw-manager [init] [--yes]\n')):
            with self.subTest(stdin=stdin):
                self.calls.write_text('')
                self.run_shell('main', stdin=stdin)
                self.assertEqual(self.calls.read_text(), expected)

    def test_menu_firewall_decline_or_eof_never_calls_component(self):
        for stdin in ('5\ninit\nn\n', '5\ninit\n', '5\ninit\n\n'):
            with self.subTest(stdin=stdin):
                self.run_shell('main', stdin=stdin)
                self.assertFalse(self.calls.exists())

    def test_menu_ssh_lockdown_requires_verified_login(self):
        for answer, expected in (('', ['server-security-audit [--audit-only]']),
                                 ('verified', ['server-security-audit [--audit-only]',
                                               'server-security-audit [--yes]'])):
            with self.subTest(answer=answer):
                self.calls.write_text('')
                self.run_shell('main', stdin='8\n' + answer + '\n')
                self.assertEqual(self.calls.read_text().splitlines(), expected)

    def test_full_workflow_is_explicit_menu_choice(self):
        self.run_shell(self.workflow() + 'main', stdin='10\nverified\n')
        self.assertIn('bootstrap-debian [--check]', self.calls.read_text())
        self.assertIn('firewall', self.calls.read_text())

    def test_invalid_menu_choice_or_firewall_action_never_runs_component(self):
        for stdin in ('99\n', '5\nreset\n'):
            with self.subTest(stdin=stdin):
                self.run_shell('main', stdin=stdin, success=False)
                self.assertFalse(self.calls.exists())

    def test_menu_component_failure_is_propagated(self):
        r = self.run_shell('export FAIL_COMPONENT=enable-bbr; main',
                           stdin='3\n', success=False)
        self.assertEqual(r.returncode, 17)
        self.assertEqual(self.calls.read_text(), 'enable-bbr []\n')

    def test_complete_workflow_and_environment(self):
        result = self.run_shell(self.workflow() + 'main init', stdin='verified\n')
        self.assertIn('[已完成] SSH 仅允许公钥认证', result.stdout)
        self.assertNotIn('[待办] SSH', result.stdout)
        self.assertEqual(self.calls.read_text().splitlines(), [
            'bootstrap-debian [--check]', 'swap', 'bootstrap-debian []',
            'enable-bbr []', 'ipv6-manager [disable]',
            'firewall', 'server-security-audit [--audit-only]', 'server-security-audit [--yes]'])
        self.assertEqual(self.envfile.read_text(), '1|0|1\n')
        self.assertNotIn('install-docker', self.calls.read_text())

    def test_preserve_ipv6_and_defer_security(self):
        result = self.run_shell(self.workflow() + 'main init --keep-ipv6 --defer-ssh-lockdown')
        self.assertIn('[待办] SSH 密码收口未执行', result.stdout)
        calls = self.calls.read_text()
        self.assertNotIn('ipv6-manager', calls)
        self.assertNotIn('[--yes]', calls)
        self.assertIn('[--audit-only]', calls)

    def test_unverified_login_never_closes_password_auth(self):
        result = self.run_shell(self.workflow() + 'main init', stdin='\n')
        self.assertNotIn('[--yes]', self.calls.read_text())
        self.assertIn('收口尚未完成', result.stdout)
        self.assertIn('[待办] SSH 密码收口未执行', result.stdout)

    def test_completion_summary_reports_pending_time_and_shell_hint(self):
        result = self.run_shell('TEST_SYNCED=no; finish_summary')
        self.assertIn('[待办] 时间同步尚未确认', result.stdout)
        self.assertIn('exec zsh -l', result.stdout)
        self.assertNotIn('[已完成] 系统时间已同步', result.stdout)

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
        self.run_shell('''
ufw() {
  if [[ "$1" == status ]]; then
    echo 'Status: inactive'
  else
    printf "%s\\n" "Added user rules (see 'ufw status' for running firewall):" '(None)'
  fi
}
setup_firewall
''')
        self.assertEqual(self.calls.read_text(), 'ufw-manager [init] [--yes]\n')

    def test_inactive_existing_rules_require_operator(self):
        self.run_shell('ufw() { if [[ "$1" == status ]]; then echo "Status: inactive"; '
                       'else printf "%s\\n" "Added user rules (see \'ufw status\' for running firewall):" '
                       '"ufw allow 8080/tcp"; fi; }; setup_firewall', success=False)
        self.assertEqual(self.calls.read_text(), 'ufw-manager [check]\n')

    def test_firewall_read_failure_stops_before_initialization(self):
        for failing in ('status', 'show'):
            with self.subTest(failing=failing):
                self.run_shell('ufw() { [[ "$1" != ' + failing + ' ]]; }; setup_firewall',
                               success=False)
                self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
