#!/usr/bin/env python3
"""LAB-2 only: kill the helper during archive creation, then use its recovery unit."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import time

HELPER = '/root/rp-lab/transaction-current.py'
OUT = Path('/root/rp-lab/prepare-crash')
TX = Path('/var/lib/rp/transaction')

if '--victim' in sys.argv:
    spec = importlib.util.spec_from_file_location('transaction', HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    def crash(*args, **kwargs):
        os.kill(os.getpid(), signal.SIGKILL)
    tarfile.TarFile.add = crash
    sys.argv = [HELPER, 'prepare', str(os.getpid())]
    module.main()
    raise SystemExit('fault injection failed')

OUT.mkdir(mode=0o700, exist_ok=True)
records = []
def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=180)
def record(name, ok, detail):
    item = dict(id=name, result='PASS' if ok else 'FAIL', detail=detail, time=time.time())
    records.append(item)
    (OUT/'results.json').write_text(json.dumps(records, indent=2)+'\n')
    print(json.dumps(item), flush=True)
    if not ok: raise RuntimeError(name)

assert run(['rp', '_func']).returncode == 0, 'old tunnel must be healthy'
original = Path('/etc/rp/rp2.conf').read_bytes()
try:
    r = run([sys.executable, __file__, '--victim'])
    (OUT/'victim.log').write_text(r.stdout+r.stderr)
    record('sigkill-delivered', r.returncode == -signal.SIGKILL, {'rc': r.returncode})
    phase = json.loads((TX/'state.json').read_text())['phase']
    record('durable-preparing', phase == 'PREPARING', phase)
    r = run(['systemctl', 'is-active', '--quiet', 'rp-transaction-rollback.timer'])
    record('recovery-timer-armed', r.returncode == 0, 'real systemd timer remains active')
    r = run(['systemctl', 'start', 'rp-transaction-rollback.service'])
    (OUT/'recovery.log').write_text(r.stdout+r.stderr)
    phase = json.loads((TX/'state.json').read_text())['phase']
    record('recovery-unit-succeeded', r.returncode == 0 and phase == 'ROLLED_BACK', phase)
    record('config-unchanged', Path('/etc/rp/rp2.conf').read_bytes() == original,
           'no extraction of incomplete archive')
    r = run(['systemctl', 'is-active', '--quiet', 'rp-watch'])
    record('watch-restored', r.returncode == 0, 'watch service active')
    record('tunnel-healthy', run(['rp', '_func']).returncode == 0, 'live two-way probe')
    record('partial-archive-cleaned', not (TX/'preparing.tgz').exists()
           and not (TX/'pending').exists() and not (TX/'installing').exists(),
           'archive and update markers removed')
finally:
    if (TX/'pending').exists():
        r = run(['python3', str(TX/'runner.py'), 'rollback'])
        (OUT/'cleanup.log').write_text(r.stdout+r.stderr)
