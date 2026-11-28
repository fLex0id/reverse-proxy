"""Applying or restoring generated WG files must also update the live link MTU."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LiveMTU(unittest.TestCase):
    def test_apply_and_rollback_use_installed_mtu_not_new_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = (ROOT / 'rp.sh').read_text().rsplit('main "$@"', 1)[0]
            source = source.replace('/etc/wireguard/', tmp + '/')
            (root / 'functions').write_text(source)
            script = '''source "$TEST_DIR/functions"
wg() { :; }
wg-quick() { :; }
ip() { [[ $2 != set ]] || printf '%s\n' "$*" >>"$TEST_DIR/ip-calls"; }
CFG[WG_MTU]=1400; CFG[EXIT_MTU]=1400
ACT=([wg0]=1 [wgexit]=1)
vps1_actions
'''
            for mtu in [1280, 1080]:
                for interface in ['wg0', 'wg-exit']:
                    (root / (interface + '.conf')).write_text('[Interface]\nMTU = ' + str(mtu) + '\n')
                (root / 'ip-calls').write_text('')
                r = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                   env=dict(os.environ, TEST_DIR=tmp))
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(set((root / 'ip-calls').read_text().splitlines()),
                                 {'link set dev ' + i + ' mtu ' + str(mtu) for i in ['wg0', 'wg-exit']})


if __name__ == '__main__':
    unittest.main()
