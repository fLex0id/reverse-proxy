#!/usr/bin/env python3
"""Decode complete LAB-1 PCAPs without filtering on its underlay source address.

Internal-source kernel replies must not disappear from leak review. This tool
collects packet/address/DNS evidence; it deliberately does not infer policy PASS
from zero counts or decide which observed names are permitted. Inspect the raw
logs alongside positive LAB-2/client captures and the exact configured policy.
The reader is an authorized lab SSH host with tcpdump installed.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import shlex
import subprocess
import uuid

p = argparse.ArgumentParser()
p.add_argument('--directory', required=True)
p.add_argument('--reader', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
root = Path(a.directory)
out = Path(a.output)
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
rows = []
captures = sorted(root.rglob('lab1.pcap'))
if not captures:
    raise SystemExit('No LAB-1 captures found')
for index, capture in enumerate(captures):
    remote = '/root/rp-lab/review-' + uuid.uuid4().hex + '.pcap'
    try:
        subprocess.run(['scp', '-q', str(capture), a.reader + ':' + remote], check=True)
        result = subprocess.run(['ssh', '-o', 'BatchMode=yes', a.reader,
            shlex.join(['tcpdump', '-nn', '-tttt', '-r', remote])],
            capture_output=True, text=True, timeout=60, check=True)
    finally:
        subprocess.run(['ssh', '-o', 'BatchMode=yes', a.reader,
                        shlex.join(['rm', '-f', remote])], check=True, timeout=20)
    log = f'{index:02d}-all-packets.log'
    (out / log).write_text(result.stdout + result.stderr)
    sources = Counter()
    targets = Counter()
    questions = Counter()
    unparsed = []
    for line in result.stdout.splitlines():
        match = re.search(r' IP6? (\S+) > (\S+): ', line)
        if match:
            sources[match[1]] += 1
            targets[match[2]] += 1
        else:
            unparsed.append(line)
        question = re.search(r'\b(A|AAAA|HTTPS|SVCB)\? (\S+) ', line)
        if question:
            questions[question[1] + ' ' + question[2]] += 1
    row = dict(capture=str(capture.relative_to(root)), log=log,
               packets=len(result.stdout.splitlines()), sources=dict(sources),
               destinations=dict(targets), dns_questions=dict(questions),
               unparsed=unparsed, policy_verdict='REQUIRES_REVIEW')
    rows.append(row)
    (out / 'summary.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps(dict(capture=row['capture'], packets=row['packets'],
                          dns_questions=row['dns_questions'], unparsed=len(unparsed))), flush=True)
