#!/usr/bin/env python3
"""LAB-1 prototype: conntrack-backed DNS redirect; always restore on exit/timer.

Run directly on LAB-1 after other fault/regression suites finish. Keeps the
existing Xray DNS policy and general UDP forwarding; no global cone toggle.
"""
import json
from pathlib import Path
import subprocess
import time
import uuid

root = Path('/root/rp-lab/dns-redirect-' + uuid.uuid4().hex[:8])
root.mkdir(mode=0o700)
paths = [Path('/etc/rp/xray.json'), Path('/etc/rp/rp.nft')]
if any(x['tag'] == 'dns-hijack' for x in json.loads(paths[0].read_text())['inbounds']):
    raise SystemExit('Use a pre-fix candidate: this installation already has DNS redirect')
for path in paths:
    subprocess.run(['cp', '-p', str(path), str(root / path.name)], check=True)
restore = root / 'restore.sh'
restore.write_text('#!/bin/bash\nset -e\n' + ''.join(
    'cp -p ' + str(root / path.name) + ' ' + str(path) + '\n' for path in paths) +
    'restorecon /etc/rp/xray.json /etc/rp/rp.nft\n'
    'systemctl restart rp-net rp-xray\n'
    'rp tunnel sync\n')
restore.chmod(0o700)
unit = 'rp-lab-dns-restore-' + uuid.uuid4().hex[:8]
subprocess.run(['systemd-run', '--quiet', '--unit=' + unit, '--on-active=240s',
                '/bin/bash', str(restore)], check=True)
try:
    cfg = json.loads(paths[0].read_text())
    cfg['inbounds'].append(dict(tag='dns-hijack', listen='0.0.0.0', port=14206,
        protocol='tunnel', settings=dict(network='tcp,udp', address='127.0.0.1', port=53)))
    cfg['routing']['rules'].insert(0, dict(type='field', inboundTag=['dns-hijack'], outboundTag='dns-out'))
    paths[0].write_text(json.dumps(cfg, indent=2) + '\n')
    nft = paths[1].read_text()
    nft = nft.replace('    # WG между VPS',
        '    iifname != "wg0" iifname != "lo" meta l4proto { tcp, udp } th dport 14206 drop\n    # WG между VPS')
    nft = nft.replace('    iifname "wg0" ip daddr',
        '    iifname "wg0" meta l4proto { tcp, udp } th dport 53 return\n    iifname "wg0" ip daddr', 1)
    nft = nft.replace('  chain in {', '''  chain dns_redirect {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "wg0" meta l4proto { tcp, udp } th dport 53 redirect to :14206
  }
  chain in {''', 1)
    paths[1].write_text(nft)
    with (root / 'validation.log').open('w') as log:
        subprocess.run(['nft', '-c', '-f', str(paths[1])], stdout=log, stderr=log, check=True)
        subprocess.run(['env', 'XRAY_LOCATION_ASSET=/var/lib/rp/assets', '/usr/local/bin/xray',
                        'run', '-test', '-c', str(paths[0])], stdout=log, stderr=log, check=True)
    subprocess.run(['systemctl', 'restart', 'rp-net', 'rp-xray'], check=True)
    subprocess.run(['rp', 'tunnel', 'sync'], check=True)
    print('TRIAL_READY ' + str(root), flush=True)
    # Controller runs the namespace probes while this process owns the trial.
    time.sleep(180)
finally:
    subprocess.run(['/bin/bash', str(restore)], check=True)
    subprocess.run(['systemctl', 'stop', unit + '.timer'], check=True)
    print('TRIAL_RESTORED', flush=True)
