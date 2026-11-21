#!/usr/bin/env python3
"""Run on authorized VPS-1: real failed migration with independent restoration.

The candidate changes owned files and fails immediately after unit generation.
The test never changes SSH or unrelated units. Keep this output private.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import time
import uuid


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', required=True)
    p.add_argument('--helper', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--failure', choices=['exit', 'kill'], default='exit')
    a = p.parse_args()
    out = Path(a.output).resolve()
    out.mkdir(parents=True, mode=0o700, exist_ok=False)
    os.umask(0o077)
    spec = importlib.util.spec_from_file_location('migration_fixture', a.helper)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    units = {u: helper.unit_state(u) for u in helper.UNITS}
    for unit in ['rp-net.service', 'rp-xray.service', 'rp-echo.service', 'wg-quick@wg0.service']:
        if units[unit]['ActiveState'] != 'active':
            raise RuntimeError('baseline service is not active: ' + unit)

    def hashes():
        result = {}
        for rel in helper.PATHS:
            path = Path('/') / rel
            files = [path] if path.is_file() else (list(path.rglob('*')) if path.is_dir() else [])
            for file in files:
                if file.is_file():
                    result[str(file)] = dict(sha256=helper.digest(file), mode=oct(file.stat().st_mode & 0o777))
        return result

    def runtime():
        value = helper.capture_runtime()
        value['nft'] = {k: re.sub(r'counter packets \d+ bytes \d+', 'counter', v)
                        for k, v in value['nft'].items()}
        return value

    before = hashes()
    runtime_before = runtime()
    (out / 'before-hashes.json').write_text(json.dumps(before, indent=2) + '\n')
    (out / 'before-runtime.json').write_text(json.dumps(runtime_before, indent=2) + '\n')
    backup = out / 'independent-backup.tgz'
    with tarfile.open(backup, 'w:gz', dereference=False) as archive:
        for rel in helper.PATHS:
            path = Path('/') / rel
            if path.exists():
                archive.add(path, arcname=rel)
    with tarfile.open(backup, 'r:gz') as archive:
        if not all(helper.valid_member(x) for x in archive):
            raise RuntimeError('independent backup is not restorable')
    restore = out / 'restore.sh'
    active = [u for u, state in units.items() if state['ActiveState'] == 'active']
    restore.write_text('#!/bin/bash\nset -eu\ntouch ' + shlex.quote(str(out / 'fallback-used')) +
                       '\nsystemctl stop rp-migration-recover.timer rp-migration-recover.service || true\n' +
                       'systemctl stop ' + shlex.join(helper.TIMERS + list(reversed(helper.CORE))) + ' || true\n' +
                       'tar -xpf ' + shlex.quote(str(backup)) + ' -C /\n' +
                       'systemctl daemon-reload\nsysctl -q -p /etc/sysctl.d/99-rp.conf\n' +
                       'systemctl start ' + shlex.join(active) + '\n')
    restore.chmod(0o700)
    unit = 'rp-lab-migration-restore-' + uuid.uuid4().hex[:10]
    subprocess.run(['systemd-run', '--quiet', '--unit=' + unit, '--on-active=600',
                    '/bin/bash', str(restore)], check=True)
    source = Path(a.candidate).read_text()
    marker = '  units_vps1 || die "Не удалось записать или применить службы и sysctl; миграция остановлена"'
    if source.count(marker) != 1:
        raise RuntimeError('migration injection point is ambiguous')
    injected = marker + '\n  conf_set WATCH_MIN 11\n  printf fixture >/etc/rp/migration-lab-marker\n'
    injected += '  touch ' + shlex.quote(str(out / 'mutation-reached')) + '\n'
    if a.failure == 'exit':
        injected += '  die "controlled laboratory migration failure"'
    else:
        injected += '  sleep 600\n  exit 91'
    candidate = out / 'candidate.sh'
    candidate.write_text(source.replace(marker, injected))
    started = time.monotonic()
    summary = dict(failure=a.failure, result='UNKNOWN')
    with (out / 'migration.log').open('w') as log:
        process = subprocess.Popen(['bash', str(candidate), 'migrate'], stdout=log, stderr=subprocess.STDOUT)
        try:
            if a.failure == 'kill':
                deadline = time.monotonic() + 180
                while not (out / 'mutation-reached').exists():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('candidate did not reach the injected pause')
                    time.sleep(0.25)
                meta = helper.load()
                if helper.pid_start(meta['owner']) != meta['owner_start']:
                    raise RuntimeError('supervisor PID identity changed')
                os.kill(meta['owner'], 9)
            rc = process.wait(timeout=240)
            deadline = time.monotonic() + 180
            while helper.load()['phase'] not in helper.TERMINAL:
                if time.monotonic() >= deadline:
                    raise RuntimeError('automatic rollback did not complete')
                time.sleep(1)
            meta = helper.load()
            after = hashes()
            runtime_after = runtime()
            states = {u: helper.unit_state(u) for u in helper.UNITS}
            summary.update(rc=rc, phase=meta['phase'], seconds=round(time.monotonic() - started, 3),
                           mutation_reached=(out / 'mutation-reached').exists(),
                           hashes_restored=after == before, runtime_restored=runtime_before == runtime_after,
                           services_restored=states == units, fallback_used=(out / 'fallback-used').exists())
            (out / 'after-hashes.json').write_text(json.dumps(after, indent=2) + '\n')
            (out / 'after-runtime.json').write_text(json.dumps(runtime_after, indent=2) + '\n')
            if (rc == 0 or meta['phase'] != 'ROLLED_BACK' or after != before or
                    runtime_after != runtime_before or states != units or summary['fallback_used'] or
                    not summary['mutation_reached']):
                raise RuntimeError('rollback verification failed; independent fallback remains armed')
            summary['result'] = 'PASS'
            subprocess.run(['systemctl', 'stop', unit + '.timer'], check=True)
        finally:
            (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
