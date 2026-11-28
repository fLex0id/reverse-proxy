#!/usr/bin/env python3
"""Bounded real ENOSPC for client staging and apply backups; installed rp untouched."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    out = Path(args.output).resolve()
    out.mkdir(parents=True, mode=0o700, exist_ok=False)
    functions = out / 'functions.sh'
    functions.write_text(Path(args.candidate).read_text().rsplit('main "$@"', 1)[0])
    results = []
    for case in ['client', 'apply']:
        root = out / case
        root.mkdir()
        fs = root / 'fs'
        fs.mkdir()
        subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=96k,mode=0700',
                        'rp-private-storage-fixture', str(fs)], check=True, timeout=15)
        try:
            target = fs / 'clients.tsv' if case == 'client' else root / 'installed'
            target.write_text('#' + 'x' * (40000 if case == 'client' else 160000) + '\n')
            target.chmod(0o600)
            before = hashlib.sha256(target.read_bytes()).hexdigest()
            common = r'''
source "$FUNCTIONS"
STATE=$TEST_DIR; CLIENTS=$STATE/fs/clients.tsv; BK_DIR=$STATE/fs/backups
ASSETS=$STATE; XRAY_BIN=/bin/true
need_vps1() { :; }; ask() { :; }; conf_load() { :; }
wg_pair() { echo 'fixture-private fixture-public'; }
wg() { echo fixture-psk; }
'''
            if case == 'client':
                action = r'''
py() { [[ $1 != next-ip ]] || echo 10.77.0.3; }
vps1_apply() { touch "$TEST_DIR/applied"; }
cl_add storage-fixture
'''
            else:
                action = r'''
py() {
  printf candidate >"$2/xray.json"
  printf 'xray.json|%s/installed|600|root:root|restart:fixture\n' "$TEST_DIR"
}
vps1_units_sync() { touch "$TEST_DIR/applied"; }
vps1_actions() { :; }; vps1_check() { :; }
vps1_apply
'''
            run = subprocess.run(['bash', '-c', common + action], capture_output=True,
                text=True, timeout=30, env=dict(os.environ, FUNCTIONS=str(functions),
                                              TEST_DIR=str(root), LC_ALL='C', RP_ASCII='0'))
            (root / 'private.log').write_text(run.stdout + run.stderr)
            entry = dict(id=case, rc=run.returncode,
                         enospc_observed='No space left on device' in run.stderr,
                         original_preserved=hashlib.sha256(target.read_bytes()).hexdigest() == before,
                         mode_preserved=target.stat().st_mode & 0o777 == 0o600,
                         application_not_reached=not (root / 'applied').exists(),
                         staging_removed=not list(fs.glob('.clients.*')) and
                                         not list(root.glob('stage.*')))
            entry['result'] = 'PASS' if (entry['rc'] != 0 and all(entry[k] for k in [
                'enospc_observed', 'original_preserved', 'mode_preserved',
                'application_not_reached', 'staging_removed'])) else 'FAIL'
            results.append(entry)
        finally:
            subprocess.run(['umount', str(fs)], check=True, timeout=15)
    summary = dict(result='PASS' if all(x['result'] == 'PASS' for x in results) else 'FAIL', cases=results)
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    return 0 if summary['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
