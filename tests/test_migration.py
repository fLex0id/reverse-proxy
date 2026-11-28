"""State restoration and failure semantics of the standalone VPS-1 supervisor."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / 'src/py/migration.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Migration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.tx = self.root / 'var/lib/rp/migration'
        self.tx.mkdir(parents=True, mode=0o700)
        for name, value in [('ROOT', self.root), ('TX', self.tx)]:
            p = patch.object(m, name, value)
            p.start()
            self.addCleanup(p.stop)

    def write(self, rel, data):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data)
        p.chmod(0o600)
        return p

    def units(self):
        return {u: dict(LoadState='loaded', ActiveState='inactive', UnitFileState='disabled') for u in m.UNITS}

    def test_archive_restores_all_owned_files_and_absence_preserving_neighbors(self):
        paths = ['etc/rp/rp.conf', 'etc/rp/clients.tsv', 'usr/local/lib/rp/rp.py',
                 'usr/local/bin/rp', 'etc/wireguard/wg0.conf',
                 'etc/systemd/system/rp-net.service', 'var/lib/rp/route-target',
                 'var/lib/rp/assets/geosite.dat']
        for path in paths:
            self.write(path, 'old-' + path)
        neighbor = self.write('etc/systemd/system/unrelated.service', 'unrelated')
        dropin = self.write('etc/systemd/system/wg-quick@wg0.service.d/operator.conf', 'operator')
        old_umask = os.umask(0o077)
        try:
            checksum = m.archive()
        finally:
            os.umask(old_umask)
        self.assertEqual((self.tx / 'backup.tgz').stat().st_mode & 0o777, 0o600)
        for path in paths:
            self.write(path, 'changed')
        self.write('etc/rp/new-config', 'new')
        self.write('usr/local/bin/hysteria.new', 'new-staging')
        with patch.object(m, 'command'):
            m.restore_files({'sha256': checksum})
        for path in paths:
            self.assertEqual((self.root / path).read_text(), 'old-' + path)
            self.assertEqual((self.root / path).stat().st_mode & 0o777, 0o600)
        self.assertEqual(neighbor.read_text(), 'unrelated')
        self.assertEqual(dropin.read_text(), 'operator')
        self.assertFalse((self.root / 'etc/rp/new-config').exists())
        self.assertFalse((self.root / 'usr/local/bin/hysteria.new').exists())

    def test_corrupt_archive_never_stops_services_or_deletes_files(self):
        conf = self.write('etc/rp/rp.conf', 'old')
        checksum = m.archive()
        (self.tx / 'backup.tgz').write_bytes(b'corrupt')
        with patch.object(m, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'checksum'):
                m.rollback(dict(phase='MIGRATING', sha256=checksum))
            command.assert_not_called()
        self.assertEqual(conf.read_text(), 'old')

    def test_backup_rejects_symlinks_before_mutation(self):
        conf = self.write('etc/rp/rp.conf', 'old')
        conf.with_name('link').symlink_to('/etc/shadow')
        with self.assertRaisesRegex(RuntimeError, 'unsupported'):
            m.archive()
        self.assertEqual(conf.read_text(), 'old')

    def test_archive_members_are_scoped_and_not_links(self):
        for name, kind, expected in [('etc/rp/rp.conf', tarfile.REGTYPE, True),
                                     ('etc/rp/../../shadow', tarfile.REGTYPE, False),
                                     ('etc/ssh/sshd_config', tarfile.REGTYPE, False),
                                     ('/etc/rp/rp.conf', tarfile.REGTYPE, False),
                                     ('etc/rp/key', tarfile.SYMTYPE, False),
                                     ('etc/rp/key', tarfile.LNKTYPE, False),
                                     ('etc/rp/dev', tarfile.CHRTYPE, False)]:
            with self.subTest(name=name, kind=kind):
                member = tarfile.TarInfo(name)
                member.type = kind
                self.assertEqual(m.valid_member(member), expected)

    def test_preparing_never_extracts_incomplete_archive(self):
        meta = dict(phase='PREPARING', units=self.units())
        with patch.object(m, 'restore_files') as files, patch.object(m, 'disarm'), \
                patch.object(m, 'command'):
            m.rollback(meta)
        files.assert_not_called()
        self.assertEqual(m.load()['phase'], 'ROLLED_BACK')

    def test_failed_restore_does_not_publish_terminal_success(self):
        meta = dict(phase='MIGRATING', units=self.units())
        response = subprocess.CompletedProcess([], 3, '', '')
        with patch.object(m, 'verify_archive'), patch.object(m, 'command', return_value=response), \
                patch.object(m, 'restore_files', side_effect=OSError('disk failed')), \
                patch.object(m, 'disarm') as disarm:
            with self.assertRaises(OSError):
                m.rollback(meta)
            disarm.assert_not_called()
        self.assertEqual(m.load()['phase'], 'ROLLING_BACK')

    def test_failed_terminal_write_is_not_treated_as_committed(self):
        meta = dict(phase='MIGRATING')
        with patch.object(m, 'save', side_effect=OSError('disk failed')), patch.object(m, 'disarm') as disarm:
            with self.assertRaises(OSError):
                m.finish(meta, 'COMMITTED')
            disarm.assert_not_called()
        self.assertEqual(meta['phase'], 'MIGRATING')

    def test_managed_data_must_be_flushed_before_terminal_marker(self):
        meta = dict(phase='MIGRATING')
        with patch.object(m, 'sync_owned', side_effect=OSError('fsync failed')), \
                patch.object(m, 'save') as save, patch.object(m, 'disarm') as disarm:
            with self.assertRaises(OSError):
                m.finish(meta, 'COMMITTED')
            save.assert_not_called()
            disarm.assert_not_called()
        self.assertEqual(meta['phase'], 'MIGRATING')

    def test_guard_rejects_pending_operation_and_missing_internal_token(self):
        m.save(dict(phase='MIGRATING', token='private-fixture-value'))
        with patch.object(m, 'own_lock'), patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                m.guard()
            with self.assertRaises(RuntimeError):
                m.guard(internal=True)
        with patch.object(m, 'own_lock'), patch.dict(os.environ, RP_MIGRATION_TOKEN='private-fixture-value'):
            m.guard(internal=True)
        m.save(dict(phase='ROLLED_BACK'))
        with patch.object(m, 'own_lock'):
            m.guard()
            with self.assertRaises(RuntimeError):
                m.guard(internal=True)

    def test_runtime_restore_scopes_firewall_and_routes(self):
        runtime = dict(firewall=[dict(zone='public', permanent=False, port='8443/tcp', present=True)],
                       nft={f + ' ' + t: '' for f, t in m.TABLES},
                       routes={'100': 'local default dev lo scope host\n', '200': 'prohibit default metric 1000\n'},
                       rules=['90: from all fwmark 0x1 lookup 100'],
                       sysctls={'net.ipv4.conf.all.rp_filter': '2'})
        def call(*args, **kwargs):
            if args[:4] == ('ip', '-4', 'rule', 'show'):
                return subprocess.CompletedProcess(args, 0, '90: from all fwmark 0x1 lookup 100\n123: from 192.0.2.1 lookup 555\n', '')
            return subprocess.CompletedProcess(args, 1 if args[0] in ('nft', 'firewall-cmd') else 0, '', '')
        with patch.object(m, 'command', side_effect=call) as command:
            m.restore_runtime(runtime)
        calls = [c.args for c in command.call_args_list]
        self.assertNotIn(('firewall-cmd', '--reload'), calls)
        self.assertFalse(any('555' in c for c in calls))
        self.assertIn(('firewall-cmd', '--zone=public', '--add-port=8443/tcp'), calls)
        self.assertIn(('ip', '-4', 'rule', 'del', 'pref', '90', 'from', 'all', 'fwmark', '0x1', 'lookup', '100'), calls)

    def test_rule_ownership_uses_exact_selectors_and_priorities(self):
        self.assertTrue(m.owned_rule('90: from all fwmark 0x1 lookup 100'))
        self.assertTrue(m.owned_rule('100: from all fwmark 0xff lookup 200'))
        self.assertTrue(m.owned_rule('101: from 10.77.0.1/32 lookup 200'))
        for line in ['90: from all fwmark 0x1 lookup 1000',
                     '101: from 10.77.0.10 lookup 200',
                     '101: from 10.77.0.1/24 lookup 200',
                     '999: from all fwmark 0x1 lookup 100',
                     '90: from 192.0.2.1 fwmark 0x1 lookup 100']:
            with self.subTest(line=line):
                self.assertFalse(m.owned_rule(line))

    def test_recovery_leaves_live_owner_before_deadline(self):
        m.save(dict(phase='MIGRATING', boot_id='boot', owner=123, owner_start='start', deadline=200))
        with patch.object(m, 'boot_id', return_value='boot'), patch.object(m, 'pid_start', return_value='start'), \
                patch.object(m.time, 'time', return_value=100), patch.object(m, 'stop_child') as stop:
            m.recover()
            stop.assert_not_called()

    def test_recovery_never_signals_pid_reused_on_another_boot(self):
        with patch.object(m, 'boot_id', return_value='new'), patch.object(m.os, 'killpg') as kill:
            m.stop_child(dict(boot_id='old', child_pid=123, child_start='start'))
            kill.assert_not_called()

    def test_deadline_does_not_kill_an_active_rollback(self):
        m.save(dict(phase='ROLLING_BACK', boot_id='boot', owner=123, owner_start='start', deadline=100))
        with patch.object(m, 'boot_id', return_value='boot'), patch.object(m, 'pid_start', return_value='start'), \
                patch.object(m.time, 'time', return_value=200), patch.object(m, 'stop_child') as stop:
            m.recover()
            stop.assert_not_called()

    def test_private_metadata_publication(self):
        m.save(dict(phase='PREPARING', token='fixture'))
        self.assertEqual((self.tx / 'state.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((self.tx / 'state.json').read_text())['phase'], 'PREPARING')


if __name__ == '__main__':
    unittest.main()
