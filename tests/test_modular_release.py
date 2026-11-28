"""Exercise the distribution boundary without changing the host installation."""
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest

from rp_fixture import SINGLE


class ModularRelease(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)
        tools = self.work / 'bin'
        tools.mkdir()
        self.bundle, = SINGLE.parent.glob('rp-*.tar.gz')
        self.env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                        TMPDIR=str(self.work), RP_TEST_BUNDLE=str(self.bundle),
                        RP_TEST_TRACE=str(self.work / 'attempts'))
        curl = tools / 'curl'
        curl.write_text('''#!/usr/bin/env bash
while [[ $1 != -o ]]; do shift; done
out=$2
printf '%s\n' "$4" >>"$RP_TEST_TRACE"
if [[ $4 == https://github.com/* && ${RP_TEST_MIRROR:-0} == 1 ]]; then exit 22; fi
cp "$RP_TEST_BUNDLE" "$out"
''')
        curl.chmod(0o755)
        sleep = tools / 'sleep'
        sleep.write_text('#!/usr/bin/env bash\nexit 0\n')
        sleep.chmod(0o755)

    def bootstrap(self):
        return subprocess.run(
            ['bash', '-c', 'bash <(cat "$1") version', 'test', str(SINGLE.with_name('rp.sh'))],
            text=True, capture_output=True, env=self.env, timeout=10)

    def test_verified_stream_dispatches_and_cleans(self):
        result = self.bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r'^rp \d+\.\d+\.\d+')
        self.assertEqual(list(self.work.glob('rp-bootstrap.*')), [])

    def test_mirror_does_not_bypass_checksum(self):
        corrupted = self.work / 'corrupt'
        corrupted.write_bytes(self.bundle.read_bytes() + b'extra')
        self.env.update(RP_TEST_BUNDLE=str(corrupted), RP_TEST_MIRROR='1',
                        GH_MIRROR='https://mirror.example')
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        attempts = (self.work / 'attempts').read_text().splitlines()
        self.assertEqual(len(attempts), 10)
        self.assertTrue(all(url.startswith('https://mirror.example/https://github.com/')
                            for url in attempts[5:]))
        self.assertEqual(list(self.work.glob('rp-bootstrap.*')), [])

    def test_valid_mirror_runs_after_github_retries(self):
        self.env.update(RP_TEST_MIRROR='1', GH_MIRROR='https://mirror.example')
        result = self.bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rp ', result.stdout)
        self.assertEqual(len((self.work / 'attempts').read_text().splitlines()), 6)
