#!/usr/bin/env python3
"""Stop only rp's Xray, with independent timed restoration armed first."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import subprocess
import time
import uuid
p=argparse.ArgumentParser();p.add_argument('--lab1',required=True);p.add_argument('--client',required=True);p.add_argument('--output',required=True);a=p.parse_args()
out=Path(a.output);out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
def ssh(host,command,timeout=180):
    r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',host,command],text=True,capture_output=True,timeout=timeout)
    return r
r=ssh(a.lab1,'rp tunnel reality-xhttp2',420);(out/'pin.log').write_text(r.stdout+r.stderr)
if r.returncode: raise SystemExit('Could not establish manual control; no fault injected')
# A separate systemd timer restores Xray even if this runner loses connection.
restore_unit='rp-lab-restore-xray-'+uuid.uuid4().hex[:8]
r=ssh(a.lab1,'systemd-run --unit='+restore_unit+' --on-active=45s /usr/bin/systemctl start rp-xray')
if r.returncode: raise SystemExit('Cannot arm independent restore timer')
f=(out/'capture.log').open('w')
cap=subprocess.Popen(['ssh',a.lab1,"timeout --signal=INT 35 tcpdump -U -i ens18 -nn -s 256 -w /root/rp-lab/failclosed-xray.pcap 'host 1.1.1.1 or port 53'"],stdout=f,stderr=f)
checks={}
try:
    time.sleep(2)
    r=ssh(a.lab1,'systemctl stop rp-xray; systemctl is-active rp-xray')
    (out/'stop.log').write_text(r.stdout+r.stderr)
    if 'inactive' not in r.stdout: raise RuntimeError('Xray stop not confirmed')
    commands={
      'https':"ip netns exec rp-lab-client curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace -o /dev/null",
      'dns':"ip netns exec rp-lab-client python3 /root/rp-lab/dns-probe.py 8.8.8.8 failclosed-control.example.com",
      'ipv6':"ip netns exec rp-lab-client curl -g -6 -k -sS --max-time 10 'https://[2606:4700:4700::1111]/' -o /dev/null"}
    def probe(item):
        name,cmd=item;r=ssh(a.client,cmd,20);(out/(name+'.log')).write_text(r.stdout+r.stderr)
        # A missing executable, namespace or broken SSH is not a kill-switch PASS.
        blocked=(r.returncode==28 if name!='dns' else
                 r.returncode==1 and 'TimeoutError' in r.stderr)
        result='PASS' if blocked else ('FAIL' if r.returncode==0 else 'UNKNOWN')
        return name,{'rc':r.returncode,'result':result,'expectation':'request times out while Xray is stopped'}
    with ThreadPoolExecutor(max_workers=3) as pool:
        checks.update(pool.map(probe,commands.items()))
    r=ssh(a.lab1,'nft list table inet rp_guard; nft list table ip6 rp_block6')
    (out/'guard-counters.log').write_text(r.stdout+r.stderr)
finally:
    r=ssh(a.lab1,'systemctl start rp-xray')
    (out/'restore.log').write_text(r.stdout+r.stderr)
    cap.wait(timeout=45);f.close()
    subprocess.run(['scp','-q',a.lab1+':/root/rp-lab/failclosed-xray.pcap',str(out)],check=True)
    ssh(a.lab1,'systemctl stop '+restore_unit+'.timer')
r=ssh(a.client,"ip netns exec rp-lab-client curl -4 -fsS --max-time 20 https://example.com -o /dev/null")
checks['restored']={'rc':r.returncode,'result':'PASS' if r.returncode==0 else 'FAIL'}
(out/'results.json').write_text(json.dumps(checks,indent=2));print(json.dumps(checks,indent=2))
ssh(a.lab1,'rp tunnel auto',420)
