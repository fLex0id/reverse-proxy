"""Real OpenSSL certificates: reinstall must preserve the peer's pinned identity."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class CertificateIdentity(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        (self.root/'functions').write_text((ROOT/'rp.sh').read_text().rsplit('main "$@"',1)[0])
        self.assertEqual(self.cert().returncode,0)
        self.original={n:(self.root/n).read_bytes() for n in ('hy2.crt','hy2.key','rp.conf')}

    def cert(self):
        script='source "$TEST_DIR/functions"; ETC=$TEST_DIR; CONF=$ETC/rp.conf; conf_load; chown() { :; }; hy2_cert example.com'
        return subprocess.run(['bash','-c',script],capture_output=True,text=True,
                              env=dict(os.environ,TEST_DIR=str(self.root)))

    def test_reinstall_preserves_certificate_key_and_pin(self):
        r=self.cert(); self.assertEqual(r.returncode,0,r.stderr)
        for n,data in self.original.items(): self.assertEqual((self.root/n).read_bytes(),data,n+' changed')

    def test_partial_identity_is_rejected_without_rotation(self):
        (self.root/'hy2.key').unlink()
        self.assertNotEqual(self.cert().returncode,0)
        self.assertEqual((self.root/'hy2.crt').read_bytes(),self.original['hy2.crt'])
        self.assertFalse((self.root/'hy2.key').exists())

    def test_corrupt_key_is_rejected_without_overwriting(self):
        (self.root/'hy2.key').write_text('broken key\n')
        self.assertNotEqual(self.cert().returncode,0)
        self.assertEqual((self.root/'hy2.key').read_text(),'broken key\n')

    def test_wrong_pin_is_rejected(self):
        text=(self.root/'rp.conf').read_text()
        text='\n'.join('HY2_PIN="00"' if line.startswith('HY2_PIN=') else line for line in text.splitlines())+'\n'
        (self.root/'rp.conf').write_text(text)
        self.assertNotEqual(self.cert().returncode,0)
        self.assertEqual((self.root/'rp.conf').read_text(),text)

if __name__=='__main__': unittest.main()
