#!/usr/bin/env python3
"""Package the exact committed candidate without publishing it."""
import argparse
import json
from pathlib import Path
import subprocess

from build import ROOT, assemble, digest


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if git('status', '--porcelain'):
        raise SystemExit('Commit the reviewed changes before packaging.')
    args.output.mkdir(parents=True, exist_ok=False)
    assemble(args.output)
    launcher = (args.output / 'rp.sh').read_bytes()
    if launcher != (ROOT / 'rp.sh').read_bytes():
        raise SystemExit('Generated bootstrap differs from the committed rp.sh.')
    build = args.output / 'BUILD.json'
    build.write_text(json.dumps(dict(schema=2, source_commit=git('rev-parse', 'HEAD'),
                                     bootstrap_sha256=digest(launcher)), indent=2) + '\n')
    with (args.output / 'SHA256SUMS').open('a') as sums:
        sums.write(f'{digest(build.read_bytes())}  {build.name}\n')


if __name__ == '__main__':
    main()
