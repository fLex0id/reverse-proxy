#!/usr/bin/env python3
"""Drop only LAB-2 -> LAB-1 packet-up TCP; timed rule cleanup preserves SSH."""
import argparse
import json
from pathlib import Path
import subprocess
import time
p=argparse.ArgumentParser();p.add_argument('--lab1',required=True);p.add_argument('--lab2',required=True);p.add_argument('--client',required=True);p.add_argument('--lab1-ip',required=True);p.add_argument('--output',required=True);a=p.parse_args()
out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
def run(host,cmd,timeout=420):
    return subprocess.run(['ssh','-o','BatchMode=yes',host,cmd],capture_output=True,text=True,timeout=timeout)
for mode in ['reality-xhttp2','auto']:
    r=run(a.lab1,'rp tunnel '+mode);(out/('mode-'+mode+'.log')).write_text(r.stdout+r.stderr)
    if r.returncode: raise SystemExit('Cannot prepare active packet-up/auto')
r=run(a.lab2,'systemd-run --unit=rp-lab-clear-fault --on-active=240s /usr/sbin/nft delete table inet rp_lab_fault')
if r.returncode: raise SystemExit('Cannot arm cleanup timer')
rule='table inet rp_lab_fault { chain out { type filter hook output priority -10; policy accept; ip daddr '+a.lab1_ip+' tcp dport 8443 counter drop; } }'
started=time.monotonic();records=[];first_recovered=None
try:
    r=run(a.lab2,"nft -f - <<'NFT'\n"+rule+'\nNFT')
    if r.returncode: raise RuntimeError(r.stderr)
    for _ in range(80):
        r=run(a.client,"ip netns exec rp-lab-client curl -4 -fsS --connect-timeout 2 --max-time 3 https://1.1.1.1/cdn-cgi/trace -o /dev/null",timeout=10)
        elapsed=time.monotonic()-started
        records.append({'seconds':round(elapsed,3),'rc':r.returncode})
        (out/'probes.json').write_text(json.dumps(records,indent=2))
        if r.returncode==0 and any(v['rc']!=0 for v in records):
            first_recovered=elapsed;break
        if elapsed>=200:break
        time.sleep(1)
finally:
    r=run(a.lab2,'nft list table inet rp_lab_fault; nft delete table inet rp_lab_fault; systemctl stop rp-lab-clear-fault.timer; journalctl -u rp-watch --since "10 minutes ago" --no-pager')
    (out/'watch-and-rule.log').write_text(r.stdout+r.stderr)
(out/'result.json').write_text(json.dumps({'recovery_seconds':first_recovered,'sla_seconds':60,'result':'PASS' if first_recovered is not None and first_recovered<=60 else 'FAIL'},indent=2))
print((out/'result.json').read_text(),flush=True)
# Leave the proven policy in auto; timed cleanup also protects a killed runner.
