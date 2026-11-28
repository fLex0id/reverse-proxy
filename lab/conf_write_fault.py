#!/usr/bin/env python3
"""Real ENOSPC in a bounded private tmpfs; never touches installed rp files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline', required=True)
    p.add_argument('--candidate', required=True)
    p.add_argument('--output', required=True)
    a = p.parse_args()
    out = Path(a.output).resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.umask(0o077)
    original = '#' + 'p' * 40000 + '\nCHANGE="old"\n'
    expected_hash = hashlib.sha256(original.encode()).hexdigest()
    results = []
    for label, path in [('baseline', a.baseline), ('candidate', a.candidate)]:
        folder = out / label
        folder.mkdir(mode=0o700)
        functions = folder / 'functions.sh'
        functions.write_text(Path(path).read_text().rsplit('main "$@"', 1)[0])
        filesystem = folder / 'fs'
        filesystem.mkdir(mode=0o700)
        subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=96k,mode=0700',
                        'rp-conf-write-fixture', str(filesystem)], check=True, timeout=15)
        try:
            conf = filesystem / 'rp.conf'
            conf.write_text(original)
            conf.chmod(0o600)
            script = '''source "$1"
ETC=$2; CONF=$ETC/rp.conf
conf_set CHANGE new
printf 'WRITE_RETURNED_SUCCESS\n'
'''
            r = subprocess.run(['bash', '-c', script, 'bash', str(functions), str(filesystem)],
                               capture_output=True, text=True, timeout=30)
            (folder / 'write.log').write_text(r.stdout + r.stderr)
            actual_hash = hashlib.sha256(conf.read_bytes()).hexdigest()
            results.append(dict(id=label, rc=r.returncode,
                                enospc_observed='No space left on device' in r.stderr,
                                original_preserved=actual_hash == expected_hash,
                                config_mode=oct(conf.stat().st_mode & 0o777),
                                staging_removed=not list(filesystem.glob('.rp.*')),
                                success_reported='WRITE_RETURNED_SUCCESS' in r.stdout))
        finally:
            subprocess.run(['umount', str(filesystem)], check=True, timeout=15)
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    candidate = results[-1]
    passed = (candidate['enospc_observed'] and candidate['rc'] != 0 and
              candidate['original_preserved'] and candidate['staging_removed'] and
              candidate['config_mode'] == '0o600' and not candidate['success_reported'])
    print(json.dumps(dict(result='PASS' if passed else 'FAIL', cases=results)), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
