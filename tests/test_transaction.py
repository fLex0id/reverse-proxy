import importlib.util
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch, Mock

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

    def test_confirmation_cannot_cross_deadline_during_live_probe(self):
        meta=dict(phase='READY',deadline=100,sha256='verified')
        with patch.object(tx,'load',return_value=meta), patch.object(tx,'save') as save, \
             patch.object(tx,'validate_results'), patch.object(tx,'digest',return_value='verified'), \
             patch.object(tx.time,'time',side_effect=[99,101]):
            with self.assertRaisesRegex(RuntimeError,'deadline'): tx.confirm()
            save.assert_not_called()
        self.assertEqual(meta['phase'],'READY')

    def test_failed_watch_restore_does_not_publish_terminal_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            state=Path(tmp); meta=dict(phase='ROLLING_BACK',watch_active=True)
            with patch.object(tx,'TX',state), patch.object(tx,'save') as save, \
                 patch.object(tx,'restore_watch',side_effect=RuntimeError('start failed')):
                with self.assertRaisesRegex(RuntimeError,'start failed'): tx.finish_rollback(meta)
                save.assert_not_called()
            self.assertEqual(meta['phase'],'ROLLING_BACK')

    def test_backup_interruption_has_durable_recovery_before_watch_stops(self):
        class AbruptStop(BaseException):
            pass  # Deliberately bypass the normal exception/failure cleanup.
        with tempfile.TemporaryDirectory() as tmp:
            state=Path(tmp); folder=state/'transaction'; folder.mkdir()
            meta=folder/'state.json'; meta.write_text('{"phase":"COMMITTED"}')
            original_exists=Path.exists
            def exists(p):
                return str(p)=='/etc/rp/rp2.conf' or original_exists(p)
            events=[]
            def command(*args,**kwargs):
                events.append(args)
                return Mock(returncode=1 if 'rp-rollback-run.timer' in args else 0)
            with patch.multiple(tx,STATE=state,TX=folder,META=meta,BACKUP=state/'backup.tgz'), \
                 patch.object(Path,'exists',exists), patch.object(tx,'command',command), \
                 patch.object(tx,'arm',lambda m: events.append(('ARM',))), \
                 patch.object(tx,'owned_keys',return_value=[]), \
                 patch.object(tx.tarfile,'open',side_effect=AbruptStop):
                with self.assertRaises(AbruptStop): tx.prepare(os.getpid())
            self.assertIn(('ARM',),events,'backup started before recovery timer was armed')
            self.assertLess(events.index(('ARM',)),events.index(('systemctl','stop','rp-watch')))
            self.assertEqual(json.loads(meta.read_text())['phase'],'PREPARING')

if __name__=='__main__': unittest.main()
