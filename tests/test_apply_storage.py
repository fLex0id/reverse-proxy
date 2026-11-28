"""Applying rendered files must stop if its rollback copy cannot be made."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from rp_fixture import SINGLE

ROOT = Path(__file__).resolve().parents[1]


class ApplyStorage(unittest.TestCase):
    def attempt(self, failure=''):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.target = self.root / 'installed'
        self.target.write_text('original\n')
        self.target.chmod(0o600)
        (self.root / 'functions').write_text(SINGLE.read_text().rsplit('main "$@"', 1)[0])
        script = r'''
source "$TEST_DIR/functions"
STATE=$TEST_DIR; BK_DIR=$STATE/backups; ASSETS=$STATE; XRAY_BIN=/bin/true
conf_load() { :; }
py() {
  printf 'candidate\n' >"$2/xray.json"
  printf 'xray.json|%s/installed|600|root:root|restart:fixture\n' "$TEST_DIR"
}
vps1_units_sync() { :; }
vps1_check() { [[ $TEST_FAILURE != readiness && $TEST_FAILURE != restore ]]; }
vps1_actions() { :; }
cp() {
  if [[ $TEST_FAILURE == backup && ${!#} == "$BK_DIR/"* ]]; then return 1; fi
  if [[ $TEST_FAILURE == restore && ${!#} == "$TEST_DIR/installed"* ]]; then return 1; fi
  command cp "$@"
}
chmod() { [[ $TEST_FAILURE != permissions ]] || return 1; command chmod "$@"; }
mv() { [[ $TEST_FAILURE != publish ]] || return 1; command mv "$@"; }
vps1_apply
'''
        return subprocess.run(['bash', '-c', script], text=True, capture_output=True,
                              env=dict(os.environ, TEST_DIR=str(self.root), TEST_FAILURE=failure, RP_ASCII='0'))

    def test_backup_failure_never_publishes_candidate(self):
        result = self.attempt('backup')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_text(), 'original\n')

    def test_private_directory_failure_stops_apply(self):
        result = self.attempt('permissions')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_text(), 'original\n')

    def test_publication_failure_cleans_staging(self):
        result = self.attempt('publish')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_text(), 'original\n')
        self.assertFalse(self.target.with_name('installed.rp-new').exists())

    def test_failed_readiness_restores_original(self):
        result = self.attempt('readiness')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_text(), 'original\n')

    def test_restore_failure_is_explicit_and_retains_backup(self):
        result = self.attempt('restore')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Откат файлов не завершён', result.stdout + result.stderr)
        self.assertTrue(any(p.read_text() == 'original\n' for p in (self.root / 'backups').rglob('*') if p.is_file()))

    def test_success_keeps_private_backup(self):
        result = self.attempt()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_text(), 'candidate\n')
        backups = [p for p in (self.root / 'backups').iterdir() if p.is_dir()]
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o700)


if __name__ == '__main__':
    unittest.main()
