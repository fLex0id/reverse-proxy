#!/usr/bin/env python3
"""Stop only rp's Xray, with independent timed restoration armed first."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import shlex
import subprocess
import time
import uuid
p=argparse.ArgumentParser();p.add_argument('--lab1',required=True);p.add_argument('--lab2',required=True);p.add_argument('--client',required=True);p.add_argument('--output',required=True);a=p.parse_args()
out=Path(a.output);out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
def ssh(host,command,timeout=180):
    r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',host,command],text=True,capture_output=True,timeout=timeout)
    return r
r=ssh(a.lab1,'rp tunnel reality-xhttp2',420);(out/'pin.log').write_text(r.stdout+r.stderr)
if r.returncode: raise SystemExit('Could not establish manual control; no fault injected')
for name,command in [('https',"ip netns exec rp-lab-client curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace -o /dev/null"),
                     ('dns',"ip netns exec rp-lab-client python3 /root/rp-lab/dns-probe.py 8.8.8.8 failclosed-control.example.com")]:
    r=ssh(a.client,command);(out/('preflight-'+name+'.log')).write_text(r.stdout+r.stderr)
    if r.returncode:raise SystemExit('Client preflight failed; no fault injected')
# A separate systemd timer restores Xray even if this runner loses connection.
restore_unit='rp-lab-restore-xray-'+uuid.uuid4().hex[:8]
sync_active=ssh(a.lab1,'systemctl is-active --quiet rp-route-sync.timer').returncode==0
restore_targets='rp-xray'+(' rp-route-sync.timer' if sync_active else '')
r=ssh(a.lab1,'systemd-run --unit='+restore_unit+' --on-active=45s /usr/bin/systemctl start '+restore_targets)
if r.returncode: raise SystemExit('Cannot arm independent restore timer')
captures=[]
checks={}
try:
    # The route-sync unit pulls Xray back up through its service dependency.
    # Pause that supervisor to hold a sustained fault; the independent timer
    # restores both. The first unpaused run is retained as recovery evidence.
    r=ssh(a.lab1,'systemctl stop rp-route-sync.timer rp-route-sync.service')
    if r.returncode:raise RuntimeError('Cannot hold a sustained Xray outage')
    for label,host in [('lab1',a.lab1),('lab2',a.lab2),('client',a.client)]:
        unit='rp-lab-failclosed-'+uuid.uuid4().hex[:8]
        args=['tcpdump','-U','-i','wg0' if label=='client' else 'ens18','-nn','-s','0','-w','-',
              'host 1.1.1.1 or host 2606:4700:4700::1111 or port 53 or icmp']
        if label=='client':args=['ip','netns','exec','rp-lab-client']+args
        args=['systemd-run','--quiet','--pipe','--wait','--unit='+unit,'--property=RuntimeMaxSec=90']+args
        data=(out/(label+'.pcap')).open('wb');log=(out/(label+'-capture.log')).open('w')
        proc=subprocess.Popen(['ssh',host,shlex.join(args)],stdout=data,stderr=log)
        captures.append((label,host,unit,proc,data,log))
    time.sleep(2)
    for label,host,unit,proc,data,log in captures:
        if (out/(label+'.pcap')).stat().st_size<24 or ssh(host,'systemctl is-active --quiet '+unit).returncode:
            raise RuntimeError('Capture missing on '+host)
    r=ssh(a.lab1,'systemctl stop rp-xray; systemctl is-active rp-xray')
    (out/'stop.log').write_text(r.stdout+r.stderr)
    if 'inactive' not in r.stdout: raise RuntimeError('Xray stop not confirmed')
    (out/'fault-start.json').write_text(json.dumps({'unix_time':time.time()})+'\n')
    commands={
      'https':"ip netns exec rp-lab-client curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace -o /dev/null",
      'dns':"ip netns exec rp-lab-client python3 /root/rp-lab/dns-probe.py 8.8.8.8 failclosed-control.example.com",
      'ipv6':"ip netns exec rp-lab-client curl -g -6 -k -sS --max-time 10 'https://[2606:4700:4700::1111]/' -o /dev/null"}
    def probe(item):
        name,cmd=item;r=ssh(a.client,cmd,20);(out/(name+'.log')).write_text(r.stdout+r.stderr)
        # A missing executable, namespace or broken SSH is not a kill-switch PASS.
        blocked=(r.returncode in (7,28) if name!='dns' else
                 r.returncode==1 and ('TimeoutError' in r.stderr or 'ConnectionRefusedError' in r.stderr))
        result='PASS' if blocked else ('FAIL' if r.returncode==0 else 'UNKNOWN')
        return name,{'rc':r.returncode,'result':result,'expectation':'network timeout/refusal while Xray is stopped; no answer'}
    with ThreadPoolExecutor(max_workers=3) as pool:
        checks.update(pool.map(probe,commands.items()))
    r=ssh(a.lab1,'systemctl is-active rp-xray')
    if r.stdout.strip()!='inactive':raise RuntimeError('Xray restarted during sustained-fault probes')
    r=ssh(a.lab1,'nft list table inet rp_guard; nft list table ip6 rp_block6')
    (out/'guard-counters.log').write_text(r.stdout+r.stderr)
finally:
    (out/'fault-end.json').write_text(json.dumps({'unix_time':time.time()})+'\n')
    r=ssh(a.lab1,'systemctl start '+restore_targets)
    (out/'restore.log').write_text(r.stdout+r.stderr)
    for label,host,unit,proc,data,log in captures:
        ssh(host,'systemctl kill --signal=SIGINT '+unit);ssh(host,'systemctl stop '+unit)
        proc.wait(timeout=20);data.close();log.close()
        remote='/root/rp-lab/'+unit+'.pcap'
        subprocess.run(['scp','-q',str(out/(label+'.pcap')),a.client+':'+remote],check=True)
        result=ssh(a.client,shlex.join(['tcpdump','-nn','-vv','-r',remote]))
        (out/(label+'-packets.log')).write_text(result.stdout+result.stderr)
    ssh(a.lab1,'systemctl stop '+restore_unit+'.timer')
start=time.monotonic()
while True:
    r=ssh(a.client,"ip netns exec rp-lab-client curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace -o /dev/null")
    if r.returncode==0 or time.monotonic()-start>=60:break
    time.sleep(2)
(out/'restored.log').write_text(r.stdout+r.stderr)
checks['restored']={'rc':r.returncode,'result':'PASS' if r.returncode==0 else 'FAIL','seconds':time.monotonic()-start}
(out/'results.json').write_text(json.dumps(checks,indent=2));print(json.dumps(checks,indent=2))
ssh(a.lab1,'rp tunnel auto',420)
