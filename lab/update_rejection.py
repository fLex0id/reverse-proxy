#!/usr/bin/env python3
"""Installed updater must reject unavailable/corrupt downloads without mutation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def snapshot():
    files = ['/usr/local/bin/rp', '/etc/rp/rp.conf', '/etc/rp/clients.tsv']
    return dict(files={p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in files},
                pids=subprocess.check_output(['systemctl', 'show', 'rp-xray', 'rp-net', 'rp-hy2',
                                              'rp-hy2o', '-p', 'MainPID'], text=True),
                staging=sorted(str(p) for p in Path('/tmp').glob('rp-update.*')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=False)
    garbage = out / 'garbage.sh'
    garbage.write_text('not an rp installer\n')
    syntax = out / 'syntax.sh'
    syntax.write_text(Path('/usr/local/bin/rp').read_text() + '\n)\n')
    before = snapshot()
    results = []
    for name, url in [('unavailable', (out / 'missing.sh').as_uri()),
                      ('garbage', garbage.as_uri()), ('syntax', syntax.as_uri())]:
        run = subprocess.run(['/usr/local/bin/rp', 'update'], env=dict(os.environ, RP_URL=url, RP_ASCII='0'),
                             text=True, capture_output=True, timeout=90)
        (out / (name + '.log')).write_text(run.stdout + run.stderr)
        same = snapshot() == before
        results.append(dict(id=name, rc=run.returncode, state_unchanged=same,
                            result='PASS' if run.returncode != 0 and same else 'FAIL'))
    summary = dict(result='PASS' if all(x['result'] == 'PASS' for x in results) else 'FAIL', cases=results)
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    return 0 if summary['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
