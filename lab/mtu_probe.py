#!/usr/bin/env python3
"""Compare actual QUIC over both Hysteria transports at 1080 and 1280 MTU.

Runtime-only changes, independent systemd restore timers, no persisted config edit.
Do not run concurrently with any other lab mutation/fault suite.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
import uuid

p = argparse.ArgumentParser()
for name in ['lab1', 'lab2', 'client', 'output']:
    p.add_argument('--' + name, required=True)
a = p.parse_args()
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=True)
out.chmod(0o700)
records = []

def remote(host, args):
    return subprocess.check_output(['ssh', '-o', 'BatchMode=yes', host, shlex.join(args)], text=True)

try:
    for transport in ['hy2-wg', 'hy2o-wg']:
        (out / (transport + '-pin.log')).write_text(remote(a.lab1, ['rp', 'tunnel', transport]))
        for mtu in [1080, 1280]:
            guards = []
            try:
                for host, interface in [(a.lab1, 'wg-exit'), (a.lab2, 'rp-wg')]:
                    old = json.loads(remote(host, ['ip', '-j', 'link', 'show', interface]))[0]['mtu']
                    unit = 'rp-lab-mtu-restore-' + uuid.uuid4().hex[:10]
                    remote(host, ['systemd-run', '--quiet', '--unit=' + unit, '--on-active=180s',
                                  '/usr/sbin/ip', 'link', 'set', interface, 'mtu', str(old)])
                    guards.append((host, interface, old, unit))
                    remote(host, ['ip', 'link', 'set', interface, 'mtu', str(mtu)])
                target = out / (transport + '-' + str(mtu))
                args = [sys.executable, str(Path(__file__).with_name('application_matrix.py')),
                        '--lab1', a.lab1, '--lab2', a.lab2, '--client', a.client, '--output', str(target)]
                with (out / (target.name + '.log')).open('w') as log:
                    subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=100)
                results = json.loads((target / 'results.json').read_text())
                row = dict(transport=transport, mtu=mtu, applications=results)
                records.append(row)
                (out / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
                print(json.dumps(row), flush=True)
            finally:
                for host, interface, old, unit in reversed(guards):
                    remote(host, ['ip', 'link', 'set', interface, 'mtu', str(old)])
                    remote(host, ['systemctl', 'stop', unit + '.timer'])
finally:
    (out / 'restore-auto.log').write_text(remote(a.lab1, ['rp', 'tunnel', 'auto']))
