#!/usr/bin/env python3
"""Real SSH terminal menu lock checks during an already running migration test."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    out = Path(args.output).resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    probe = subprocess.run(['ssh', args.host, 'flock -n /run/rp.lock true'], capture_output=True)
    if probe.returncode != 1:
        raise RuntimeError('no existing operation lock; refuse to run menu mutations')
    results = []
    for ascii_mode in [0, 1]:
        proc = subprocess.Popen(['ssh', '-tt', '-o', 'BatchMode=yes', args.host,
                                 f'RP_ASCII={ascii_mode} /usr/local/bin/rp menu'],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        transcript = bytearray()

        def expect(needle, start=0):
            deadline = time.monotonic() + 20
            while needle not in transcript[start:]:
                if time.monotonic() >= deadline or proc.poll() is not None:
                    raise RuntimeError('terminal expectation not observed')
                ready, _, _ = select.select([proc.stdout], [], [], 0.5)
                if ready:
                    data = os.read(proc.stdout.fileno(), 65536)
                    if not data:
                        raise RuntimeError('terminal closed')
                    transcript.extend(data)

        try:
            expect(b'> ')
            for option in [11, 13, 14]:
                offset = len(transcript)
                proc.stdin.write((str(option) + '\n').encode())
                proc.stdin.flush()
                phrase = ('Drugaya operatsiya rp uzhe vypolnyaetsya' if ascii_mode else
                          'Другая операция rp уже выполняется').encode()
                expect(phrase, offset)
                expect(('Lyubaya klavisha' if ascii_mode else 'Любая клавиша').encode(), offset)
                results.append(dict(mode='ascii' if ascii_mode else 'unicode', option=option, result='PASS'))
                offset = len(transcript)
                proc.stdin.write(b'x')
                proc.stdin.flush()
                expect(b'> ', offset)
            proc.stdin.write(b'0\n')
            proc.stdin.flush()
            proc.wait(timeout=10)
            if proc.returncode != 0:
                raise RuntimeError('menu exit failed')
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=10)
            (out / ('menu-' + str(ascii_mode) + '.log')).write_bytes(transcript)
            proc.stdin.close()
            proc.stdout.close()
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results), flush=True)


if __name__ == '__main__':
    main()
