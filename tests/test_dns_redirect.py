"""DNS interception must preserve reply identity without an external listener."""
import json
from pathlib import Path
import types
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'rp.sh').read_text()
PYTHON = SOURCE.split("py_source() { cat <<'RP_PY_EOF'\n", 1)[1].split('\nRP_PY_EOF', 1)[0]
rp = types.ModuleType('rp_generated')
exec(compile(PYTHON, 'rp_generated', 'exec'), rp.__dict__)


class DNSRedirect(unittest.TestCase):
    def config(self):
        return json.loads(rp.xray_server(dict(TRANSPORT_ORDER='hy2-wg', SOCKS_USER='fixture',
            SOCKS_PASS='fixture', ETC='/nonexistent-rp-fixture', RU_DIRECT='1')))

    def test_redirect_uses_normal_socket_with_terminal_dns_policy(self):
        cfg = self.config()
        inbound = next(x for x in cfg['inbounds'] if x['tag'] == 'dns-hijack')
        self.assertEqual(inbound['settings']['network'], 'tcp,udp')
        self.assertFalse(inbound['settings'].get('followRedirect', False))
        self.assertNotIn('streamSettings', inbound)
        rules = [r for r in cfg['routing']['rules'] if 'dns-hijack' in r.get('inboundTag', [])]
        self.assertEqual([r['outboundTag'] for r in rules], ['dns-out'])
        outbound = next(x for x in cfg['outbounds'] if x['tag'] == 'dns-out')
        self.assertEqual([r['action'] for r in outbound['settings']['rules']], ['drop', 'hijack', 'drop'])

    def test_redirect_is_wg_only_and_does_not_bypass_kill_switch(self):
        nft = rp.nft_rules({})
        bypass = 'iifname "wg0" meta l4proto { tcp, udp } th dport 53 return'
        self.assertLess(nft.index(bypass), nft.index('meta l4proto udp tproxy'))
        self.assertIn('iifname "wg0" meta l4proto { tcp, udp } th dport 53 redirect to :14206', nft)
        self.assertIn('iifname != "wg0" iifname != "lo" meta l4proto { tcp, udp } th dport 14206 drop', nft)
        self.assertIn('iifname "wg0" counter drop', nft)
        self.assertIn('oifname "wg0" counter drop', nft)

    def test_ru_dns_never_becomes_foreign_fallback(self):
        cfg = self.config()
        ru = next(s for s in cfg['dns']['servers'] if s['address'] == '77.88.8.8')
        self.assertTrue(ru['skipFallback'])
        self.assertTrue(ru['finalQuery'])
        self.assertTrue(ru['domains'])
        self.assertTrue(cfg['dns']['servers'][-1]['address'].startswith('https://'))
        self.assertEqual(cfg['outbounds'][0]['protocol'], 'blackhole')


if __name__ == '__main__':
    unittest.main()
