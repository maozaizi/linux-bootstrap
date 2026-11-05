"""Check service-manager selection without installing Docker."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DockerLoggingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='docker-logging-')
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / 'docker'
        self.config = self.directory / 'daemon.json'
        source = (ROOT / 'install-docker.sh').read_text()
        start = source.index('configure_log_rotation() {')
        end = source.index('# 连接正在运行的 systemd', start)
        self.source = ('set -euo pipefail\ninfo() { :; }; warn() { :; }; '
                       'die() { echo "$*" >&2; exit 1; };\n' +
                       source[start:end].replace('/etc/docker', str(self.directory)))

    def run_logging(self, size, count):
        return subprocess.run(['bash', '-c', self.source + '\nconfigure_log_rotation'],
                              env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                                   'DOCKER_LOG_MAX_SIZE': size, 'DOCKER_LOG_MAX_FILE': count},
                              text=True, capture_output=True)

    def test_invalid_limits_are_rejected_before_writing(self):
        for size, count in (('0m', '3'), ('000', '3'), ('10m', '0'),
                            ('10m', '000'), ('-1', '3'), ('10m', '1.5')):
            with self.subTest(size=size, count=count):
                r = self.run_logging(size, count)
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertFalse(self.directory.exists())

    def test_valid_limits_are_written(self):
        for size, count in (('10m', '3'), ('1', '1'), ('20M', '5')):
            with self.subTest(size=size, count=count):
                r = self.run_logging(size, count)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                config = json.loads(self.config.read_text())
                self.assertEqual(config['log-opts'], {'max-size': size, 'max-file': count})
                self.config.unlink()

    def test_existing_configuration_is_preserved(self):
        self.directory.mkdir()
        original = '{"live-restore":true}\n'
        self.config.write_text(original)
        r = self.run_logging('10m', '3')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.config.read_text(), original)


class DockerServiceTests(unittest.TestCase):
    def setUp(self):
        source = (ROOT / 'install-docker.sh').read_text()
        start = source.index('systemd_is_running() {')
        end = source.index('\n}', start) + 2
        function = source[start:end]
        start = source.index('# 服务管理：')
        end = source.index('# 版本信息', start)
        self.source = 'set -euo pipefail\n' + function + '\n' + '''
DAEMON_JSON_CREATED=0
DOCKER_WAS_ACTIVE=0
info() { :; }; warn() { :; }
die() { echo "$*" >&2; exit 1; }
systemctl() {
  case "$1" in
    --version) return 0 ;;
    show-environment) [[ "${MANAGER_UP:-0}" == 1 ]] ;;
    enable) echo "SYSTEMD: $*" ;;
    *) return 1 ;;
  esac
}
service() { echo "SERVICE: $*"; [[ "${FAIL_SERVICE:-0}" == 0 ]]; }
'''
        self.body = source[start:end]

    def run_shell(self, settings):
        return subprocess.run(['bash', '-c', self.source + settings + '\n' + self.body],
                              text=True, capture_output=True)

    def test_client_without_manager_uses_service(self):
        r = self.run_shell('MANAGER_UP=0')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('SERVICE: docker start', r.stdout)
        self.assertNotIn('SYSTEMD:', r.stdout)

    def test_running_manager_uses_systemctl(self):
        r = self.run_shell('MANAGER_UP=1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('SYSTEMD: enable --now docker', r.stdout)
        self.assertIn('SYSTEMD: enable --now containerd', r.stdout)
        self.assertNotIn('SERVICE:', r.stdout)

    def test_service_start_failure_is_not_ignored(self):
        r = self.run_shell('MANAGER_UP=0; FAIL_SERVICE=1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('无法通过 service 启动 Docker', r.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
