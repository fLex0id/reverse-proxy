#!/usr/bin/env python3
"""LAB-2: observe the real, unchanged 30-minute confirmation deadline."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

HELPER = '/root/rp-lab/transaction-current.py'
TX = Path('/var/lib/rp/transaction')
OUT = Path('/root/rp-lab/rollback-deadline')
OUT.mkdir(mode=0o700, exist_ok=True)
records = []
def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=180)
def require(args):
    r = run(args)
    if r.returncode: raise RuntimeError(r.stdout+r.stderr)
    return r
def record(name, ok, detail):
    row = dict(id=name, result='PASS' if ok else 'FAIL', time=time.time(), detail=detail)
    records.append(row)
    (OUT/'results.json').write_text(json.dumps(records, indent=2)+'\n')
    print(json.dumps(row), flush=True)
    if not ok: raise RuntimeError(name)

require(['rp', '_func'])
original = Path('/etc/rp/rp2.conf').read_bytes()
started = time.monotonic()
try:
    require(['bash', '-c', 'python3 "$1" prepare "$$"', 'bash', HELPER])
    meta = json.loads((TX/'state.json').read_text())
    record('default-deadline', 1799 <= meta['deadline']-meta['created'] <= 1800,
           {'created': meta['created'], 'deadline': meta['deadline'],
            'helper_sha256': hashlib.sha256(Path(HELPER).read_bytes()).hexdigest()})
    marker = Path('/etc/rp/lab-deadline-new-file')
    marker.write_text('must be removed by old-tree restoration\n')
    require(['python3', str(TX/'runner.py'), 'ready'])
    details = require(['systemctl', 'cat', 'rp-transaction-rollback.timer'])
    (OUT/'timer.txt').write_text(details.stdout)
    record('persistent-real-timer', 'Persistent=true' in details.stdout,
           'no deadline shortening or clock manipulation; no confirm will be issued')
    samples = []
    next_log = 0
    while True:
        now = time.time()
        phase = json.loads((TX/'state.json').read_text())['phase']
        if phase == 'ROLLED_BACK': break
        if now > meta['deadline']+180: raise RuntimeError('rollback did not finish before deadline + 180s')
        if time.monotonic() >= next_log:
            sample = dict(time=now, phase=phase,
                          live_probe_rc=run(['rp', '_func']).returncode,
                          watch_rc=run(['systemctl', 'is-active', '--quiet', 'rp-watch']).returncode)
            samples.append(sample)
            (OUT/'samples.json').write_text(json.dumps(samples, indent=2)+'\n')
            print(json.dumps(sample), flush=True)
            next_log = time.monotonic()+60
        time.sleep(5)
    record('timer-actually-fired', time.time() >= meta['deadline'],
           {'elapsed_seconds': time.monotonic()-started, 'phase': phase})
    record('config-restored', Path('/etc/rp/rp2.conf').read_bytes() == original and not marker.exists(),
           'old configuration preserved; synthetic new file removed')
    record('tunnel-and-watch-healthy', run(['rp', '_func']).returncode == 0 and
           run(['systemctl', 'is-active', '--quiet', 'rp-watch']).returncode == 0,
           'two-way probe and active watcher')
    record('cleanup', not (TX/'pending').exists() and not (TX/'installing').exists()
           and not Path('/var/lib/rp/backup.tgz').exists(), 'backup and markers absent')
finally:
    r = run(['journalctl', '-u', 'rp-transaction-rollback', '--since', '40 minutes ago', '--no-pager'])
    (OUT/'rollback-journal.log').write_text(r.stdout+r.stderr)
    if (TX/'pending').exists():
        r = run(['python3', str(TX/'runner.py'), 'rollback'])
        (OUT/'emergency-cleanup.log').write_text(r.stdout+r.stderr)
