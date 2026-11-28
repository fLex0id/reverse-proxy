"""Excluded transport credentials must not be shipped in a VPS-2 bundle."""
import itertools
from pathlib import Path
import tarfile
import tempfile
import types
import unittest

from rp_fixture import SINGLE

SOURCE = SINGLE.read_text()
PYTHON = SOURCE.split("py_source() { cat <<'RP_PY_EOF'\n", 1)[1].split('\nRP_PY_EOF', 1)[0]
rp = types.ModuleType('rp_generated')
exec(compile(PYTHON, 'rp_generated', 'exec'), rp.__dict__)

class BundleTransports(unittest.TestCase):
    def config(self):
        return dict(PUBLIC_IP='192.0.2.1', RL_PUB='fixture-public', RL_SID='abcd',
            RXH_PORT='443', RXH2_PORT='8443', RXH_SNI='example.org', RXH2_SNI='example.net',
            RL_UUID_X='fixture-stream', RL_UUID_PX='fixture-stream-probe',
            RL_UUID_T='fixture-packet', RL_UUID_PT='fixture-packet-probe',
            HY2_PORT='443', HY2O_PORT='8443', HY2_PASS='fixture-hy-secret',
            HY2O_OBFS='fixture-obfs-secret', HY2_SNI='example.com', HY2_PIN='ab'*32,
            EXIT_PRIV2='fixture-wg-secret', EXIT_PUB1='fixture-wg-public', EXIT_PSK='fixture-psk')

    def bundle(self, cfg):
        with tempfile.TemporaryDirectory() as tmp:
            rp.build_bundle(cfg, tmp, {})
            with tarfile.open(Path(tmp)/'bundle.tgz', 'r:gz') as tf:
                return {m.name:(m.mode,tf.extractfile(m).read()) for m in tf}

    def test_each_transport_subset_has_only_needed_configs_and_secrets(self):
        names = {'hy2-wg':'hy2.yaml', 'hy2o-wg':'hy2o.yaml',
                 'reality-xhttp':'xray-xhttp.json', 'reality-xhttp2':'xray-xhttp2.json'}
        for count in range(1,5):
            for order in itertools.combinations(names,count):
                with self.subTest(order=order):
                    cfg=self.config();cfg['TRANSPORT_ORDER']=' '.join(order)
                    files=self.bundle(cfg)
                    wanted={'etc/rp/rp2.conf'}|{'etc/rp/'+names[t] for t in order}
                    hy=any(t.startswith('hy2') for t in order)
                    if hy:wanted.add('etc/rp/rp-wg.conf')
                    self.assertEqual(set(files),wanted)
                    if hy:self.assertEqual(files['etc/rp/rp-wg.conf'][0],0o600)
                    else:
                        content=b''.join(data for mode,data in files.values())
                        self.assertNotIn(b'fixture-wg-secret',content)
                        self.assertNotIn(b'fixture-hy-secret',content)
                        self.assertNotIn(b'fixture-obfs-secret',content)

    def test_xhttp_only_does_not_require_unused_wireguard_keys(self):
        cfg=self.config();cfg['TRANSPORT_ORDER']='reality-xhttp2 reality-xhttp'
        for key in ['EXIT_PRIV2','EXIT_PUB1','EXIT_PSK']:del cfg[key]
        self.assertNotIn('etc/rp/rp-wg.conf',self.bundle(cfg))

if __name__=='__main__':unittest.main()
