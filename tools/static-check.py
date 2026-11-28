#!/usr/bin/env python3
"""Validate build outputs, sourced modules and embedded assets without installing."""
import json
import os
from pathlib import Path
import py_compile
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='rp-static-') as work:
    work = Path(work)
    dist, repeated, bundle = (work / name for name in ['dist', 'repeat', 'bundle'])
    for output in (dist, repeated):
        run(str(ROOT / 'tools/build.sh'), '--output', str(output))
    for artifact in dist.iterdir():
        assert artifact.read_bytes() == (repeated / artifact.name).read_bytes(), artifact.name
    assert (dist / 'rp.sh').read_bytes() == (ROOT / 'rp.sh').read_bytes(), 'rebuild rp.sh'
    archive, = dist.glob('rp-*.tar.gz')
    bundle.mkdir()
    run('tar', '-xzf', str(archive), '-C', str(bundle))
    dispatcher = bundle / 'dispatch.sh'
    library = work / 'functions.sh'
    library.write_text((dist / 'rp-single.sh').read_text().rsplit('main "$@"', 1)[0])
    generated = work / 'generated'
    run('bash', '-c', 'source "$1" && vps2_files "$2"', 'static', str(library), str(generated))
    generated_shells = [generated / 'usr/local/bin/rp', generated / 'usr/local/lib/rp/watch.sh',
                        generated / 'usr/local/lib/rp/ssh22.sh']
    bash_files = [*dist.glob('*.sh'), *bundle.rglob('*.sh'), *generated_shells,
                  *(ROOT / 'tools').glob('*.sh')]
    for path in bash_files:
        run('bash', '-n', str(path))
    if not shutil.which('shellcheck'):
        raise SystemExit('NOT_TESTED: shellcheck missing')
    sourced = subprocess.run(
        ['shellcheck', '-a', '-x', '-S', 'warning', '-P', str(bundle), '-f', 'json', str(dispatcher)],
        cwd=ROOT, capture_output=True, text=True)
    if sourced.returncode not in (0, 1):
        raise SystemExit(sourced.stderr or sourced.stdout)
    diagnostics = [row for row in json.loads(sourced.stdout)
                   if row['file'] != '/etc/os-release']
    if diagnostics:
        raise SystemExit(json.dumps(diagnostics, ensure_ascii=False, indent=2))
    run('shellcheck', '-S', 'warning', *map(str, [
        *dist.glob('*.sh'), *generated_shells, *(ROOT / 'tools').glob('*.sh')]))

    flake = shutil.which('pyflakes3') or shutil.which('pyflakes')
    if not flake:
        raise SystemExit('NOT_TESTED: pyflakes missing')
    python_paths = [*(ROOT / 'src/py').rglob('*.py'), *bundle.rglob('*.py'),
                    *(ROOT / 'tools').glob('*.py'), generated / 'usr/local/lib/rp/transaction.py']
    for index, path in enumerate(python_paths):
        py_compile.compile(str(path), cfile=str(work / f'check-{index}.pyc'), doraise=True)
    run(flake, *map(str, python_paths))
    run(str(ROOT / 'tools/compare-functions.sh'), '--dist', str(dist), '--allow-vps2-ssh22',
        '--allow-stream-up-sni-h2')

    module_names = (ROOT / 'src/modules.list').read_text().splitlines()
    module_names += ['main/distribution.sh', 'lib/python-sources.sh']
    for filename in module_names:
        module = bundle / filename
        run('bash', '--noprofile', '--norc', '-c', r'''
set -uo pipefail
snapshot() { declare -p | sed -E '/^declare .* (BASH_(ARGC|ARGV|LINENO|SOURCE|COMMAND|SUBSHELL)|LINENO|PIPESTATUS|_|RANDOM|SRANDOM|EPOCHREALTIME|EPOCHSECONDS|SECONDS)=/d'; }
before=$(snapshot)
source "$1" || exit
after=$(snapshot | sed '/^declare -- before=/d')
[[ $before == "$after" ]]
''', 'static', str(module), env=dict(os.environ, BASH_ENV='/dev/null'))

print('PASS: reproducible build, Bash syntax, ShellCheck warning+, Python compile/pyflakes, module loading and baseline comparison')
