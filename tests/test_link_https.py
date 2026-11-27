"""Real local TLS requests to the one-use installer delivery service."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LinkHTTPS(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = (ROOT / 'rp.sh').read_text()
        embedded = source.split("py_source() { cat <<'RP_PY_EOF'\n", 1)[1].split('\nRP_PY_EOF', 1)[0]
        (self.root / 'server.py').write_text(embedded)
        self.body = b'#!/bin/bash\necho fixture-only\n'
        (self.root / 'block.sh').write_bytes(self.body)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt',
                        'ec_paramgen_curve:prime256v1', '-nodes', '-days', '1',
                        '-subj', '/CN=127.0.0.1', '-keyout', str(self.root / 'key.pem'),
                        '-out', str(self.root / 'crt.pem')], check=True, capture_output=True)
        public = subprocess.check_output(['openssl', 'x509', '-in', str(self.root / 'crt.pem'), '-pubkey', '-noout'])
        der = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'der'], input=public,
                             capture_output=True, check=True).stdout
        import base64
        import hashlib
        self.pin = 'sha256//' + base64.b64encode(hashlib.sha256(der).digest()).decode()
        self.token = os.urandom(12).hex()

    def start(self, ttl=8):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        self.process = subprocess.Popen(['python3', str(self.root / 'server.py'), 'serve',
            str(self.port), self.token, str(self.root / 'block.sh'), str(self.root / 'crt.pem'),
            str(self.root / 'key.pem'), str(ttl)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(('127.0.0.1', self.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.02)
        self.fail('local HTTPS listener did not start')

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=5)

    def request(self, token=None, pin=None):
        return subprocess.run(['curl', '--noproxy', '*', '-fsSk', '--max-time', '3',
            '--pinnedpubkey', pin or self.pin,
            f'https://127.0.0.1:{self.port}/{token or self.token}'], capture_output=True)

    def test_wrong_pin_and_token_do_not_consume_valid_link(self):
        self.start()
        self.assertEqual(self.request(pin='sha256//' + 'A' * 43 + '=').returncode, 90)
        self.assertEqual(self.request(token='wrong-fixture').returncode, 22)
        good = self.request()
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(good.stdout, self.body)
        self.assertNotEqual(self.request().returncode, 0)
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.assertEqual((self.root / 'result').read_text(), 'ok\n')
        self.assertFalse((self.root / 'key.pem').exists())
        self.assertFalse((self.root / 'block.sh').exists())

    def test_simultaneous_download_has_one_winner(self):
        self.start()
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.request(), range(4)))
        self.assertEqual(sum(r.returncode == 0 for r in results), 1)
        self.assertEqual([r.stdout for r in results if r.returncode == 0], [self.body])
        self.assertEqual(self.process.wait(timeout=5), 0)

    def test_expired_link_does_not_serve_during_shutdown_grace(self):
        self.start(ttl=1)
        time.sleep(1.15)
        self.assertNotEqual(self.request().returncode, 0)
        self.assertEqual(self.process.wait(timeout=5), 3)
        self.assertEqual((self.root / 'result').read_text(), 'timeout\n')
        self.assertFalse((self.root / 'key.pem').exists())
        self.assertFalse((self.root / 'block.sh').exists())


if __name__ == '__main__':
    unittest.main()
