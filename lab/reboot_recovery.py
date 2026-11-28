#!/usr/bin/env python3
"""Real LAB-2 reboot in INSTALLING; preserve management SSH and verify recovery.

This tests durable boot recovery after controlled owned-file mutation, not every
failure point of a full rp push. Never overlap another mutation/fault suite.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser()
for name in ['lab1', 'lab2', 'client', 'output']:
    p.add_argument('--' + name, required=True)
a = p.parse_args()
out = Path(a.output)
out.mkdir(parents=True, exist_ok=True)
out.chmod(0o700)
results = []

def ssh(host, command, timeout=120):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host, command],
                          text=True, capture_output=True, timeout=timeout)

def check(name, ok, detail):
    row = dict(id=name, result='PASS' if ok else 'FAIL', detail=detail, time=time.time())
    results.append(row)
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(row), flush=True)
    if not ok:
        raise RuntimeError(name + ': inspect live transaction before another mutation')

def checked(host, command, name):
    r = ssh(host, command)
    (out / (name + '.log')).write_text(r.stdout + r.stderr)
    if r.returncode:
        raise RuntimeError(name + ': ' + str(r.returncode))
    return r.stdout.strip()

checked(a.lab1, 'rp tunnel reality-xhttp2', 'pin')
checked(a.lab2, 'test ! -e /var/lib/rp/transaction/pending && rp _func', 'preflight')
old_boot = checked(a.lab2, 'cat /proc/sys/kernel/random/boot_id', 'boot-before')
old_hash = checked(a.lab2, 'sha256sum /etc/rp/rp2.conf', 'config-before').split()[0]
script = '''set -e
test ! -e /etc/rp/lab-reboot-new-owned
python3 /usr/local/lib/rp/transaction.py prepare "$$"
printf 'uncommitted fixture\\n' >/etc/rp/lab-reboot-new-owned
printf '\\n# interrupted laboratory installation\\n' >>/etc/rp/rp2.conf
sync
systemctl reboot
'''
r = ssh(a.lab2, script)
(out / 'reboot-request.log').write_text(r.stdout + r.stderr)
started = time.monotonic()
boot = ''
while time.monotonic() - started < 180:
    r = ssh(a.lab2, 'cat /proc/sys/kernel/random/boot_id', timeout=10)
    if r.returncode == 0 and r.stdout.strip() != old_boot:
        boot = r.stdout.strip()
        break
    time.sleep(5)
check('actual-reboot', bool(boot), {'seconds': time.monotonic() - started})
while time.monotonic() - started < 300:
    r = ssh(a.lab2, "python3 -c 'import json; print(json.load(open(\"/var/lib/rp/transaction/state.json\"))[\"phase\"])'")
    if r.returncode == 0 and r.stdout.strip() == 'ROLLED_BACK':
        break
    time.sleep(3)
check('boot-rollback', r.returncode == 0 and r.stdout.strip() == 'ROLLED_BACK',
      {'phase': r.stdout.strip(), 'seconds': time.monotonic() - started})
new_hash = checked(a.lab2, 'sha256sum /etc/rp/rp2.conf', 'config-after').split()[0]
check('old-config-restored', new_hash == old_hash, 'SHA256 comparison')
r = ssh(a.lab2, 'test ! -e /etc/rp/lab-reboot-new-owned && test ! -e /var/lib/rp/backup.tgz && test ! -e /var/lib/rp/transaction/pending')
check('owned-file-and-transaction-cleanup', r.returncode == 0, 'new file, backup and pending marker absent')
checked(a.lab2, 'systemctl is-active --quiet rp-watch && rp _func', 'watch-and-tunnel')
check('watch-and-tunnel', True, 'supervisor active and bidirectional functional probe passes')
state = checked(a.lab2, 'rp mode status', 'mode-after')
check('manual-pin-preserved', 'mode=manual:reality-xhttp2' in state and 'active=reality-xhttp2' in state, state)
checked(a.lab1, 'rp tunnel sync', 'route-sync')
checked(a.client, 'ip netns exec rp-lab-client curl -4 -fsS --max-time 20 https://1.1.1.1/cdn-cgi/trace -o /dev/null', 'client-https')
check('client-https', True, 'isolated WG client received HTTPS after boot recovery')
checked(a.lab1, 'rp tunnel auto', 'restore-auto')
