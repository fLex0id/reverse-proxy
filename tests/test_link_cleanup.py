"""Temporary link delivery owns only the firewall port rule it created."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from rp_fixture import SINGLE

ROOT = Path(__file__).resolve().parents[1]


class LinkCleanup(unittest.TestCase):
    def run_case(self, failure='', preexisting=False):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'functions').write_text(SINGLE.read_text().rsplit('main "$@"', 1)[0])
        serve = self.root / 'serve'
        serve.mkdir(mode=0o700)
        (serve / 'result').write_text('ok\n')
        (serve / 'block.sh').write_text('fixture\n')
        if preexisting:
            (self.root / 'port-open').touch()
        script = r'''
source "$TEST_DIR/functions"
STATE=$TEST_DIR
fw_kind() { echo firewalld; }
firewall-cmd() {
  case $1 in
    --query-port=*) [[ -e $STATE/port-open ]];;
    --add-port=*) [[ $TEST_FAILURE != open ]] || return 1; touch "$STATE/port-open";;
    --remove-port=*) [[ $TEST_FAILURE != close ]] || return 1; rm -f "$STATE/port-open";;
    *) return 2;;
  esac
}
fw_open_rt 8444/tcp || exit 9
link_close 8444
'''
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True,
            env=dict(os.environ, TEST_DIR=str(self.root), TEST_FAILURE=failure, RP_ASCII='0'))

    def test_open_error_is_not_success(self):
        result = self.run_case('open')
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)

    def test_close_error_is_not_success_and_keeps_retry_marker(self):
        result = self.run_case('close')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'link.firewall').exists())
        self.assertEqual((self.root / 'link.result').read_text(), 'cleanup-failed\n')
        self.assertFalse((self.root / 'serve').exists())

    def test_preexisting_firewall_rule_is_preserved(self):
        result = self.run_case(preexisting=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / 'port-open').exists())

    def test_owned_rule_and_secrets_removed(self):
        result = self.run_case()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'port-open').exists())
        self.assertFalse((self.root / 'link.firewall').exists())
        self.assertFalse((self.root / 'serve').exists())
        self.assertEqual((self.root / 'link.result').read_text(), 'ok\n')


if __name__ == '__main__':
    unittest.main()
