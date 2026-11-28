"""Configuration publication must preserve the old file on storage failures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from rp_fixture import SINGLE

ROOT = Path(__file__).resolve().parents[1]
OLD = 'KEEP="preserved"\nCHANGE="old"\n'


class ConfigWrite(unittest.TestCase):
    def attempt(self, failure='', original=OLD, arguments='CHANGE new'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            conf = root / 'rp.conf'
            if original is not None:
                conf.write_text(original)
                conf.chmod(0o600)
            (root / 'functions').write_text(SINGLE.read_text().rsplit('main "$@"', 1)[0])
            script = r'''
source "$TEST_DIR/functions"
ETC=$TEST_DIR; CONF=$ETC/rp.conf
cp() { [[ $TEST_FAILURE != copy ]] || return 1; command cp "$@"; }
grep() { [[ $TEST_FAILURE != read ]] || return 2; command grep "$@"; }
chmod() { [[ $TEST_FAILURE != permissions ]] || return 1; command chmod "$@"; }
mv() {
  [[ $TEST_FAILURE != publish || ${!#} != "$CONF" ]] || return 1
  [[ $TEST_FAILURE != edit || ${!#} == "$CONF" ]] || return 1
  command mv "$@"
}
mktemp() { [[ $TEST_FAILURE != stage ]] || return 1; command mktemp "$@"; }
printf() {
  [[ $TEST_FAILURE != append || $1 != '%s="%s"\n' ]] || return 1
  builtin printf "$@"
}
conf_set ''' + arguments + r'''
printf 'DONE %s\n' "$(cf CHANGE)"
'''
            result = subprocess.run(['bash', '-c', script], cwd=root, text=True, capture_output=True,
                                    env=dict(os.environ, TEST_DIR=tmp, TEST_FAILURE=failure), timeout=10)
            return result, conf.read_text() if conf.exists() else None, \
                (conf.stat().st_mode & 0o777) if conf.exists() else None, list(root.glob('.rp.*'))

    def test_storage_failure_preserves_original(self):
        for failure in ['copy', 'read', 'permissions', 'publish', 'edit', 'stage', 'append']:
            with self.subTest(failure=failure):
                result, data, mode, residue = self.attempt(failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('DONE', result.stdout)
                self.assertEqual(data, OLD)
                self.assertEqual(mode, 0o600)
                self.assertFalse(residue)

    def test_success_preserves_other_keys_and_updates_memory(self):
        result, data, mode, residue = self.attempt()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(data, OLD.replace('"old"', '"new"'))
        self.assertIn('DONE new', result.stdout)
        self.assertEqual(mode, 0o600)
        self.assertFalse(residue)

    def test_no_remaining_lines_is_not_a_read_failure(self):
        result, data, _, _ = self.attempt(original='CHANGE="old"\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(data, 'CHANGE="new"\n')

    def test_create_missing_config(self):
        result, data, mode, residue = self.attempt(original=None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(data, 'CHANGE="new"\n')
        self.assertEqual(mode, 0o600)
        self.assertFalse(residue)

    def test_invalid_arguments_do_not_change_config(self):
        for arguments in ['CHANGE', 'invalid-key value', "CHANGE 'bad$value'"]:
            with self.subTest(arguments=arguments):
                result, data, _, residue = self.attempt(arguments=arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(data, OLD)
                self.assertFalse(residue)


if __name__ == '__main__':
    unittest.main()
