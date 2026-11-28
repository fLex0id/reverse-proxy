#!/usr/bin/env python3
"""Build a reproducible rp payload and its Bash entry points."""
import argparse
import hashlib
import io
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'
PYTHON = {
    'transaction_source': ('transaction', 'RP_TRANSACTION_PY'),
    'migration_source': ('migration', 'RP_MIGRATION_PY'),
    'py_source': ('rp', 'RP_PY_EOF'),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def expand_shell(text):
    def expand(match):
        kind, name = match.groups()
        if kind == 'PY':
            path = SRC / 'py/snippets' / (name + '.py')
        else:
            path = SRC / 'vps2/runtime' / (name + '.sh')
        substituted = path.read_text()
        if not substituted.endswith('\n'):
            raise ValueError(f'missing final newline in {path}')
        return substituted.removesuffix('\n')

    return re.sub(r'^@(PY|VPS2):([a-z_]+)@$', expand, text, flags=re.M)


def python_functions(single):
    functions = []
    for name, (source, marker) in PYTHON.items():
        if single:
            code = (SRC / 'py' / (source + '.py')).read_text()
            if marker in code.splitlines() or not code.endswith('\n'):
                raise ValueError(f'invalid embedded payload {source}')
            functions.append(f"{name}() {{ cat <<'{marker}'\n{code}{marker}\n}}\n")
        else:
            functions.append(f'{name}() {{ cat -- "$RP_ROOT/py/{source}.py"; }}\n')
    return '\n'.join(functions)


def shell_template(name, **values):
    text = (SRC / 'main' / name).read_text()
    for key, value in values.items():
        text = text.replace('@' + key + '@', value)
    return text.encode()


def shell_module(name):
    return expand_shell((SRC / name).read_text())


def strip_shebang(text):
    return text.split('\n', 1)[1]


def assemble(output):
    version = (SRC / 'main/VERSION').read_text().strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+[-+a-zA-Z0-9.]*', version):
        raise ValueError('invalid rp version')
    modules = (SRC / 'modules.list').read_text().splitlines()
    if len(modules) != len(set(modules)) or not all(
            re.fullmatch(r'(?:lib|mod|vps2)/[a-z0-9-]+\.sh', name) for name in modules):
        raise ValueError('invalid or duplicate module path')
    init = (SRC / 'main/init.sh').read_text()
    if init.count('@VERSION@') != 1:
        raise ValueError('initialization must have exactly one version placeholder')
    single_init = init.replace('@VERSION@', version)
    runtime_init = init.replace('SELF_VERSION="@VERSION@"\n', '')
    body = {name: shell_module(name) for name in modules}
    distribution = shell_module('main/distribution.sh')
    single = ('\n'.join([single_init, *(strip_shebang(text) for text in body.values()),
                        strip_shebang(distribution), python_functions(single=True)])
              + '\nmain "$@"\n').encode()

    files = {name: text.encode() for name, text in body.items()}
    files['main/init.sh'] = runtime_init.encode()
    files['main/distribution.sh'] = distribution.encode()
    files['lib/python-sources.sh'] = ('#!/usr/bin/env bash\n\n' +
                                     python_functions(single=False)).encode()
    for name, _ in PYTHON.values():
        relative = 'py/' + name + '.py'
        files[relative] = (SRC / relative).read_bytes()
    files['rp-single.sh'] = single
    manifest = ''.join(f'{digest(data)}  {name}\n' for name, data in sorted(files.items())).encode()
    # Include the dispatcher template in the release identity without hashing a
    # dispatcher that already embeds that identity.
    release_id = digest(manifest + (SRC / 'main/dispatch.sh').read_bytes())
    source_list = ['main/init.sh', *modules, 'lib/python-sources.sh', 'main/distribution.sh']
    sources = '\n'.join(f'# shellcheck source={name}\nsource "$RP_ROOT/{name}" || exit 1'
                        for name in source_list)
    files['dispatch.sh'] = shell_template('dispatch.sh', VERSION=version,
                                          RELEASE_ID=release_id, SOURCES=sources)
    archive = 'rp-' + version + '.tar.gz'
    output.mkdir(parents=True, exist_ok=True)
    # GNU gzip -n makes compression independent of Python's platform zlib.
    with tempfile.TemporaryFile() as tar_bytes, (output / archive).open('wb') as compressed:
        with tarfile.open(fileobj=tar_bytes, mode='w', format=tarfile.USTAR_FORMAT) as bundle:
            directories = sorted({str(parent) for name in files for parent in Path(name).parents
                                  if parent != Path('.')})
            for directory in directories:
                item = tarfile.TarInfo(directory)
                item.type = tarfile.DIRTYPE
                item.mode = 0o755
                bundle.addfile(item)
            for name, data in sorted(files.items()):
                item = tarfile.TarInfo(name)
                item.mode = 0o755 if name in {'dispatch.sh', 'rp-single.sh'} else 0o644
                item.size = len(data)
                bundle.addfile(item, io.BytesIO(data))
        tar_bytes.seek(0)
        subprocess.run(['gzip', '-n', '-9', '-c'], stdin=tar_bytes, stdout=compressed, check=True)
    credentials = dict(VERSION=version, RELEASE_ID=release_id,
                       BUNDLE_SHA256=digest((output / archive).read_bytes()))
    # lab.23 demands these historical function markers and a minimum 32 KiB
    # before it will call a downloaded candidate. The real functions supply
    # those markers in the compatibility entry and are never called by it.
    migration = re.search(r'^migrate_apply\(\) \{\n.*?^\}$', body['mod/update.sh'],
                          re.M | re.S)[0]
    legacy = python_functions(single=True).split("py_source() {", 1)[1]
    bootstrap = shell_template('bootstrap.sh', **credentials, LEGACY='')
    compatibility = shell_template('bootstrap.sh', **credentials,
                                   LEGACY=migration + '\n\npy_source() {' + legacy)
    artifacts = {'rp.sh': bootstrap, 'rp-single.sh': single, 'rp-legacy-update.sh': compatibility}
    for name, data in artifacts.items():
        path = output / name
        path.write_bytes(data)
        path.chmod(0o755)
    checksums = ''.join(f'{digest((output / name).read_bytes())}  {name}\n'
                        for name in sorted([archive, *artifacts]))
    (output / 'SHA256SUMS').write_text(checksums)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    assemble(parser.parse_args().output)
