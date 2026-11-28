"""Use actual processes/flock to check update handover and rollback exclusion."""
import os
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UpdateLock(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lock = self.root / 'rp.lock'
        self.functions = self.root / 'functions'
        self.functions.write_text((ROOT / 'rp.sh').read_text().rsplit('main "$@"', 1)[0]
                                  .replace('/run/rp.lock', str(self.lock)))
        self.env = dict(os.environ, TEST_DIR=str(self.root), RP_ASCII='1')

    def run_shell(self, script):
        return subprocess.run(['bash', '-c', 'source "$TEST_DIR/functions"\n' + script],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def test_child_reuses_lock_and_parent_retains_it(self):
        result = self.run_shell(r'''
lock
bash -c 'source "$TEST_DIR/functions"; lock; echo CHILD_LOCKED' || exit 31
flock -n "$TEST_DIR/rp.lock" true && exit 32
printf 'PARENT_LOCKED\n'
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('CHILD_LOCKED\nPARENT_LOCKED', result.stdout)

    def test_unrelated_descriptor_is_not_accepted(self):
        result = self.run_shell(r'''
exec 9>"$TEST_DIR/unrelated"
flock 9
lock
flock -n "$TEST_DIR/rp.lock" true && exit 33
printf 'LOCKED\n'
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('LOCKED', result.stdout)

    def test_matching_but_unlocked_descriptor_is_acquired(self):
        result = self.run_shell(r'''
exec 9>"$TEST_DIR/rp.lock"
lock
flock -n "$TEST_DIR/rp.lock" true && exit 34
printf 'LOCKED\n'
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def pending_migration(self):
        tx = self.root / 'state/migration'
        tx.mkdir(parents=True)
        helper = (ROOT / 'src/migration.py').read_text()
        helper = helper.replace('/run/rp.lock', str(self.lock)).replace('/var/lib/rp/migration', str(tx))
        (tx / 'runner.py').write_text(helper)
        (tx / 'state.json').write_text(json.dumps(dict(phase='MIGRATING', token='fixture')))

    def test_cli_rejects_pending_migration_even_after_owner_lock_is_gone(self):
        self.pending_migration()
        result = self.run_shell('STATE=$TEST_DIR/state\nlock\nprintf UNEXPECTED\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('UNEXPECTED', result.stdout)

    def test_route_timer_defers_pending_migration(self):
        self.pending_migration()
        result = self.run_shell(r'''
STATE=$TEST_DIR/state; CFG[ROLE]=vps1
vps2_read() { touch "$TEST_DIR/network-called"; }
route_sync
[[ ! -f $TEST_DIR/network-called ]]
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_update_rejects_candidate_without_transaction_before_installation(self):
        (self.root / 'rp').write_text('old executable\n')
        (self.root / 'candidate').write_text('#!/bin/bash\nSELF_VERSION="1.2.9"\ntouch "$TEST_DIR/invoked"\n')
        result = self.run_shell(r'''
SELF_BIN=$TEST_DIR/rp; STATE=$TEST_DIR/state; BK_DIR=$STATE/backup
need_vps1() { :; }; yesno() { return 0; }; self_ok() { return 0; }
self_fetch() { cp "$TEST_DIR/candidate" "$1"; }
migration_run() { touch "$TEST_DIR/invoked"; }
lock
self_upgrade
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'invoked').exists())
        self.assertEqual((self.root / 'rp').read_text(), 'old executable\n')

    def test_update_holds_lock_before_child_lock_and_through_failed_migration(self):
        # The candidate pauses BEFORE acquiring its lock, exposing the old
        # unlock/reacquire gap deterministically, without touching host services.
        original = self.root / 'rp'
        original.write_text('old executable\n')
        (self.root / 'candidate').write_text('''#!/usr/bin/env bash
SELF_VERSION="1.2.9-lab.99"
source "$TEST_DIR/functions"
migrate_apply() {
  :
}
touch "$TEST_DIR/child-ready"
while [[ ! -f $TEST_DIR/continue ]]; do sleep 0.02; done
lock
echo CHILD_LOCKED
exit 23
''')
        script = r'''
source "$TEST_DIR/functions"
SELF_BIN=$TEST_DIR/rp; STATE=$TEST_DIR/state; BK_DIR=$STATE/backup
need_vps1() { :; }
migration_run() { echo OLD_HELPER_CALLED; return 99; }
self_fetch() { cp "$TEST_DIR/candidate" "$1"; }
self_ok() { bash -n "$1"; }
yesno() { return 0; }
lock
self_upgrade
rc=$?
flock -n "$TEST_DIR/rp.lock" true && exit 35
exit "$rc"
'''
        process = subprocess.Popen(['bash', '-c', script], env=self.env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'child-ready').exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    self.fail('candidate never reached handover')
                time.sleep(0.02)
            probe = subprocess.run(['flock', '-n', str(self.lock), 'true'], check=False)
            self.assertNotEqual(probe.returncode, 0, 'update released lock before migration')
            (self.root / 'continue').touch()
            out, err = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 1, out + err)
            self.assertIn('CHILD_LOCKED', out)
            self.assertNotIn('OLD_HELPER_CALLED', out)
            self.assertEqual(original.read_text(), 'old executable\n')
            self.assertEqual(subprocess.run(['flock', '-n', str(self.lock), 'true']).returncode, 0)
        finally:
            (self.root / 'continue').touch()
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)


if __name__ == '__main__':
    unittest.main()
