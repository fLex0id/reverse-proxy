"""Runtime inter-zone policy is distinct from firewalld's intra-zone switch."""
import os
from pathlib import Path
import subprocess
import unittest

from rp_fixture import SINGLE

SOURCE = SINGLE.read_text()
HELPER = 'fw_egress_state() {' + SOURCE.split('fw_egress_state() {', 1)[1].split('\ncmd_egress() {', 1)[0]

class EgressFirewall(unittest.TestCase):
    def state(self, failure='', zone='rp-tunnel', external='public'):
        script = r'''firewall-cmd() {
  case "$*" in
    --info-policy=rp-tunnel-egress)
      [[ $TEST_FAILURE == unavailable ]] && return 36
      if [[ $TEST_FAILURE == inactive ]]; then echo rp-tunnel-egress
      else echo 'rp-tunnel-egress (active)'; fi
      if [[ $TEST_FAILURE == reject ]]; then echo '  target: REJECT'
      else echo '  target: ACCEPT'; fi ;;
    '--policy=rp-tunnel-egress --query-ingress-zone=rp-tunnel')
      [[ $TEST_FAILURE != ingress ]] ;;
    '--policy=rp-tunnel-egress --query-egress-zone=public')
      [[ $TEST_FAILURE == query-error ]] && return 36
      [[ $TEST_FAILURE != egress ]] ;;
    *) return 97 ;;
  esac
}
''' + HELPER + '\nfw_egress_state "$1" "$2"\n'
        return subprocess.check_output(['bash', '-c', script, 'bash', zone, external],
            text=True, env=dict(os.environ, TEST_FAILURE=failure)).strip()

    def test_active_policy_is_valid_without_intra_zone_forward(self):
        self.assertEqual(self.state(), 'yes')

    def test_inactive_rejecting_or_wrong_direction_policy_is_not_valid(self):
        for failure in ['inactive', 'reject', 'ingress', 'egress']:
            with self.subTest(failure=failure): self.assertEqual(self.state(failure), 'no')

    def test_failed_runtime_queries_are_unknown(self):
        for failure in ['unavailable', 'query-error']:
            with self.subTest(failure=failure): self.assertEqual(self.state(failure), 'unknown')

    def test_missing_zone_is_unknown(self): self.assertEqual(self.state(zone=''), 'unknown')
    def test_wrong_ingress_zone_is_rejected(self): self.assertEqual(self.state(zone='public'), 'no')
    def test_same_zone_is_rejected(self): self.assertEqual(self.state(external='rp-tunnel'), 'no')

if __name__ == '__main__': unittest.main()
