"""Diagnostic failures must be observable by callers, including after --fix."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from rp_fixture import SINGLE

ROOT = Path(__file__).resolve().parents[1]

class DiagnosticStatus(unittest.TestCase):
    def run_diag(self, failure='', fix=False, repairs=True, args=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'functions'
            path.write_text(SINGLE.read_text().rsplit('main "$@"', 1)[0])
            script = r'''source "$TEST_DIR/functions"
need_vps1() { :; }
banner() { :; }
sleep() { :; }
broken() { [[ $TEST_FAILURE == "$1" && ! -f $TEST_DIR/repaired ]]; }
systemctl() { ! broken service; }
vps2_read() {
  if [[ $1 == *'/var/lib/rp/active'* ]]; then
    broken control && return 1
    echo hy2-wg
  else
    broken egress-unavailable && return 1
    if broken nat; then echo nat=no; else echo nat=yes; fi
    echo ip_forward=1; echo fw_forward=yes
  fi
}
vps2_run() {
  [[ $TEST_REPAIR == yes ]] && touch "$TEST_DIR/repaired"
  return 0
}
hy2_live() { ! broken handshake; }
sysctl() {
  if [[ $* == *'-w '* ]]; then
    [[ $TEST_REPAIR == yes ]] && touch "$TEST_DIR/repaired"
    return 0
  fi
  if broken rpfilter; then echo 1; else echo 2; fi
}
ip() { broken route || echo '1.1.1.1 dev wg-exit'; }
py() {
  if [[ $1 == probe ]]; then
    if broken probe; then echo 'fail connection'; else echo 'ok 1'; fi
  else
    broken dns-generator && return 1
    broken dns-empty && return 0
    echo https://good/dns-query
    broken dns-second && echo https://bad/dns-query
    return 0
  fi
}
sx() {
  if broken https; then echo 500; return 22; fi
  echo 204
  broken partial && return 28
  return 0
}
doh_test() { ! broken dns && [[ $1 != *bad* ]]; }
cmd_diag "$@"
'''
            return subprocess.run(['bash', '-c', script, 'bash'] + (args if args is not None else ['--fix'] if fix else []),
                capture_output=True, text=True, env=dict(os.environ, TEST_DIR=tmp,
                    TEST_FAILURE=failure, TEST_REPAIR='yes' if repairs else 'no')).returncode

    def test_healthy(self): self.assertEqual(self.run_diag(), 0)

    def test_invalid_arguments_are_rejected(self):
        for args in [['--unknown'], ['--fix', '--fix']]:
            with self.subTest(args=args):
                self.assertEqual(self.run_diag(args=args), 2)

    def test_failures_are_not_success(self):
        for failure in ['service', 'control', 'handshake', 'rpfilter', 'route', 'probe',
                        'nat', 'egress-unavailable', 'https', 'partial', 'dns',
                        'dns-second', 'dns-empty', 'dns-generator']:
            with self.subTest(failure=failure):
                self.assertNotEqual(self.run_diag(failure), 0)

    def test_repaired_rp_filter_is_rechecked(self):
        self.assertEqual(self.run_diag('rpfilter', fix=True), 0)

    def test_failed_rp_filter_repair_is_not_success(self):
        self.assertNotEqual(self.run_diag('rpfilter', fix=True, repairs=False), 0)

    def test_repaired_nat_is_rechecked(self):
        self.assertEqual(self.run_diag('nat', fix=True), 0)

    def test_successful_fix_command_without_repair_is_not_success(self):
        self.assertNotEqual(self.run_diag('nat', fix=True, repairs=False), 0)

if __name__ == '__main__':
    unittest.main()
