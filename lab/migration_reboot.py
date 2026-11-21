#!/usr/bin/env python3
"""Controller: interrupt a prepared migration and really reboot authorized VPS-1."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ['lab1', 'client', 'candidate', 'helper', 'fixture', 'output']:
        p.add_argument('--' + arg, required=True)
    a = p.parse_args()
    out = Path(a.output).resolve()
    out.mkdir(parents=True, exist_ok=False, mode=0o700)
    remote_out = '/root/rp-lab/migration-reboot-' + uuid.uuid4().hex[:10]

    def ssh(host, command, label, timeout=30):
        r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host, command],
                           capture_output=True, text=True, timeout=timeout)
        (out / (label + '.log')).write_text(r.stdout + r.stderr)
        return r

    old = ssh(a.lab1, 'cat /proc/sys/kernel/random/boot_id', 'old-boot')
    if old.returncode:
        raise RuntimeError('management SSH unavailable before test')
    before = old.stdout.strip()
    command = shlex.join(['python3', a.fixture, '--candidate', a.candidate,
                          '--helper', a.helper, '--output', remote_out, '--failure', 'reboot'])
    summary = dict(result='UNKNOWN', remote_artifacts=remote_out)
    with (out / 'fixture.log').open('w') as log:
        process = subprocess.Popen(['ssh', '-o', 'BatchMode=yes', a.lab1, command], stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 180
            attempt = 0
            while time.monotonic() < deadline:
                r = ssh(a.lab1, 'test -f ' + shlex.quote(remote_out + '/ready-for-reboot'), 'ready-' + str(attempt))
                if r.returncode == 0:
                    break
                if process.poll() is not None:
                    raise RuntimeError('fixture ended before the intended mutation')
                attempt += 1
                time.sleep(2)
            else:
                raise RuntimeError('fixture never reached the reboot gate')
            # Pause only this recovery timer until reboot. It remains enabled,
            # so the next boot must recover using the installed durable runner.
            script = '''import importlib.util,os,signal,subprocess
spec=importlib.util.spec_from_file_location('m', {helper!r})
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
d=m.load()
assert d['phase']=='MIGRATING' and m.pid_start(d['owner'])==d['owner_start']
subprocess.run(['systemctl','stop',m.TIMER,m.SERVICE],check=True)
os.kill(d['owner'],signal.SIGKILL)
subprocess.run(['systemctl','reboot'],check=True)
'''.format(helper=a.helper)
            start = time.monotonic()
            # A dropped SSH connection is expected here; a new boot ID is the proof.
            ssh(a.lab1, shlex.join(['python3', '-c', script]), 'request-reboot')
            deadline = time.monotonic() + 240
            attempt = 0
            while time.monotonic() < deadline:
                r = ssh(a.lab1, 'cat /proc/sys/kernel/random/boot_id', 'boot-' + str(attempt))
                if r.returncode == 0 and r.stdout.strip() and r.stdout.strip() != before:
                    summary['boot_changed'] = True
                    summary['ssh_return_seconds'] = round(time.monotonic() - start, 3)
                    break
                attempt += 1
                time.sleep(2)
            else:
                raise RuntimeError('new boot not observed; inspect management console')
            phase_script = "import json;print(json.load(open('/var/lib/rp/migration/state.json'))['phase'])"
            attempt = 0
            while time.monotonic() < deadline:
                r = ssh(a.lab1, shlex.join(['python3', '-c', phase_script]), 'phase-' + str(attempt))
                if r.returncode == 0 and r.stdout.strip() == 'ROLLED_BACK':
                    break
                attempt += 1
                time.sleep(2)
            else:
                raise RuntimeError('boot recovery did not reach ROLLED_BACK; private fallback is available')
            summary['boot_recovery_seconds'] = round(time.monotonic() - start, 3)
            verify = '''import importlib.util,json
from pathlib import Path
def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
m=module('m',{helper!r}); f=module('f',{fixture!r}); p=Path({directory!r})
r=dict(hashes_restored=f.owned_hashes(m)==json.loads((p/'before-hashes.json').read_text()),
 runtime_restored=f.runtime_snapshot(m)==json.loads((p/'before-runtime.json').read_text()),
 services_restored={{u:m.unit_state(u) for u in m.UNITS}}==json.loads((p/'before-units.json').read_text()),
 fallback_used=(p/'fallback-used').exists(),phase=m.load()['phase'])
print(json.dumps(r))
'''.format(helper=a.helper, fixture=a.fixture, directory=remote_out)
            r = ssh(a.lab1, shlex.join(['python3', '-c', verify]), 'verify', timeout=90)
            if r.returncode:
                raise RuntimeError('state verification command failed')
            summary.update(json.loads(r.stdout))
            client_results = []
            for attempt in range(5):
                r = ssh(a.client, 'ip netns exec rp-lab-client curl -4 -fsS --max-time 8 https://1.1.1.1/cdn-cgi/trace -o /dev/null', 'client-' + str(attempt))
                client_results.append(r.returncode)
                if r.returncode == 0:
                    break
                time.sleep(2)
            summary['client_attempt_rcs'] = client_results
            if (not all(summary[k] for k in ['hashes_restored', 'runtime_restored', 'services_restored']) or
                    summary['fallback_used'] or client_results[-1] != 0):
                raise RuntimeError('recovered state/client did not match the baseline')
            summary['result'] = 'PASS'
        finally:
            (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            if process.poll() is None:
                process.terminate()  # local SSH only; no unrelated remote process
            process.wait(timeout=10)
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
