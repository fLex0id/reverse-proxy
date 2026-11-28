"""Failed binary/data writes must stop before reporting installer success."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from rp_fixture import SINGLE

ROOT = Path(__file__).resolve().parents[1]

class InstallerWrites(unittest.TestCase):
    def attempt(self, failure):
        source = SINGLE.read_text()
        body = source.split('  rp_msg "Xray и Hysteria2"\n', 1)[1].split('  # 4. files:', 1)[0]
        script = r'''rp_msg() { :; }
rp_fail() { echo "FAILED: $*" >&2; exit 1; }
rp_dl() { return 0; }
sha256sum() { echo 'fixturehash fixturefile'; }
unzip() { return 0; }
install() {
  case "$TEST_FAILURE:$*" in
    xray-stage:*'/usr/local/bin/xray.new'|hy2-stage:*'/usr/local/bin/hysteria.new'|assets-dir:'-d '*|assets-write:'-m 644 '*) return 1 ;;
  esac
  return 0
}
mv() {
  case "$TEST_FAILURE:$*" in
    xray-publish:*'/usr/local/bin/xray'|hy2-publish:*'/usr/local/bin/hysteria') return 1 ;;
  esac
  return 0
}
tmp=$TEST_DIR; xurl=fixture; hurl=fixture; xsha=fixturehash; hsha=fixturehash
''' + body + '\nprintf completed >"$TEST_DIR/completed"\n'
        with tempfile.TemporaryDirectory() as tmp:
            r = subprocess.run(['bash', '-c', script], text=True, capture_output=True,
                env=dict(os.environ, TEST_DIR=tmp, TEST_FAILURE=failure))
            return r.returncode, (Path(tmp)/'completed').exists()

    def test_successful_writes_continue(self): self.assertEqual(self.attempt(''), (0, True))

    def test_failed_writes_do_not_continue(self):
        for failure in ['xray-stage', 'xray-publish', 'assets-dir', 'assets-write', 'hy2-stage', 'hy2-publish']:
            with self.subTest(failure=failure):
                rc, completed = self.attempt(failure)
                self.assertNotEqual(rc, 0)
                self.assertFalse(completed)

if __name__ == '__main__': unittest.main()
