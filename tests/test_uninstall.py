"""Exercise real removal functions against a filesystem fixture and service doubles."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UninstallOwnership(unittest.TestCase):
    def check_role(self, role, pending_link=False, close_failure=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = (ROOT / 'rp.sh').read_text()
            name = 'cmd_uninstall' if role == 1 else 'cmd_remove'
            body = source.split(name + '() {\n', 1)[1].split('\n}\n', 1)[0]
            body = re.sub(r'/(etc|usr|var|root)/', str(root) + r'/\1/', body)
            units = root / 'etc/systemd/system'
            units.mkdir(parents=True)
            owned = units / ('rp-xray.service' if role == 1 else 'rp-watch.service')
            other = units / 'rp-unrelated.service'
            other.write_text('unrelated unit\n')
            owned.write_text('rp unit\n')
            other_dropin = units / 'wg-quick@wg0.service.d/operator.conf'
            other_dropin.parent.mkdir()
            other_dropin.write_text('unrelated override\n')
            own_dropin = other_dropin.with_name('rp.conf')
            own_dropin.write_text('rp network dependency\n')
            for path in ['etc/rp', 'var/lib/rp', 'usr/local/lib/rp', 'root/.ssh']:
                (root / path).mkdir(parents=True)
            if pending_link:
                (root / 'var/lib/rp/link.firewall').write_text('19444/tcp\n')
                (root / 'var/lib/rp/serve').mkdir()
                (root / 'var/lib/rp/serve/block.sh').write_text('fixture-only\n')
            helper = root / 'usr/local/lib/rp/transaction.py'
            helper.write_text('owned helper\n')
            key = root / 'root/.ssh/authorized_keys'
            key.write_text('preserve-other-key\nremove rp@vps1\n')
            log = root / 'calls'
            script = '''
set -uo pipefail
systemctl() { echo "systemctl $*" >>"$CALLS"; [[ $1 != is-active ]]; }
nft() { :; }; ip() { return 1; }; tr_stop_all() { :; }
need_vps1() { :; }; yesno() { return 0; }; fw_close() { echo "fw_close $*" >>"$CALLS"; }
cf() { if [[ $1 == LINK_PORT ]]; then echo 8444; else echo 12345; fi; }
say() { :; }; ok() { :; }; err() { echo "$*"; }
firewall-cmd() { echo "firewall-cmd $*" >>"$CALLS"; [[ $CLOSE_FAILURE != 1 ]]; }
'''
            if role == 1:
                script += 'link_close() {' + source.split('link_close() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
            script += name + '() {\n' + body + '\n}\n' + name + '\n'
            result = subprocess.run(['bash', '-c', script], input='y\n', text=True,
                                    capture_output=True, env=dict(os.environ,
                                    ETC=str(root/'etc/rp'), STATE=str(root/'var/lib/rp'),
                                    LIB=str(root/'usr/local/lib/rp'), CALLS=str(log),
                                    CLOSE_FAILURE='1' if close_failure else '0'))
            if close_failure:
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(owned.exists())
                self.assertTrue((root / 'var/lib/rp/link.firewall').exists())
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(other.exists(), 'unrelated rp-prefixed unit was deleted')
            self.assertEqual(other_dropin.read_text(), 'unrelated override\n')
            self.assertFalse(owned.exists(), 'owned unit remains')
            if role == 1:
                self.assertFalse(own_dropin.exists(), 'owned network dependency remains')
                self.assertNotIn('fw_close 8444/tcp', log.read_text())
                if pending_link:
                    self.assertIn('firewall-cmd --remove-port=19444/tcp', log.read_text())
            else:
                self.assertFalse(helper.exists(), 'transaction helper remains after removal')
                self.assertEqual(key.read_text(), 'preserve-other-key\n')
                self.assertIn('rp-transaction-recover.service', log.read_text())
                self.assertIn('rp-transaction-rollback.timer', log.read_text())

    def test_vps1_preserves_unrelated_units_and_wireguard_overrides(self):
        self.check_role(1)

    def test_vps2_preserves_unrelated_units_and_removes_transaction_helpers(self):
        self.check_role(2)

    def test_vps1_removes_owned_link_rule_before_state(self):
        self.check_role(1, pending_link=True)

    def test_failed_link_cleanup_keeps_state_for_retry(self):
        self.check_role(1, pending_link=True, close_failure=True)


if __name__ == '__main__':
    unittest.main()
