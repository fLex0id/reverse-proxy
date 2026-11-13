import importlib.util
from pathlib import Path
import tarfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('transaction',Path(__file__).resolve().parents[1]/'src/transaction.py')
tx=importlib.util.module_from_spec(spec);spec.loader.exec_module(tx)

class TransactionValidation(unittest.TestCase):
    def member(self,name,kind=tarfile.REGTYPE):
        m=tarfile.TarInfo(name);m.type=kind;return m
    def test_regular_owned_file(self): self.assertTrue(tx.valid_member(self.member('etc/rp/rp2.conf'),['etc/rp']))
    def test_path_traversal(self): self.assertFalse(tx.valid_member(self.member('etc/rp/../../shadow'),['etc/rp']))
    def test_other_host_file(self): self.assertFalse(tx.valid_member(self.member('etc/ssh/sshd_config'),['etc/rp']))
    def test_absolute(self): self.assertFalse(tx.valid_member(self.member('/etc/rp/conf'),['etc/rp']))
    def test_link(self): self.assertFalse(tx.valid_member(self.member('etc/rp/config',tarfile.SYMTYPE),['etc/rp']))
    def test_device(self): self.assertFalse(tx.valid_member(self.member('etc/rp/device',tarfile.CHRTYPE),['etc/rp']))

    def check_results(self,results,rc='0'):
        def read(p,*args,**kw):
            if str(p).endswith('rp2.conf'): return 'TRANSPORT_ORDER="hy2-wg reality-xhttp2"\n'
            if str(p).endswith('results'): return results
            if str(p).endswith('push.rc'): return rc
            raise AssertionError(str(p))
        with patch.object(Path,'read_text',read),patch.object(tx,'command') as cmd:
            tx.validate_results()
            cmd.assert_any_call('/usr/local/bin/rp','_func',timeout=60)
            cmd.assert_any_call('systemctl','is-active','--quiet','rp-watch')
    def test_complete_results(self): self.check_results('hy2-wg=ok\nreality-xhttp2=ok\n')
    def test_missing_results(self):
        with self.assertRaises(RuntimeError): self.check_results('hy2-wg=ok\n')
    def test_failed_results(self):
        with self.assertRaises(RuntimeError): self.check_results('hy2-wg=fail:t3\nreality-xhttp2=ok\n')
    def test_failed_install(self):
        with self.assertRaises(RuntimeError): self.check_results('hy2-wg=ok\nreality-xhttp2=ok\n','1')
    def test_duplicate_results(self):
        with self.assertRaises(RuntimeError): self.check_results('hy2-wg=ok\nhy2-wg=ok\nreality-xhttp2=ok\n')

if __name__=='__main__': unittest.main()
