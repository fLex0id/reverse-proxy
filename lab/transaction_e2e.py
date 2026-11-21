#!/usr/bin/env python3
"""Run on LAB-2 only after an installed, working candidate; independent SSH required.

Test real archive integrity, owned-file rollback, unrelated-key preservation and
concurrent confirm/rollback. This never reboots or changes management networking.
"""
import json
from pathlib import Path
import subprocess
import time

HELPER='/root/rp-lab/transaction-current.py'
RUNNER='/var/lib/rp/transaction/runner.py'
OUT=Path('/root/rp-lab/transaction-tests');OUT.mkdir(mode=0o700,exist_ok=True)
records=[]
def run(args,check=True):
    r=subprocess.run(args,text=True,capture_output=True,timeout=180)
    if check and r.returncode: raise RuntimeError('command failed: '+repr(args)+'\n'+r.stdout+r.stderr)
    return r

def record(name,ok,detail):
    records.append(dict(id=name,result='PASS' if ok else 'FAIL',detail=detail,time=time.time()))
    (OUT/'results.json').write_text(json.dumps(records,indent=2)+'\n')
    print(json.dumps(records[-1]),flush=True)
    if not ok: raise RuntimeError(name)

def phase(): return json.loads(Path('/var/lib/rp/transaction/state.json').read_text())['phase']
def prepare():
    run(['bash','-c','python3 "$1" prepare "$$"; r=$?; exit "$r"','bash',HELPER])

def healthy():
    for _ in range(15):
        if run(['/usr/local/bin/rp','_func'],False).returncode==0: return True
        time.sleep(2)
    return False

backup=Path('/var/lib/rp/backup.tgz')
assert healthy(), 'old tunnel is not healthy'
original=Path('/etc/rp/rp2.conf').read_bytes()
keys=Path('/root/.ssh/authorized_keys')
comment='# rp-lab-unrelated-concurrent-change'
try:
    prepare()
    record('backup-private',backup.stat().st_mode&0o777==0o600,'backup mode')
    saved=backup.read_bytes()
    with backup.open('r+b') as f: f.seek(10); b=f.read(1); f.seek(10); f.write(bytes([b[0]^1]))
    r=run(['python3',RUNNER,'rollback'],False)
    (OUT/'corrupt-archive.log').write_text(r.stdout+r.stderr)
    record('corrupt-backup-rejected',r.returncode!=0 and phase()=='INSTALLING','no extraction on checksum failure')
    backup.write_bytes(saved);backup.chmod(0o600)
    Path('/etc/rp/lab-created-after-update').write_text('synthetic owned file')
    with Path('/etc/rp/rp2.conf').open('a') as f: f.write('\n# simulated new configuration\n')
    with keys.open('a') as f: f.write(comment+'\n')
    r=run(['python3',RUNNER,'rollback']);(OUT/'rollback.log').write_text(r.stdout+r.stderr)
    record('old-config-restored',Path('/etc/rp/rp2.conf').read_bytes()==original,'byte-for-byte original configuration')
    record('new-owned-file-removed',not Path('/etc/rp/lab-created-after-update').exists(),'old tree restored')
    record('unrelated-ssh-change-preserved',comment in keys.read_text(),'concurrent unrelated authorized_keys comment preserved')
    record('rollback-tunnel-healthy',phase()=='ROLLED_BACK' and healthy(),'old active transport passes live probe')
    record('rollback-cleanup',not backup.exists() and not Path('/var/lib/rp/transaction/pending').exists(),'archive and pending marker absent')
    for i in range(3):
        prepare()
        run(['python3',RUNNER,'ready'])
        Path('/var/lib/rp/push.rc').write_text('0\n')
        # Alternate launch order; the lock must serialize both cases.
        actions=['confirm','rollback'] if i%2==0 else ['rollback','confirm']
        procs=[subprocess.Popen(['python3',RUNNER,action],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True) for action in actions]
        output={}
        for action,proc in zip(actions,procs):
            text=proc.communicate(timeout=180)[0];output[action]={'rc':proc.returncode,'log':text}
        (OUT/('race-%d.json'%i)).write_text(json.dumps(output,indent=2))
        state=phase()
        good=state in ('COMMITTED','ROLLED_BACK') and not backup.exists() and healthy()
        if state=='ROLLED_BACK': good=good and output['confirm']['rc']!=0
        if state=='COMMITTED': good=good and output['confirm']['rc']==0
        record('confirm-rollback-race-%d'%i,good,{'phase':state,'rc':{k:v['rc'] for k,v in output.items()}})
finally:
    # Restore only the test comment; never overwrite unrelated live keys.
    text=keys.read_text();keys.write_text('\n'.join(x for x in text.splitlines() if x!=comment)+'\n');keys.chmod(0o600)
    if Path('/var/lib/rp/transaction/pending').exists():
        r=run(['python3',RUNNER,'rollback'],False)
        (OUT/'cleanup-rollback.log').write_text(r.stdout+r.stderr)
