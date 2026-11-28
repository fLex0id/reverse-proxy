#!/usr/bin/env python3
"""Paired strict DoH probes: LAB-1 SOCKS versus direct LAB-2, with underlay PCAP.

Upload the candidate script to both hosts first. Only its functions are sourced.
No DNS fallback or TLS verification bypass is used. Run without other lab suites.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
for arg in ['lab1', 'lab2', 'candidate', 'output']:
    p.add_argument('--' + arg, required=True)
p.add_argument('--transport', choices=['reality-xhttp2', 'reality-xhttp', 'hy2-wg', 'hy2o-wg'], default='hy2o-wg')
p.add_argument('--repetitions', type=int, default=10)
a = p.parse_args()
if not 1 <= a.repetitions <= 100:
    p.error('repetitions must be 1..100')
out = Path(a.output)
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
token = uuid.uuid4().hex[:10]
captures = []
rows = []

def ssh(host, command, timeout=180):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                          text=True, capture_output=True, timeout=timeout)

script = r'''source <(sed '$d' "$1")
conf_load
STATE=$(mktemp -d /tmp/rp-doh-compare.XXXXXX) || exit 2
trap 'rm -rf "${STATE:?}"' EXIT
eval "$(declare -f sx | sed '1s/^sx /original_sx /')"
path=$2; mapping=$3
sx() {
  if [[ $path == direct ]]; then
    curl --proxy '' -4 -fsS --connect-timeout 8 --connect-to "$mapping" "$@"
  else
    original_sx --connect-to "$mapping" "$@"
  fi
}
doh_test "$4"; rc=$?
cat "$STATE/doh-last.json"
exit "$rc"
'''

def probe(path, host, repeat, label, url, mapping):
    started = time.time()
    result = ssh(host, shlex.join(['bash', '-c', script, 'bash', a.candidate, path, mapping, url]), 35)
    (out / f'{repeat}-{label}-{path}.log').write_text(result.stdout + result.stderr)
    report = json.loads(result.stdout)
    if result.returncode not in [0, 1] or (result.returncode == 0) != (report['result'] == 'PASS'):
        raise RuntimeError('probe execution/status mismatch')
    report.update(path=path, repeat=repeat, endpoint=label, started=started, transport=a.transport)
    return report

cases = [
    ('quad9-ip1', 'https://9.9.9.9/dns-query', '9.9.9.9:443:9.9.9.9:443'),
    ('quad9-name1', 'https://dns.quad9.net/dns-query', 'dns.quad9.net:443:9.9.9.9:443'),
    ('quad9-ip2', 'https://149.112.112.112/dns-query', '149.112.112.112:443:149.112.112.112:443'),
    ('quad9-name2', 'https://dns.quad9.net/dns-query', 'dns.quad9.net:443:149.112.112.112:443'),
    ('cloudflare-ip', 'https://1.1.1.1/dns-query', '1.1.1.1:443:1.1.1.1:443'),
    ('cloudflare-name', 'https://cloudflare-dns.com/dns-query', 'cloudflare-dns.com:443:1.1.1.1:443'),
]
try:
    pin = ssh(a.lab1, 'rp tunnel ' + a.transport)
    (out / 'pin.log').write_text(pin.stdout + pin.stderr)
    if pin.returncode:
        raise RuntimeError('transport pin failed')
    for label, host in [('lab1', a.lab1), ('lab2', a.lab2)]:
        unit = 'rp-lab-doh-' + token
        command = ['systemd-run', '--quiet', '--pipe', '--wait', '--unit=' + unit,
                   '--property=RuntimeMaxSec=1800', 'tcpdump', '-U', '-i', 'ens18', '-nn', '-s', '0',
                   '-w', '-', 'tcp port 443 and (host 9.9.9.9 or host 149.112.112.112 or host 1.1.1.1)']
        data = (out / (label + '.pcap')).open('wb')
        log = (out / (label + '-capture.log')).open('w')
        proc = subprocess.Popen(['ssh', host, shlex.join(command)], stdout=data, stderr=log)
        captures.append((label, host, unit, proc, data, log))
    time.sleep(2)
    for label, host, unit, proc, data, log in captures:
        if (out / (label + '.pcap')).stat().st_size < 24 or ssh(host, 'systemctl is-active --quiet ' + unit).returncode:
            raise RuntimeError('capture failed on ' + host)
    with ThreadPoolExecutor(max_workers=2) as pool:
        for repeat in range(1, a.repetitions + 1):
            for label, url, mapping in cases:
                futures = [pool.submit(probe, path, host, repeat, label, url, mapping)
                           for path, host in [('proxied', a.lab1), ('direct', a.lab2)]]
                rows.extend(f.result() for f in futures)
                (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
            print(json.dumps(dict(repeat=repeat, cases=len(rows),
                                  failed=sum(r['result'] != 'PASS' for r in rows))), flush=True)
finally:
    for label, host, unit, proc, data, log in captures:
        ssh(host, 'systemctl kill --signal=SIGINT ' + unit)
        ssh(host, 'systemctl stop ' + unit)
        proc.wait(timeout=20)
        data.close()
        log.close()
    restored = ssh(a.lab1, 'rp tunnel auto')
    (out / 'restore-auto.log').write_text(restored.stdout + restored.stderr)
    if restored.returncode:
        raise RuntimeError('automatic mode restoration failed')
