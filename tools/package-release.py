#!/usr/bin/env python3
"""Package an exact committed candidate; never publish or modify Git refs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if git('status', '--porcelain'):
        raise SystemExit('Commit the reviewed changes before packaging.')
    source = (ROOT / 'rp.sh').read_bytes()
    version = re.search(rb'^SELF_VERSION="([0-9A-Za-z._-]+)"$', source, re.M)
    if not version:
        raise SystemExit('Cannot determine script version.')
    version = version[1].decode('ascii')
    acceptance = json.loads((ROOT / 'reports/ACCEPTANCE.json').read_text())
    digest = hashlib.sha256(source).hexdigest()
    if acceptance.get('candidate_sha256') != digest:
        raise SystemExit('Candidate SHA256 differs from the acceptance record.')
    if acceptance.get('candidate_version') != version:
        raise SystemExit('Candidate version differs from the acceptance record.')
    commit = git('rev-parse', 'HEAD')
    manifest = dict(schema=1, tag='v' + version, script_version=version,
                    source_commit=commit, rp_sha256=digest,
                    channel=acceptance['release_channel'],
                    acceptance_verdict=acceptance['verdict'],
                    soak_status=acceptance['soak_status'])
    # An explicit allowlist keeps private configurations, captures, credentials
    # and unrelated untracked files out of downloadable release attachments.
    files = {
        'rp.sh': source,
        'RELEASE_NOTES_RU.md': (ROOT / 'reports/RELEASE_NOTES_RU.md').read_bytes(),
        'ACCEPTANCE.json': (ROOT / 'reports/ACCEPTANCE.json').read_bytes(),
        'BUILD.json': (json.dumps(manifest, indent=2) + '\n').encode(),
    }
    checksums = ''.join(hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
                        for name, data in sorted(files.items()))
    files['SHA256SUMS'] = checksums.encode()
    args.output.mkdir(parents=True, exist_ok=False)
    for name, data in files.items():
        target = args.output / name
        target.write_bytes(data)
        target.chmod(0o755 if name == 'rp.sh' else 0o644)
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
