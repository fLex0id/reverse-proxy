#!/usr/bin/env python3
"""Validate the shipped script and generated shell/Python assets, without install."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import py_compile
ROOT=Path(__file__).resolve().parents[1]
s=(ROOT/'rp.sh').read_text()
with tempfile.TemporaryDirectory() as tmp:
    d=Path(tmp);shell=d/'functions.sh'
    shell.write_text(s.rsplit('main "$@"',1)[0])
    py=d/'rp.py';py.write_text(s.split("py_source() { cat <<'RP_PY_EOF'\n",1)[1].split('\nRP_PY_EOF',1)[0])
    py_compile.compile(str(py),doraise=True)
    subprocess.run(['bash','-c','source "$1"; vps2_files "$2"','bash',str(shell),str(d/'generated')],check=True)
    bash_files=[ROOT/'rp.sh',d/'generated/usr/local/bin/rp',d/'generated/usr/local/lib/rp/watch.sh']
    for f in bash_files: subprocess.run(['bash','-n',str(f)],check=True)
    if not shutil.which('shellcheck'): raise SystemExit('NOT_TESTED: shellcheck missing')
    subprocess.run(['shellcheck','-S','warning',*(str(p) for p in bash_files)],check=True)
    for f in (py,ROOT/'src/transaction.py',d/'generated/usr/local/lib/rp/transaction.py'):
        py_compile.compile(str(f),doraise=True)
        if shutil.which('pyflakes3'): subprocess.run(['pyflakes3',str(f)],check=True)
        elif shutil.which('pyflakes'): subprocess.run(['pyflakes',str(f)],check=True)
        else: raise SystemExit('NOT_TESTED: pyflakes missing')
    embedded=s.split("transaction_source() { cat <<'RP_TRANSACTION_PY'\n",1)[1].split('RP_TRANSACTION_PY\n',1)[0]
    assert embedded==(ROOT/'src/transaction.py').read_text(),'transaction helper not regenerated'
print('PASS: Bash syntax, generated shells, ShellCheck warning+, Python compile/pyflakes, embedded helper consistency')
