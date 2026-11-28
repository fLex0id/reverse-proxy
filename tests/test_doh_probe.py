"""A DoH check must validate a complete DNS answer, not a body length."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from rp_fixture import SINGLE

ROOT = Path(__file__).resolve().parents[1]
QUESTION = b'\x07example\x03com\0' + struct.pack('!HH', 1, 1)
ANSWER = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 30, 4) + b'\xc0\x00\x02\x01'
VALID = struct.pack('!6H', 0, 0x8180, 1, 1, 0, 0) + QUESTION + ANSWER

class DoHProbe(unittest.TestCase):
    def run_probe(self, body=VALID, curl_rc=0, content_type='application/dns-message', http='200'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'body').write_bytes(body)
            (root / 'functions').write_text(SINGLE.read_text().rsplit('main "$@"', 1)[0])
            script = '''source "$TEST_DIR/functions"
STATE=$TEST_DIR
sx() {
  local dest="" stats=0
  while (($#)); do
    case $1 in -o) shift; dest=$1 ;; -w) shift; stats=1 ;; esac
    shift
  done
  if [[ -n $dest ]]; then cp "$TEST_DIR/body" "$dest"; else cat "$TEST_DIR/body"; fi
  ((stats==0)) || printf '%s\\n%s\\n0.1\\n' "$TEST_HTTP" "$TEST_TYPE"
  return "$TEST_CURL_RC"
}
doh_test https://resolver.invalid/dns-query
'''
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                env=dict(os.environ, TEST_DIR=tmp, TEST_CURL_RC=str(curl_rc), TEST_TYPE=content_type, TEST_HTTP=http))
            return result.returncode

    def test_valid_answer(self): self.assertEqual(self.run_probe(), 0)
    def test_html_body_is_not_dns(self): self.assertNotEqual(self.run_probe(b'<html>' + b'x'*100 + b'</html>', content_type='text/html'), 0)
    def test_partial_download_is_not_success(self): self.assertNotEqual(self.run_probe(curl_rc=28), 0)
    def test_wrong_content_type(self): self.assertNotEqual(self.run_probe(content_type='text/plain'), 0)
    def test_http_error_is_not_success(self): self.assertNotEqual(self.run_probe(http='500'), 0)
    def test_truncated_answer(self): self.assertNotEqual(self.run_probe(VALID[:-1]), 0)
    def test_wrong_id(self): self.assertNotEqual(self.run_probe(b'\x00\x01' + VALID[2:]), 0)
    def test_error_response(self): self.assertNotEqual(self.run_probe(VALID[:3] + b'\x83' + VALID[4:]), 0)
    def test_missing_answers(self): self.assertNotEqual(self.run_probe(struct.pack('!6H',0,0x8180,1,0,0,0)+QUESTION), 0)

class DNSCommandStatus(unittest.TestCase):
    def run_command(self, servers, generator_rc=0):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'functions'
            path.write_text(SINGLE.read_text().rsplit('main "$@"', 1)[0])
            script = '''source "$TEST_FUNCTIONS"
need_vps1() { :; }
py() { printf '%s\\n' "$TEST_SERVERS"; return "$TEST_GENERATOR_RC"; }
doh_test() { [[ $1 != *bad* ]]; }
cmd_dns test
'''
            return subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                env=dict(os.environ, TEST_FUNCTIONS=str(path), TEST_SERVERS=servers,
                         TEST_GENERATOR_RC=str(generator_rc))).returncode
    def test_all_success(self): self.assertEqual(self.run_command('https://good1 https://good2'), 0)
    def test_one_failed_resolver(self): self.assertNotEqual(self.run_command('https://bad https://good'), 0)
    def test_all_failed_resolvers(self): self.assertNotEqual(self.run_command('https://bad'), 0)
    def test_empty_resolvers(self): self.assertNotEqual(self.run_command(''), 0)
    def test_generator_failure(self): self.assertNotEqual(self.run_command('https://good', 1), 0)

if __name__ == '__main__': unittest.main()
