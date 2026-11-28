#!/usr/bin/env python3
"""Installed one-use link: real pinned HTTPS download, expiration and interruption.

The downloaded installer is kept private and is not executed by this runner.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['lab1', 'lab2', 'output']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    out = Path(args.output).resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    port = '19444'
    records = []

    def remote(host, command, name, timeout=30):
        r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                           text=True, capture_output=True, timeout=timeout)
        log = out / (name + '.log')
        log.write_text(r.stdout + r.stderr)
        log.chmod(0o600)
        return r

    preflight = remote(args.lab1, 'flock -n /run/rp.lock true || exit 1; '
                       '! systemctl is-active --quiet rp-serve || exit 1; '
                       '! test -e /var/lib/rp/link.firewall || exit 1; '
                       'test -z "$(ss -ltnH \'sport = :19444\')" || exit 1; '
                       'firewall-cmd --query-port=19444/tcp; test "$?" = 1', 'preflight')
    if preflight.returncode:
        raise RuntimeError('link service/port is not free or another operation owns the lock')
    for case in ['download', 'timeout', 'interrupt']:
        private = '/root/rp-lab/link-lifecycle-' + case + '-' + str(int(time.time()))
        if remote(args.lab1, 'install -d -m 700 ' + private, case + '-prepare').returncode:
            raise RuntimeError('cannot prepare private fixture directory')
        if remote(args.lab2, 'install -d -m 700 ' + private, case + '-prepare-lab2').returncode:
            raise RuntimeError('cannot prepare private download directory')
        script = 'echo $$ >' + shlex.quote(private + '/pid') + '; exec env RP_ASCII=0 '
        script += ('LINK_TTL=3 ' if case == 'timeout' else '') + '/usr/local/bin/rp link ' + port
        path = out / (case + '-command.log')
        with path.open('w') as log:
            path.chmod(0o600)
            proc = subprocess.Popen(['ssh', args.lab1, shlex.join(['bash', '-c', script])],
                                    stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 90
                match = None
                while proc.poll() is None and time.monotonic() < deadline:
                    match = re.search(r'curl -fsSk --pinnedpubkey (sha256//[A-Za-z0-9+/=]+) (https://[^\s|]+)\|bash', path.read_text())
                    if match:
                        break
                    time.sleep(0.2)
                if not match:
                    raise RuntimeError('link did not produce a pinned URL; inspect private log')
                detail = {}
                if case == 'download':
                    expected = remote(args.lab1, 'sha256sum /var/lib/rp/serve/block.sh', 'served-hash')
                    dest = private + '/block.sh'
                    command = shlex.join(['curl', '-fsSk', '--max-time', '20', '--pinnedpubkey',
                                         match[1], match[2], '-o', dest])
                    download = remote(args.lab2, 'umask 077; ' + command, 'download-file')
                    actual = remote(args.lab2, 'sha256sum ' + dest, 'downloaded-hash')
                    same = (expected.returncode == actual.returncode == download.returncode == 0 and
                            expected.stdout.split()[0] == actual.stdout.split()[0])
                    retry = remote(args.lab2, shlex.join(['curl', '-fsSk', '--max-time', '5', '--pinnedpubkey',
                                                        match[1], match[2], '-o', '/dev/null']), 'reuse')
                    detail = dict(download_matches=same, reuse_rejected=retry.returncode in (7, 22))
                elif case == 'interrupt':
                    signal = remote(args.lab1, 'python3 - ' + shlex.quote(private + '/pid') + " <<'PY'\n"
                        "import os,signal,sys\nfrom pathlib import Path\npid=int(Path(sys.argv[1]).read_text())\n"
                        "argv=Path('/proc/%d/cmdline'%pid).read_bytes().split(b'\\0')\n"
                        "assert b'/usr/local/bin/rp' in argv and b'link' in argv\nos.kill(pid,signal.SIGTERM)\nPY", 'interrupt-signal')
                    if signal.returncode:
                        raise RuntimeError('cannot identify and interrupt owned link process')
                rc = proc.wait(timeout=60)
                cleanup = remote(args.lab1, '! systemctl is-active --quiet rp-serve && '
                    'test ! -d /var/lib/rp/serve && test ! -f /var/lib/rp/link.firewall && '
                    'test -z "$(ss -ltnH \'sport = :19444\')" && '
                    'test "$(firewall-cmd --query-port=19444/tcp)" = no', case + '-cleanup')
                result = remote(args.lab1, 'cat /var/lib/rp/link.result', case + '-result')
                good = cleanup.returncode == 0 and rc == {'download': 0, 'timeout': 1, 'interrupt': 130}[case]
                if case != 'interrupt':
                    good = good and result.stdout.strip() == ('ok' if case == 'download' else 'timeout')
                if case == 'download':
                    good = good and all(detail.values())
                row = dict(id=case, result='PASS' if good else 'FAIL', rc=rc,
                           cleanup_ok=cleanup.returncode == 0, detail=detail)
                records.append(row)
                (out / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
                print(json.dumps(row), flush=True)
            finally:
                if proc.poll() is None:
                    remote(args.lab1, 'systemctl stop rp-serve', case + '-emergency-stop')
                    proc.terminate()
                    proc.wait(timeout=10)
        if records[-1]['result'] != 'PASS':
            raise RuntimeError('link acceptance failed; inspect before continuing')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
