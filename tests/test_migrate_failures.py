"""Migration must propagate errors even when called in a Bash conditional."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MigrationFailures(unittest.TestCase):
    def attempt(self, failure, units=False, disable_ipv6='1'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ['lib', 'systemd', 'sysctl', 'state', 'backup']:
                (root / name).mkdir()
            source = (ROOT / 'rp.sh').read_text().rsplit('main "$@"', 1)[0]
            source = source.replace('/etc/systemd/system/', tmp + '/systemd/').replace('/etc/sysctl.d/', tmp + '/sysctl/')
            (root / 'functions').write_text(source)
            (root / 'rp.conf').write_text('ROLE="vps1"\nCONF_VER="2"\nTRANSPORT_ORDER="reality-xhttp2"\n')
            targets = {'net-script': 'lib/net-up.sh', 'net-unit': 'systemd/rp-net.service',
                       'sync-unit': 'systemd/rp-route-sync.service', 'echo-unit': 'systemd/rp-echo.service',
                       'transport-unit': 'systemd/rp-hy2.service', 'sysctl-file': 'sysctl/99-rp.conf'}
            if units and failure in targets:
                (root / targets[failure]).mkdir()  # a real redirection failure, even as root
            script = r'''
source "$TEST_DIR/functions"
ETC=$TEST_DIR; CONF=$ETC/rp.conf; LIB=$ETC/lib; STATE=$ETC/state; BK_DIR=$ETC/backup
need_vps1; CFG[DISABLE_IPV6]=$TEST_DISABLE_IPV6
sysctl() { [[ $TEST_FAILURE != sysctl-apply ]]; }
systemctl() { [[ $TEST_FAILURE != unit-reload ]]; }
'''
            if not units:
                script += r'''
self_install() { :; }; py_install() { :; }
conf_migrate() { :; }; conf_exit_mtu_migrate() { :; }; conf_set() { :; }
units_vps1() { [[ $TEST_FAILURE != units ]]; }
vps1_apply() { :; }; vps1_check() { [[ $TEST_FAILURE != readiness ]]; }
route_sync_locked() { :; }; pin_release() { :; }; run() { return 0; }
cp() { [[ $TEST_FAILURE != backup ]] || return 1; command cp "$@"; }
systemctl() {
  [[ $TEST_FAILURE != network ]] || return 1
  [[ $TEST_FAILURE != route-timer || $* != 'enable --now rp-route-sync.timer' ]]
}
'''
            action = 'units_vps1' if units else 'cmd_migrate'
            script += '\nif ' + action + '; then echo MIGRATE_SUCCESS; else exit 42; fi\n'
            result = subprocess.run(['bash', '-c', script], text=True, capture_output=True,
                                    env=dict(os.environ, TEST_DIR=tmp, TEST_FAILURE=failure,
                                             TEST_DISABLE_IPV6=disable_ipv6), timeout=10)
            return result

    def test_unit_generation_errors_are_not_masked(self):
        for failure in ['net-script', 'net-unit', 'sync-unit', 'echo-unit', 'transport-unit',
                        'sysctl-file', 'sysctl-apply', 'unit-reload']:
            with self.subTest(failure=failure):
                result = self.attempt(failure, units=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('MIGRATE_SUCCESS', result.stdout)

    def test_migration_stops_after_failed_stage(self):
        for failure in ['backup', 'units', 'network', 'readiness', 'route-timer']:
            with self.subTest(failure=failure):
                result = self.attempt(failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('MIGRATE_SUCCESS', result.stdout)

    def test_valid_unit_generation(self):
        for value in ['0', '1']:
            with self.subTest(disable_ipv6=value):
                result = self.attempt('', units=True, disable_ipv6=value)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_valid_migration(self):
        result = self.attempt('')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
