"""Exercise generated console blocks with a harmless installer payload."""
import os
from pathlib import Path
import random
import string
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BlockDelivery(unittest.TestCase):
    def generate(self, exit_code=0, failure='', single=False):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        source = (ROOT / 'rp.sh').read_text().rsplit('main "$@"', 1)[0]
        source = source.replace('/root/.rp', str(self.root / 'received'))
        (self.root / 'functions').write_text(source)
        rng = random.Random(17)
        payload = '#!/bin/bash\n#' + ''.join(rng.choices(string.ascii_letters, k=5000))
        payload += '\ntouch "$TEST_DIR/executed"\nexit ' + str(exit_code) + '\n'
        (self.root / 'payload').write_text(payload)
        script = r'''
source "$TEST_DIR/functions"
STATE=$TEST_DIR
need_vps1() { :; }
cf() { if [[ $1 == BLOCK_MAX ]]; then echo 1800; else echo pinned; fi; }
vps2_files() { [[ $TEST_FAILURE != files ]]; }
vps2_installer() { cat "$TEST_DIR/payload"; [[ $TEST_FAILURE != installer ]]; }
py_source >"$TEST_DIR/rp.py"
py() { if [[ $1 == bundle ]]; then touch "$2/bundle.tgz"; else python3 "$TEST_DIR/rp.py" "$@"; fi; }
block_make "$TEST_DIR/output" ''' + ('single' if single else '')
        self.env = dict(os.environ, TEST_DIR=str(self.root), TEST_FAILURE=failure, RP_ASCII='0')
        return subprocess.run(['bash', '-c', script], env=self.env, text=True, capture_output=True)

    def deliver(self, skip_middle=False):
        parts = sorted((self.root / 'output').glob('part*.sh'))
        self.assertGreater(len(parts), 2)
        for i, part in enumerate(parts):
            if skip_middle and i == 1:
                continue
            result = subprocess.run(['bash', str(part)], env=self.env, text=True, capture_output=True)
            if i != len(parts) - 1:
                self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_multipart_preserves_installer_failure(self):
        self.assertEqual(self.generate(exit_code=7).returncode, 0)
        result = self.deliver()
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertTrue((self.root / 'executed').exists())
        self.assertFalse((self.root / 'received').exists())

    def test_multipart_success_and_private_staging(self):
        self.assertEqual(self.generate().returncode, 0)
        result = self.deliver()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / 'executed').exists())
        self.assertEqual((self.root / 'output').stat().st_mode & 0o777, 0o700)

    def test_missing_part_is_rejected_before_execution(self):
        self.assertEqual(self.generate().returncode, 0)
        result = self.deliver(skip_middle=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'executed').exists())

    def test_generation_failure_is_not_success(self):
        for failure in ['files', 'installer']:
            with self.subTest(failure=failure):
                result = self.generate(failure=failure, single=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('Блок:', result.stdout)


if __name__ == '__main__':
    unittest.main()
