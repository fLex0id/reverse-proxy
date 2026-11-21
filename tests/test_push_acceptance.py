"""Exercise the actual push_wait function with controlled remote replies.

These are orchestration regressions, not substitutes for two-host E2E tests.
No rp function touches the real host: every external effect is stubbed below.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ORDER = 'reality-xhttp2 reality-xhttp hy2-wg hy2o-wg'
GOOD = '\n'.join(t + '=ok' for t in ORDER.split())

class PushAcceptance(unittest.TestCase):
    def run_wait(self, results, install_rc='0', sync_rc='0'):
        source = (ROOT / 'rp.sh').read_text()
        self.assertTrue(source.endswith('main "$@"\n'))
        with tempfile.TemporaryDirectory() as d:
            Path(d, 'functions.sh').write_text(source.rsplit('main "$@"', 1)[0])
            env = dict(os.environ, TEST_RESULTS=results, TEST_RC=install_rc,
                       TEST_SYNC_RC=sync_rc, TEST_DIR=d, RP_ASCII='1')
            script = r'''
source "$TEST_DIR/functions.sh"
STATE=$TEST_DIR
CFG[TRANSPORT_ORDER]='reality-xhttp2 reality-xhttp hy2-wg hy2o-wg'
sleep() { :; }
note() { :; }
route_sync_locked() { return "$TEST_SYNC_RC"; }
wait_exit() { return 0; }
vps2_read() { return 1; }
vps2_run() {
  case "$1" in
    'cat /var/lib/rp/push.rc 2>/dev/null') printf '%s\n' "$TEST_RC" ;;
    '/usr/local/bin/rp confirm') echo CONFIRMED >>"$TEST_DIR/confirmed" ;;
    *) return 1 ;;
  esac
}
tr_results() { printf '%s\n' "$TEST_RESULTS"; }
push_wait
'''
            p = subprocess.run(['bash', '-c', script], env=env,
                               text=True, capture_output=True, timeout=5)
            return p, Path(d, 'confirmed').exists()

    def assert_rejected(self, results, **kw):
        p, confirmed = self.run_wait(results, **kw)
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertFalse(confirmed, 'rollback was disarmed before acceptance')
        self.assertNotIn('FULL_OK', p.stdout)

    def test_full_results_commit(self):
        p, confirmed = self.run_wait(GOOD)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(confirmed)
        self.assertIn('FULL_OK', p.stdout)

    def test_empty_results_rejected(self): self.assert_rejected('')
    def test_partial_results_rejected(self): self.assert_rejected('hy2-wg=ok')
    def test_degraded_rejected(self): self.assert_rejected(GOOD.replace('hy2-wg=ok', 'hy2-wg=fail:t3'))
    def test_duplicate_rejected(self): self.assert_rejected(GOOD + '\nhy2-wg=ok')
    def test_unknown_transport_rejected(self): self.assert_rejected(GOOD + '\nother=ok')
    def test_bad_result_rejected(self): self.assert_rejected(GOOD.replace('hy2-wg=ok', 'hy2-wg=unknown'))
    def test_unsynchronized_route_rejected(self): self.assert_rejected(GOOD, sync_rc='1')
    def test_invalid_install_rc_rejected(self): self.assert_rejected(GOOD, install_rc='not_a_status')
    def test_install_failure_rejected(self): self.assert_rejected(GOOD, install_rc='1')

if __name__ == '__main__': unittest.main()
