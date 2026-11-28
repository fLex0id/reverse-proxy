#!/usr/bin/env python3
"""Collect strict DoH diagnostics on each real transport without installing code.

Upload the candidate to LAB-1 first. Do not overlap other network/fault suites.
The script on disk supplies only functions; no install/migrate entry point runs.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--lab1', required=True)
p.add_argument('--candidate', required=True, help='uploaded rp.sh path on LAB-1')
p.add_argument('--output', required=True)
p.add_argument('--repetitions', type=int, default=5)
a = p.parse_args()
if not 1 <= a.repetitions <= 100:
    raise SystemExit('repetitions must be 1..100')
out = Path(a.output)
out.mkdir(parents=True, exist_ok=True)
out.chmod(0o700)
rows = []

def remote(command, name, timeout=600):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', a.lab1, command],
                       text=True, capture_output=True, timeout=timeout)
    (out / (name + '.log')).write_text(r.stdout + r.stderr)
    return r

script = '''source <(sed '$d' "$1")
conf_load
urls=$(py dns) || exit 2
[[ -n $urls ]] || exit 2
for ((repeat=1;repeat<=$2;repeat++)); do
  index=0
  for url in $urls; do
    index=$((index+1))
    doh_test "$url"; result=$?
    printf '%d %d %d ' "$repeat" "$index" "$result"
    cat "$STATE/doh-last.json"
  done
done
'''
try:
    for transport in ['reality-xhttp2', 'reality-xhttp', 'hy2-wg', 'hy2o-wg']:
        if remote('rp tunnel ' + transport, transport + '-pin').returncode:
            raise RuntimeError('Pin failed; inspect remote transition before retrying')
        started = time.time()
        r = remote(shlex.join(['bash', '-c', script, 'bash', a.candidate, str(a.repetitions)]),
                   transport + '-probes')
        if r.returncode:
            raise RuntimeError('Probe harness failed; inspect log')
        parsed = []
        for line in r.stdout.splitlines():
            repeat, index, rc, report = line.split(' ', 3)
            item = json.loads(report)
            item.update(transport=transport, repeat=int(repeat), resolver_index=int(index), rc=int(rc))
            parsed.append(item)
        if not parsed or len(parsed) % a.repetitions:
            raise RuntimeError('Incomplete probe output')
        rows.extend(parsed)
        (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(json.dumps(dict(transport=transport, cases=len(parsed), seconds=time.time()-started,
                              failed=sum(x['result'] != 'PASS' for x in parsed))), flush=True)
finally:
    remote('rp tunnel auto', 'restore-auto')
