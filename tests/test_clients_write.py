"""Client changes must preserve the old list on publication/apply failures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OLD = 'old\tprivate-fixture\tpub-old\tpsk-fixture\t10.77.0.2\n'


class ClientWrites(unittest.TestCase):
    def run_case(self, command, injection=''):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        source = (ROOT / 'rp.sh').read_text()
        body = source.split('client_names() {', 1)[1].split('# ── Блок для VPS-2', 1)[0]
        body = 'client_names() {' + body.replace('/root/rp-clients', str(self.root / 'export'))
        self.clients = self.root / 'clients.tsv'
        self.clients.write_text(OLD)
        self.clients.chmod(0o600)
        script = r'''
set -uo pipefail
need_vps1() { :; }; ask() { :; }
err() { echo "ERROR: $*"; }; warn() { echo "WARN: $*"; }
ok() { echo "OK: $*"; }; note() { echo "NOTE: $*"; }
die() { err "$*"; exit 1; }
wg_pair() { echo 'private-new pub-new'; }
wg() { if [[ $1 == genpsk ]]; then echo psk-new; else cat "$TEST_DIR/peers"; fi; }
py() { case "$1" in next-ip) echo 10.77.0.3;; client) echo client-fixture;; qr) return 1;; esac; }
vps1_apply() { awk -F '\t' '{print $3}' "$CLIENTS" >"$TEST_DIR/peers"; }
''' + body + '\n' + injection + '\n' + command + '\n'
        return subprocess.run(['bash', '-c', script], text=True, capture_output=True,
                              env=dict(os.environ, TEST_DIR=str(self.root),
                                       CLIENTS=str(self.clients), STATE=str(self.root)))

    def test_delete_read_failure_does_not_erase_clients_or_succeed(self):
        # Both the legacy grep filter and the new awk filter fail on source IO.
        result = self.run_case('cl_del old', r'''
grep() { if [[ $1 == -v ]]; then return 2; else command grep "$@"; fi; }
awk() { if [[ "$*" == *'$1!=n'* ]]; then return 2; else command awk "$@"; fi; }
''')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.clients.read_text(), OLD)

    def test_show_write_failure_is_not_success(self):
        result = self.run_case('cl_show old', 'install() { return 1; }')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('Файл:', result.stdout)

    def test_delete_apply_failure_restores_list(self):
        result = self.run_case('cl_del old', 'vps1_apply() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.clients.read_text(), OLD)

    def test_add_apply_failure_restores_list(self):
        result = self.run_case('cl_add new', 'vps1_apply() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.clients.read_text(), OLD)

    def test_delete_last_client(self):
        result = self.run_case('cl_del old')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.clients.read_text(), '')
        self.assertEqual(self.clients.stat().st_mode & 0o777, 0o600)

    def test_add_and_export(self):
        result = self.run_case('cl_add new')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.clients.read_text().startswith(OLD))
        self.assertIn('new\tprivate-new\tpub-new\tpsk-new\t10.77.0.3', self.clients.read_text())
        export = self.root / 'export/new.conf'
        self.assertEqual(export.stat().st_mode & 0o777, 0o600)

    def test_failed_restore_keeps_private_backup_and_reports_failure(self):
        result = self.run_case('cl_del old', r'''
vps1_apply() { return 1; }
mv() { if [[ "$*" == *rollback* || "$*" == *clients.tsv.bak* ]]; then return 1; else command mv "$@"; fi; }
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('список клиентов восстановлен', result.stdout)
        backups = list(self.root.glob('.clients.rollback.*'))
        self.assertEqual(len(backups), 1, result.stdout + result.stderr)
        self.assertEqual(backups[0].read_text(), OLD)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)

    def test_failed_publication_preserves_original(self):
        for command in ['cl_add new', 'cl_del old']:
            with self.subTest(command=command):
                result = self.run_case(command, 'mv() { return 1; }')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.clients.read_text(), OLD)
                self.assertFalse(list(self.root.glob('.clients.*')))

    def test_partial_append_never_replaces_original(self):
        result = self.run_case('cl_add new', r'''
printf() {
  if [[ $1 == '%s\t%s\t%s\t%s\t%s\n' ]]; then builtin printf partial; return 1; fi
  builtin printf "$@"
}
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.clients.read_text(), OLD)
        self.assertFalse(list(self.root.glob('.clients.*')))

    def test_unconfirmed_live_addition_restores_list(self):
        result = self.run_case('cl_add new', 'wg() { [[ $1 != genpsk ]] || echo psk-new; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.clients.read_text(), OLD)

    def test_unconfirmed_live_removal_restores_list(self):
        result = self.run_case('cl_del old', 'wg() { echo pub-old; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.clients.read_text(), OLD)


if __name__ == '__main__':
    unittest.main()
