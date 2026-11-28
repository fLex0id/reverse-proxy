#!/usr/bin/env python3
"""Compare installed/candidate diagnostics during a real rp-net outage.

Temporarily stops rp-net and, by systemd dependency, client wg0. The inner tunnel
and SOCKS remain usable, reproducing the diagnostic's former false-success path.
Independent management SSH and a 120-second restoration timer are mandatory.
Candidate is executed directly from an uploaded file, without installation.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
for arg in ['lab1', 'client', 'candidate', 'output']:
    p.add_argument('--' + arg, required=True)
a = p.parse_args()
out = Path(a.output)
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
rows = []

def run(host, command, name, timeout=90):
    started = time.time()
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                       capture_output=True, text=True, timeout=timeout)
    (out / (name + '.log')).write_text(r.stdout + r.stderr)
    rows.append(dict(id=name, rc=r.returncode, seconds=time.time()-started))
    (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    return r

client_probe = 'ip netns exec rp-lab-client curl -4 -fsS --max-time 15 https://1.1.1.1/cdn-cgi/trace -o /dev/null'
for unit in ['rp-net', 'wg-quick@wg0', 'rp-xray']:
    if run(a.lab1, 'systemctl is-active --quiet ' + unit, 'preflight-' + unit).returncode:
        raise SystemExit('Required service is not healthy; no fault injected')
if run(a.client, client_probe, 'client-before').returncode:
    raise SystemExit('Client preflight failed; no fault injected')
unit = 'rp-lab-diag-restore-' + uuid.uuid4().hex[:10]
if run(a.lab1, 'systemd-run --quiet --unit=' + unit +
       ' --on-active=120 /usr/bin/systemctl start rp-net wg-quick@wg0', 'arm-restore').returncode:
    raise SystemExit('Cannot arm independent restoration')
try:
    if run(a.lab1, 'systemctl stop rp-net', 'stop-net').returncode:
        raise RuntimeError('Cannot inject service outage')
    state = run(a.lab1, 'systemctl is-active rp-net', 'fault-state-before')
    if state.stdout.strip() != 'inactive':
        raise RuntimeError('Network service did not stop')
    baseline = run(a.lab1, 'rp diag', 'installed-diag')
    candidate = run(a.lab1, shlex.join(['bash', a.candidate, 'diag']), 'candidate-diag')
    state = run(a.lab1, 'systemctl is-active rp-net', 'fault-state-after')
    if state.stdout.strip() != 'inactive':
        raise RuntimeError('Fault did not persist through diagnostics')
finally:
    restored = run(a.lab1, 'systemctl start rp-net wg-quick@wg0', 'restore')
    if restored.returncode:
        raise RuntimeError('Restore failed; independent timer remains armed')
    for service in ['rp-net', 'wg-quick@wg0', 'rp-xray']:
        if run(a.lab1, 'systemctl is-active --quiet ' + service, 'restored-' + service).returncode:
            raise RuntimeError('Restored service state unconfirmed; timer remains armed')
    run(a.lab1, 'systemctl stop ' + unit + '.timer', 'disarm-restore')
client = run(a.client, client_probe, 'client-after')
summary = dict(installed_rc=baseline.returncode, candidate_rc=candidate.returncode,
               result='PASS' if candidate.returncode == 1 and client.returncode == 0 else 'FAIL')
(out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary), flush=True)
raise SystemExit(0 if summary['result'] == 'PASS' else 1)
