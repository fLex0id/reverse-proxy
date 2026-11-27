"""RU policy edits must keep source lists and applied state consistent on error."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RUEdits(unittest.TestCase):
    def attempt(self, command, failure='', absent=False):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'functions').write_text((ROOT / 'rp.sh').read_text().rsplit('main "$@"', 1)[0])
        self.original = {'proxy': 'keep.example.com\n', 'direct': 'move.example.com\n'}
        if not absent:
            for kind, body in self.original.items():
                (self.root / ('ru-' + kind + '.list')).write_text(body)
        script = r'''
source "$TEST_DIR/functions"
ETC=$TEST_DIR
need_vps1() { :; }
vps1_apply() { [[ $TEST_FAILURE != apply ]]; }
vps1_set() { [[ $TEST_FAILURE != setting ]]; }
systemctl() { [[ $TEST_FAILURE != timer ]]; }
awk() { [[ $TEST_FAILURE != read ]] || return 2; command awk "$@"; }
grep() { [[ $TEST_FAILURE != read ]] || return 2; command grep "$@"; }
mv() { if [[ $TEST_FAILURE == publish && "$*" == *direct.new* ]]; then return 1; fi; command mv "$@"; }
''' + command
        return subprocess.run(['bash', '-c', script], text=True, capture_output=True,
                              env=dict(os.environ, TEST_DIR=str(self.root), TEST_FAILURE=failure, RP_ASCII='0'))

    def assert_original(self):
        for kind, body in self.original.items():
            self.assertEqual((self.root / ('ru-' + kind + '.list')).read_text(), body)

    def test_apply_failure_restores_both_lists(self):
        result = self.attempt('cmd_ru proxy move.example.com', 'apply')
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()

    def test_read_failure_preserves_both_lists(self):
        result = self.attempt('cmd_ru proxy move.example.com', 'read')
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()

    def test_second_publication_failure_restores_both_lists(self):
        result = self.attempt('cmd_ru proxy move.example.com', 'publish')
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()

    def test_failed_change_restores_original_absence(self):
        result = self.attempt('cmd_ru proxy move.example.com', 'apply', absent=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list(self.root.glob('ru-*.list')))

    def test_success_moves_domain_without_duplicates(self):
        result = self.attempt('cmd_ru proxy move.example.com; cmd_ru proxy move.example.com')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'ru-proxy.list').read_text(), 'keep.example.com\nmove.example.com\n')
        self.assertEqual((self.root / 'ru-direct.list').read_text(), '')

    def test_delete_is_validated_and_failure_restores_lists(self):
        for domain, failure in [('.*', ''), ('move.example.com', 'apply')]:
            with self.subTest(domain=domain):
                result = self.attempt('cmd_ru del ' + "'" + domain + "'", failure)
                self.assertNotEqual(result.returncode, 0)
                self.assert_original()

    def test_foreign_direct_guard_is_preserved(self):
        result = self.attempt('cmd_ru direct google.com')
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()

    def test_off_does_not_mask_config_or_timer_failure(self):
        for failure in ['setting', 'timer']:
            with self.subTest(failure=failure):
                result = self.attempt('cmd_ru off', failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('Всё идёт через туннель', result.stdout)


if __name__ == '__main__':
    unittest.main()
