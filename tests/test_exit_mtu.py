"""Inner WG must carry a QUIC Initial without IP fragmentation or DF clearing."""
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'rp.sh').read_text()
PYTHON = SOURCE.split("py_source() { cat <<'RP_PY_EOF'\n", 1)[1].split('\nRP_PY_EOF', 1)[0]
rp = types.ModuleType('rp_generated')
exec(compile(PYTHON, 'rp_generated', 'exec'), rp.__dict__)


class ExitMTU(unittest.TestCase):
    def config(self, mtu=None):
        cfg = dict(EXIT_PRIV1='private1', EXIT_PRIV2='private2', EXIT_PUB1='public1',
                   EXIT_PUB2='public2', EXIT_PSK='fixture')
        if mtu is not None:
            cfg['EXIT_MTU'] = mtu
        return cfg

    def test_defaults_allow_quic_on_both_ends(self):
        for render in [rp.wg_exit_server, rp.wg_exit_client]:
            self.assertIn('MTU = 1280\n', render(self.config()))

    def test_custom_valid_values_preserved_on_both_ends(self):
        for value in ['1228', '1280', '1380', '1420']:
            for render in [rp.wg_exit_server, rp.wg_exit_client]:
                self.assertIn('MTU = ' + value + '\n', render(self.config(value)))

    def test_invalid_and_quic_incompatible_values_rejected(self):
        for value in ['1080', '1227', '0', '-1', '65536', 'junk', '1280\nPostUp = false']:
            for render in [rp.wg_exit_server, rp.wg_exit_client]:
                with self.subTest(value=value, render=render.__name__), self.assertRaises(SystemExit):
                    render(self.config(value))

    def test_factory_migration_preserves_custom_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'functions').write_text(SOURCE.rsplit('main "$@"', 1)[0])
            for before, after in [(None, '1280'), ('1080', '1280'), ('1380', '1380'), ('1060', '1060')]:
                (root / 'rp.conf').write_text('' if before is None else 'EXIT_MTU="' + before + '"\n')
                script = '''source "$TEST_DIR/functions"
ETC=$TEST_DIR; CONF=$ETC/rp.conf
conf_load
conf_exit_mtu_migrate
[[ $(cf EXIT_MTU) == "$EXPECTED" ]]
'''
                r = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                   env=dict(os.environ, TEST_DIR=tmp, EXPECTED=after))
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
