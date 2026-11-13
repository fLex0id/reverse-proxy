"""Generate Hysteria listeners without occupying transparent-proxy destination ports."""
import json
from pathlib import Path
import subprocess
import types
import unittest
from unittest.mock import patch

SOURCE=(Path(__file__).resolve().parents[1]/'rp.sh').read_text()
PYTHON=SOURCE.split("py_source() { cat <<'RP_PY_EOF'\n",1)[1].split('\nRP_PY_EOF',1)[0]
rp=types.ModuleType('rp_generated');exec(compile(PYTHON,'rp_generated','exec'),rp.__dict__)

class HysteriaBind(unittest.TestCase):
    def render(self,public='192.0.2.10',bind=None,local='192.0.2.10',interface='ens18',route=True):
        cfg=dict(PUBLIC_IP=public,HY2_PORT='443',HY2O_PORT='8443',HY2_PASS='fixture',
                 HY2O_OBFS='fixture-obfs',HY2_MASQ='https://example.com')
        if bind is not None:cfg['HY2_BIND_IP']=bind
        def output(args,**kwargs):
            if 'address' in args:
                return json.dumps([{'ifname':interface,'addr_info':[{'family':'inet','local':local}]}])
            if not route:raise subprocess.CalledProcessError(2,args)
            return json.dumps([{'prefsrc':local}])
        with patch('subprocess.check_output',output):
            return rp.hy2_server(cfg),rp.hy2_server(cfg,True)

    def test_public_address_listener_is_specific(self):
        first,second=self.render()
        self.assertTrue(first.startswith('listen: 192.0.2.10:443\n'))
        self.assertTrue(second.startswith('listen: 192.0.2.10:8443\n'))
    def test_nat_uses_assigned_local_source(self):
        self.assertTrue(self.render(public='203.0.113.8',local='192.168.10.5')[0].startswith('listen: 192.168.10.5:443\n'))
    def test_explicit_address_is_supported(self):
        self.assertTrue(self.render(bind='192.0.2.10',route=False)[0].startswith('listen: 192.0.2.10:443\n'))
    def test_wildcard_is_rejected(self):
        with self.assertRaises(SystemExit):self.render(bind='0.0.0.0')
    def test_unassigned_address_is_rejected(self):
        with self.assertRaises(SystemExit):self.render(bind='192.0.2.11')
    def test_no_route_does_not_fall_back_to_wildcard(self):
        with self.assertRaises(SystemExit):self.render(public='203.0.113.8',route=False)
    def test_internal_wireguard_address_is_rejected(self):
        with self.assertRaises(SystemExit):self.render(interface='wg-exit')

if __name__=='__main__':unittest.main()
