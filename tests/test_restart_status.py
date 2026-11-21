"""Actual role-specific restart functions must propagate service failures."""
import os
from pathlib import Path
import subprocess
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'rp.sh').read_text()
RESTARTS = ['cmd_restart() {' + part.split('\ncmd_', 1)[0]
            for part in SOURCE.split('\ncmd_restart() {')[1:]]


class RestartStatus(unittest.TestCase):
    def attempt(self, role, failure=''):
        script = r'''
need_vps1() { :; }
cf() { echo 'reality-xhttp2 reality-xhttp hy2-wg hy2o-wg'; }
tr_has() { return 0; }
active() { echo hy2-wg; }
systemctl() { echo "systemctl $*"; [[ $* != "$TEST_FAILURE" ]]; }
tr_start() { [[ $TEST_FAILURE != transport ]]; }
restart_ready() { [[ $TEST_FAILURE != readiness ]]; }
vps1_check() { [[ $TEST_FAILURE != readiness ]]; }
unit_up() { [[ $TEST_FAILURE != inner-wg ]]; }
say() { echo "$*"; }; ok() { echo "SUCCESS $*"; }; err() { echo "ERROR $*" >&2; }
''' + RESTARTS[role] + '\ncmd_restart\n'
        return subprocess.run(['bash', '-c', script], text=True, capture_output=True,
                              env=dict(os.environ, TEST_FAILURE=failure))

    def test_vps1_failed_restart_does_not_report_success(self):
        for failure in ['restart rp-net rp-xray rp-echo wg-quick@wg0', 'restart rp-hy2',
                        'restart rp-hy2o', 'restart wg-quick@wg-exit']:
            with self.subTest(failure=failure):
                r = self.attempt(1, failure)
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertNotIn('SUCCESS', r.stdout)

    def test_vps1_restarts_client_wg_and_probe_service(self):
        r = self.attempt(1)
        self.assertIn('wg-quick@wg0', r.stdout)
        self.assertIn('rp-echo', r.stdout)

    def test_vps2_failed_transport_does_not_report_success(self):
        r = self.attempt(0, 'transport')
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn('Перезапущено:', r.stdout)

    def test_successful_restarts(self):
        for role in [0, 1]:
            with self.subTest(role=role):
                r = self.attempt(role)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_successful_start_without_readiness_is_failure(self):
        for role in [0, 1]:
            with self.subTest(role=role):
                r = self.attempt(role, 'readiness')
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertNotIn('SUCCESS', r.stdout)

    def test_inner_wg_must_be_active(self):
        self.assertNotEqual(self.attempt(1, 'inner-wg').returncode, 0)


if __name__ == '__main__':
    unittest.main()
