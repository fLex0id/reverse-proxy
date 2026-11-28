#!/usr/bin/env python3
"""Check link firewall ownership on a spare port; never change installed rp state."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--port', type=int, default=19444)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise RuntimeError('use an unprivileged spare port')
    port = str(args.port) + '/tcp'
    query = subprocess.run(['firewall-cmd', '--query-port=' + port], capture_output=True)
    listeners = subprocess.check_output(['ss', '-ltnH', 'sport = :' + str(args.port)], text=True)
    if query.returncode != 1 or listeners.strip():
        raise RuntimeError('port must be closed in firewalld and have no listener')
    os.umask(0o077)
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=False)
    functions = out / 'functions'
    functions.write_text(Path(args.candidate).read_text().rsplit('main "$@"', 1)[0])
    unit = 'rp-lab-link-cleanup-' + uuid.uuid4().hex[:8]
    subprocess.run(['systemd-run', '--quiet', '--unit=' + unit, '--on-active=120',
                    '/usr/bin/firewall-cmd', '--remove-port=' + port], check=True)
    results = []
    try:
        for case in ['owned', 'preexisting', 'close-failure']:
            root = out / case
            root.mkdir()
            (root / 'serve').mkdir()
            (root / 'serve/result').write_text('ok\n')
            (root / 'serve/block.sh').write_text('fixture only\n')
            if case == 'preexisting':
                subprocess.run(['firewall-cmd', '--add-port=' + port], check=True, capture_output=True)
            script = r'''
source "$FUNCTIONS"
STATE=$TEST_DIR
fw_open_rt "$TEST_PORT/tcp" || exit 10
firewall-cmd() {
  if [[ $TEST_CASE == close-failure && $1 == --remove-port=* ]]; then return 1; fi
  command firewall-cmd "$@"
}
link_close "$TEST_PORT"
'''
            run = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                env=dict(os.environ, FUNCTIONS=str(functions), TEST_DIR=str(root),
                         TEST_CASE=case, TEST_PORT=str(args.port), RP_ASCII='0'), timeout=30)
            (root / 'private.log').write_text(run.stdout + run.stderr)
            open_now = subprocess.run(['firewall-cmd', '--query-port=' + port], capture_output=True).returncode == 0
            result = (root / 'link.result').read_text().strip()
            good = (run.returncode != 0 and open_now and result == 'cleanup-failed' and
                    (root / 'link.firewall').exists()) if case == 'close-failure' else (
                    run.returncode == 0 and open_now == (case == 'preexisting') and result == 'ok')
            good = good and not (root / 'serve').exists()
            results.append(dict(id=case, result='PASS' if good else 'FAIL', rc=run.returncode,
                                port_open_after=open_now, cleanup_result=result))
            if case == 'close-failure':
                retry = subprocess.run(['bash', '-c', 'source "$1"; STATE=$2; link_close "$3"',
                                        'bash', str(functions), str(root), str(args.port)], capture_output=True)
                results.append(dict(id='retry-cleanup', result='PASS' if retry.returncode == 0 and
                    not (root / 'link.firewall').exists() else 'FAIL', rc=retry.returncode))
            subprocess.run(['firewall-cmd', '--remove-port=' + port], capture_output=True, check=True)
    finally:
        cleanup = subprocess.run(['firewall-cmd', '--remove-port=' + port], capture_output=True)
        if cleanup.returncode == 0:
            subprocess.run(['systemctl', 'stop', unit + '.timer'], check=True)
    summary = dict(result='PASS' if all(x['result'] == 'PASS' for x in results) else 'FAIL', cases=results)
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    return 0 if summary['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
