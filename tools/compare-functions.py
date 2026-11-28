#!/usr/bin/env python3
"""Compare function definitions and Python payloads to the baseline Git ref."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DISTRIBUTION_CHANGES = {
    'self_ok', 'self_explain_invalid', 'self_source', 'self_install',
    'self_upgrade', 'maybe_save_launched_build', 'cmd_uninstall',
}
PYTHON_FUNCTIONS = {'migration_source', 'transaction_source', 'py_source'}


def run_shell(body, *args, extra_env=None):
    return subprocess.check_output(
        ['bash', '--noprofile', '--norc', '-c', body, 'compare-functions', *map(str, args)],
        cwd=ROOT, env=dict(os.environ, RP_ASCII='0', **(extra_env or {})))


def library(text, target):
    head, call = text.rsplit('\nmain "$@"\n', 1)
    if call:
        raise ValueError('expected final entry point')
    target.write_text(head + '\n')
    return target


def definitions(path, **env):
    # stdout is a tty so the conditional palette helper c is also defined.
    master, slave = os.openpty()
    try:
        with tempfile.TemporaryFile() as dump:
            subprocess.run(
                ['bash', '--noprofile', '--norc', '-c', r'''source "$1" || exit
while read -r _ _ name; do
  printf '%s\0' "$name"
  declare -f "$name"
  printf '\0'
done < <(declare -F) >&"$2"
''', 'compare-functions', str(path), str(dump.fileno())],
                cwd=ROOT, stdout=slave, pass_fds=(dump.fileno(),), check=True,
                env=dict(os.environ, NO_COLOR='', RP_ASCII='0', **env))
            dump.seek(0)
            output = dump.read()
    finally:
        os.close(slave)
        os.close(master)
    pieces = output.rstrip(b'\0').split(b'\0')
    return dict(zip(map(bytes.decode, pieces[::2]), pieces[1::2], strict=True))


def python_payloads(defs, path, **env):
    payloads = {}
    for name in PYTHON_FUNCTIONS:
        payloads[name] = run_shell('source "$1" && "$2"', path, name, extra_env=env)
    for definition in defs.values():
        for match in re.finditer(
                rb"python3[^\n]*<<'((?:PY[A-Z_]*))'[^\n]*\n(.*?)^\1\n",
                definition, re.M | re.S):
            key = match[1].decode()
            if key in payloads:
                raise ValueError(f'duplicate Python heredoc {key}')
            payloads[key] = match[2]
        for match in re.finditer(rb"python3 -I -c '\n(.*?)^' ", definition, re.M | re.S):
            payloads['route_api_override -c'] = match[1]
    return payloads


def compare(label, baseline, candidate, expected):
    missing = sorted(baseline.keys() - candidate.keys())
    extra = sorted(candidate.keys() - baseline.keys())
    changed = sorted(k for k in baseline.keys() & candidate.keys() if baseline[k] != candidate[k])
    print(f'{label} baseline={len(baseline)} identical={len(baseline)-len(missing)-len(changed)} '
          f'changed={len(changed)} missing={len(missing)} extra={len(extra)}')
    print('  changed: ' + (', '.join(changed) or 'none'))
    print('  missing: ' + (', '.join(missing) or 'none'))
    print('  extra: ' + (', '.join(extra) or 'none'))
    unexpected = (set(changed) - expected) | set(missing)
    if unexpected:
        print('  UNEXPECTED: ' + ', '.join(sorted(unexpected)))
    return not unexpected


def installer(path, fixture, **env):
    output = run_shell('source "$1" && vps2_installer "$2"', path, fixture, extra_env=env)
    # The human-readable header embeds the enclosing VPS-1 release version.
    return re.sub(rb'^(# rp: [^\n]*' + 'версия '.encode() + rb')[a-zA-Z0-9.+-]+(?=\))', lambda match: match[1] + b'VERSION',
                  output, count=1, flags=re.M)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='v1.2.9-lab.23')
    parser.add_argument('--dist', required=True, type=Path)
    args = parser.parse_args()
    baseline = subprocess.check_output(['git', 'show', args.baseline + ':rp.sh'],
                                       cwd=ROOT, text=True)
    bundle, = args.dist.glob('rp-*.tar.gz')
    print(f'baseline={args.baseline} bundle_sha256={hashlib.sha256(bundle.read_bytes()).hexdigest()}')
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        old = library(baseline, work / 'old.sh')
        single = library((args.dist / 'rp-single.sh').read_text(), work / 'single.sh')
        package = work / 'package'
        package.mkdir()
        subprocess.run(['tar', '-xzf', str(bundle.resolve()), '-C', str(package)], check=True)
        dispatcher = (package / 'dispatch.sh').read_text()
        module = library(dispatcher, work / 'module.sh')
        identity = re.search(r'^RP_RELEASE_ID="([a-f0-9]{64})"$', dispatcher, re.M)[1]
        env = dict(RP_STAGE=str(package), RP_STAGE_ID=identity)
        old_defs, single_defs, mod_defs = definitions(old), definitions(single), definitions(module, **env)
        old_python = python_payloads(old_defs, old)
        legacy = args.dist / 'rp-legacy-update.sh'
        run_shell('source "$1" && self_ok "$2" && grep -qxF "migrate_apply() {" "$2"', old, legacy)
        print('lab.23 self_ok and migration marker (compatibility entry): PASS')
        results = [
            compare('rp-single.sh Bash', old_defs, single_defs, DISTRIBUTION_CHANGES),
            compare('Bundle Bash', old_defs, mod_defs, DISTRIBUTION_CHANGES | PYTHON_FUNCTIONS),
            compare('rp-single.sh Python', old_python, python_payloads(single_defs, single), set()),
            compare('Bundle Python', old_python, python_payloads(mod_defs, module, **env), set()),
        ]
        # Also compare the generated VPS-2 tree and complete installer output,
        # including embedded Bash functions and executable-file permissions.
        for name, script, settings in [('old', old, {}), ('single', single, {}),
                                       ('modular', module, env)]:
            run_shell('source "$1" && vps2_files "$2"', script, work / name, extra_env=settings)
        for name in ('single', 'modular'):
            same = subprocess.run(['diff', '-qr', str(work / 'old'), str(work / name)]).returncode == 0
            files = (work / 'old').rglob('*')
            same &= all(item.stat().st_mode == (work / name / item.relative_to(work / 'old')).stat().st_mode
                        for item in files)
            print(f'VPS-2 generated files and modes ({name}): {"PASS" if same else "FAIL"}')
            results.append(same)
        fixture = work / 'fixture.tgz'
        fixture.write_bytes(b'deterministic fixture for vps2_installer\n')
        old_installer = installer(old, fixture)
        for name, script, settings in [('single', single, {}), ('modular', module, env)]:
            same = old_installer == installer(script, fixture, **settings)
            print(f'VPS-2 installer with fixed payload ({name}): {"PASS" if same else "FAIL"}')
            results.append(same)
    raise SystemExit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
