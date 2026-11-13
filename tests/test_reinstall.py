"""Run the installer through its configuration/key phase in an isolated fixture."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

class Reinstall(unittest.TestCase):
    def test_existing_client_and_server_keys_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            source=(ROOT/'rp.sh').read_text().rsplit('main "$@"',1)[0]
            Path(d,'functions.sh').write_text(source)
            conf=Path(d,'rp.conf')
            keys='WG_PRIV WG_PUB EXIT_PRIV1 EXIT_PUB1 EXIT_PRIV2 EXIT_PUB2 EXIT_PSK RL_PRIV RL_PUB RL_SID RL_UUID_X RL_UUID_T RL_UUID_PX RL_UUID_PT HY2_PASS'.split()
            conf.write_text('ROLE="vps1"\n'+''.join(k+'="old-'+k+'"\n' for k in keys))
            clients=Path(d,'clients.tsv');clients.write_text('existing-client\tprivate\tpublic\tpsk\t10.66.0.2\n')
            before=clients.read_bytes()
            script=r'''
source "$TEST_DIR/functions.sh"
ETC=$TEST_DIR; CONF=$ETC/rp.conf; CLIENTS=$ETC/clients.tsv
STATE=$TEST_DIR/state; LIB=$TEST_DIR/lib; ASSETS=$STATE/assets; BK_DIR=$STATE/backup
PUBLIC_IP=192.0.2.1; WG_PORT=24566; HY2_MASQ_HOST=example.com; RXH_SNI=example.com; RXH2_SNI=example.net
steps() { :; }
step() { [[ $1 != 'Списки РФ' ]] || exit 77; }
os_check() { :; }; arch_map() { :; }; fw_kind() { echo none; }
run() { :; }; systemctl() { :; }; chown() { :; }
yesno() { [[ $1 == 'Начать установку?' ]]; }
sni_choose() { :; }; py_install() { :; }; ssh_key() { :; }; secrets_extra() { :; }
secrets_wg() { conf_set WG_PRIV REPLACED; }
secrets_reality() { conf_set RL_PRIV REPLACED; }
hy2_cert() { :; }
vps1_install
'''
            r=subprocess.run(['bash','-c',script],env=dict(os.environ,TEST_DIR=d,RP_ASCII='1'),capture_output=True,text=True)
            self.assertEqual(r.returncode,77,r.stdout+r.stderr)
            self.assertEqual(clients.read_bytes(),before,'existing clients were erased')
            text=conf.read_text()
            for k in keys: self.assertIn(k+'="old-'+k+'"',text)

if __name__=='__main__': unittest.main()
