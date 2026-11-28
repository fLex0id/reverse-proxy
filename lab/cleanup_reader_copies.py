#!/usr/bin/env python3
"""Remove only proven duplicate PCAP reader copies; retain controller originals."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--reader', required=True)
p.add_argument('--artifacts', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
out = Path(a.output)
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
manifest = {}
pattern = re.compile(r'reading from file (/root/rp-lab/(?:app|dns)-[a-f0-9]+-(lab1|lab2|client)\.pcap)')
for log in Path(a.artifacts).rglob('*packets.log'):
    for remote, label in pattern.findall(log.read_text(errors='replace')):
        original = log.parent/(label+'.pcap')
        if not original.is_file():
            continue
        digest = hashlib.sha256(original.read_bytes()).hexdigest()
        if remote in manifest and manifest[remote]['sha256'] != digest:
            raise SystemExit('Ambiguous controller original; nothing removed')
        manifest[remote] = dict(sha256=digest, original=str(original))
(out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
code = '''import hashlib,json,re,stat,sys
from pathlib import Path
rows=[]
for name,expected in json.load(sys.stdin).items():
 if not re.fullmatch(r'/root/rp-lab/(app|dns)-[a-f0-9]+-(lab1|lab2|client)\\.pcap',name):
  raise RuntimeError('Unowned reader path')
 p=Path(name)
 try: metadata=p.lstat()
 except FileNotFoundError:
  rows.append(dict(path=name,result='already-absent')); continue
 if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid!=0:
  rows.append(dict(path=name,result='REFUSED-file-type-or-owner')); continue
 if hashlib.sha256(p.read_bytes()).hexdigest()!=expected['sha256']:
  rows.append(dict(path=name,result='REFUSED-hash-mismatch')); continue
 p.unlink()
 rows.append(dict(path=name,result='removed-verified-duplicate',bytes=metadata.st_size))
print(json.dumps(rows))
'''
r = subprocess.run(['ssh', '-o', 'BatchMode=yes', a.reader, shlex.join(['python3', '-c', code])],
                   input=json.dumps(manifest), capture_output=True, text=True, timeout=120)
(out/'remote.log').write_text(r.stderr)
if r.returncode:
    raise SystemExit('Reader cleanup failed; inspect private log')
rows = json.loads(r.stdout)
(out/'results.json').write_text(json.dumps(rows, indent=2)+'\n')
print(json.dumps(dict(known_copies=len(rows), removed=sum(x['result']=='removed-verified-duplicate' for x in rows),
                     bytes_removed=sum(x.get('bytes',0) for x in rows),
                     refused=sum(x['result'].startswith('REFUSED') for x in rows))))
