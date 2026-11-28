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
SSH22_FUNCTIONS = {'vps2_files', 'vps2_installer'}
STREAM_SNI_FUNCTIONS = {'sni_choose', 'vps1_install'}
SSH22_PATH = 'usr/local/lib/rp/ssh22.sh'
OLD_SSH22_NOTICE = ('  rp_msg "SSH снаружи можно закрыть: доступ с VPS-1 по туннелю '
                    'сохранится (правило для 10.77.0.1)."\n').encode()


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
    parser.add_argument('--allow-vps2-ssh22', action='store_true',
                        help='Expect the separately reviewed VPS-2 TCP/22 policy change')
    parser.add_argument('--allow-stream-up-sni-h2', action='store_true',
                        help='Expect the stream-up-only SNI eligibility check')
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
        differences = DISTRIBUTION_CHANGES | (SSH22_FUNCTIONS if args.allow_vps2_ssh22 else set())
        if args.allow_stream_up_sni_h2:
            differences |= STREAM_SNI_FUNCTIONS
        results = [
            compare('rp-single.sh Bash', old_defs, single_defs, differences),
            compare('Bundle Bash', old_defs, mod_defs, differences | PYTHON_FUNCTIONS),
            compare('rp-single.sh Python', old_python, python_payloads(single_defs, single), set()),
            compare('Bundle Python', old_python, python_payloads(mod_defs, module, **env), set()),
        ]
        # Also compare the generated VPS-2 tree and complete installer output,
        # including embedded Bash functions and executable-file permissions.
        for name, script, settings in [('old', old, {}), ('single', single, {}),
                                       ('modular', module, env)]:
            run_shell('source "$1" && vps2_files "$2"', script, work / name, extra_env=settings)
        original = {p.relative_to(work / 'old'): p for p in (work / 'old').rglob('*') if p.is_file()}
        for name in ('single', 'modular'):
            generated = {p.relative_to(work / name): p for p in (work / name).rglob('*') if p.is_file()}
            additions = {Path(SSH22_PATH)} if args.allow_vps2_ssh22 else set()
            permitted = {Path('usr/local/bin/rp')} if args.allow_vps2_ssh22 else set()
            same = generated.keys() == original.keys() | additions
            if same:
                same = all(path.stat().st_mode == generated[rel].stat().st_mode and
                           (rel in permitted or path.read_bytes() == generated[rel].read_bytes())
                           for rel, path in original.items())
            old_dirs = {p.relative_to(work / 'old'): p.stat().st_mode
                        for p in (work / 'old').rglob('*') if p.is_dir()}
            new_dirs = {p.relative_to(work / name): p.stat().st_mode
                        for p in (work / name).rglob('*') if p.is_dir()}
            same &= old_dirs == new_dirs
            if same and additions:
                helper = generated[Path(SSH22_PATH)]
                same = helper.read_bytes() == (ROOT / 'src/vps2/runtime/ssh22.sh').read_bytes()
                same &= helper.stat().st_mode & 0o777 == 0o755
            print(f'VPS-2 generated files and modes ({name}): {"PASS" if same else "FAIL"}')
            results.append(same)
        fixture = work / 'fixture.tgz'
        fixture.write_bytes(b'deterministic fixture for vps2_installer\n')
        old_installer = installer(old, fixture)
        for name, script, settings in [('single', single, {}), ('modular', module, env)]:
            generated = installer(script, fixture, **settings)
            if args.allow_vps2_ssh22:
                generated, guard = re.subn(
                    rb'^  # BEGIN VPS2 SSH22 PUSH GUARD\n.*?^  # END VPS2 SSH22 PUSH GUARD\n',
                    b'', generated, flags=re.M | re.S)
                generated, offer = re.subn(
                    rb'^  # BEGIN VPS2 SSH22 OFFER\n.*?^  # END VPS2 SSH22 OFFER\n',
                    OLD_SSH22_NOTICE, generated, flags=re.M | re.S)
                same = guard == offer == 1 and old_installer == generated
            else:
                same = old_installer == generated
            print(f'VPS-2 installer with fixed payload ({name}): {"PASS" if same else "FAIL"}')
            results.append(same)
    raise SystemExit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
