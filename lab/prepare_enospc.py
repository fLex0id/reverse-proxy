#!/usr/bin/env python3
"""LAB-2 only: real ENOSPC in a tiny transaction tmpfs, never fill the root disk."""
import json
from pathlib import Path
import subprocess
import time
import uuid

TX=Path('/var/lib/rp/transaction');OUT=Path('/root/rp-lab/prepare-enospc')
HELPER='/root/rp-lab/transaction-current.py'
OUT.mkdir(mode=0o700,exist_ok=True);records=[]
def run(args,check=False):
    r=subprocess.run(args,capture_output=True,text=True,timeout=120)
    if check and r.returncode:raise RuntimeError(r.stdout+r.stderr)
    return r
def record(name,ok,detail):
    row=dict(id=name,result='PASS' if ok else 'FAIL',detail=detail,time=time.time())
    records.append(row);(OUT/'results.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(row),flush=True)
    if not ok:raise RuntimeError(name)

assert json.loads((TX/'state.json').read_text())['phase'] in ('COMMITTED','ROLLED_BACK')
assert not (TX/'pending').exists() and not Path('/var/lib/rp/backup.tgz').exists()
assert run(['systemctl','is-active','--quiet','rp-transaction-rollback.timer']).returncode!=0
assert run(['mountpoint','-q',str(TX)]).returncode!=0
assert run(['rp','_func']).returncode==0
original=Path('/etc/rp/rp2.conf').read_bytes()
guard='rp-lab-enospc-clean-'+uuid.uuid4().hex[:8]
cleanup='mountpoint -q /var/lib/rp/transaction && umount /var/lib/rp/transaction; systemctl disable --now rp-transaction-rollback.timer; systemctl start rp-watch'
run(['systemd-run','--unit='+guard,'--on-active=60s','/bin/bash','-c',cleanup],True)
mounted=False
try:
    run(['mount','-t','tmpfs','-o','size=128k,mode=700','rp-lab-enospc',str(TX)],True);mounted=True
    r=run(['bash','-c','python3 "$1" prepare "$$"','bash',HELPER])
    (OUT/'prepare.log').write_text(r.stdout+r.stderr)
    record('actual-enospc',r.returncode!=0 and 'No space left on device' in r.stderr,
           'kernel tmpfs ENOSPC; root filesystem remains available')
    phase=json.loads((TX/'state.json').read_text())['phase']
    record('prepare-aborted',phase=='ROLLED_BACK',phase)
    record('no-partial-state',not (TX/'pending').exists() and not (TX/'installing').exists()
           and not (TX/'preparing.tgz').exists(),'failed archive and markers removed')
    record('old-config-intact',Path('/etc/rp/rp2.conf').read_bytes()==original,'byte comparison')
    record('supervision-restored',run(['systemctl','is-active','--quiet','rp-watch']).returncode==0,
           'watch active after failed preparation')
    record('old-tunnel-healthy',run(['rp','_func']).returncode==0,'live bidirectional probe')
finally:
    if mounted:
        run(['umount',str(TX)],True)
    run(['systemctl','stop',guard+'.timer'],True)
    # The original terminal metadata becomes visible again after unmount.
    run(['systemctl','disable','--now','rp-transaction-rollback.timer'])
