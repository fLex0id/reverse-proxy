#!/usr/bin/env python3
"""One real VPS-2 installer write failure, full transaction and restoration.

Uses a private one-shot install wrapper, scoped to this installer process and
one exact binary staging path. Does not fill the disk or change the system PATH.
Baseline installers can incorrectly continue to READY; explicitly roll them back.
Requires independent management SSH. Never overlap another mutation/fault suite.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
for arg in ['lab1', 'lab2', 'client', 'output']:
    p.add_argument('--' + arg, required=True)
p.add_argument('--stage', default='xray-stage', choices=['xray-stage', 'xray-publish',
    'assets-dir', 'assets-write', 'hy2-stage', 'hy2-publish', 'wg-config',
    'config-permission', 'daemon-reload'])
a = p.parse_args()
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
token = uuid.uuid4().hex[:10]
directory = '/root/rp-lab/write-fault-' + token
unit = 'rp-lab-write-fault-' + token

def remote(host, command, name, timeout=60, input_text=None):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                       input=input_text, text=True, capture_output=True, timeout=timeout)
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    return r

def state():
    code = "import json; print(json.dumps(json.load(open('/var/lib/rp/transaction/state.json'))))"
    r = remote(a.lab2, shlex.join(['python3', '-c', code]), 'transaction-state')
    if r.returncode:
        raise RuntimeError('Cannot inspect transaction')
    return json.loads(r.stdout)

client_probe = 'ip netns exec rp-lab-client curl -4 -fsS --max-time 15 https://1.1.1.1/cdn-cgi/trace -o /dev/null'
if state()['phase'] not in ['COMMITTED', 'ROLLED_BACK']:
    raise SystemExit('Existing unresolved transaction; no fault injected')
if remote(a.client, client_probe, 'client-before').returncode:
    raise SystemExit('Client not healthy; no fault injected')
hash_cmd = 'sha256sum /etc/rp/rp2.conf /usr/local/bin/xray /usr/local/bin/hysteria /usr/local/bin/rp'
before = remote(a.lab2, hash_cmd, 'hashes-before')
if before.returncode:
    raise SystemExit('Cannot record baseline')
staging_clear = 'test ! -e /usr/local/bin/xray.new && test ! -e /usr/local/bin/hysteria.new'
if remote(a.lab2, staging_clear, 'staging-before').returncode:
    raise SystemExit('Pre-existing staging files require inspection; no fault injected')

wrapper = '''#!/usr/bin/env bash
stage=@STAGE@
tool=${0##*/}; inject=0
case "$stage:$tool:$*" in
  xray-stage:install:*'/usr/local/bin/xray.new'|xray-publish:mv:*'/usr/local/bin/xray'|\
hy2-stage:install:*'/usr/local/bin/hysteria.new'|hy2-publish:mv:*'/usr/local/bin/hysteria'|\
assets-dir:install:'-d -m 755 /usr/local/share/rp'|assets-write:install:'-m 644 '*'/usr/local/share/rp/'|\
wg-config:install:*'/etc/wireguard/rp-wg.conf'|config-permission:chmod:'750 /etc/rp'|\
daemon-reload:systemctl:'daemon-reload') inject=1 ;;
esac
if ((inject)) && [[ ! -e ${0%/*}/hit ]]; then
  phase=$(/usr/bin/python3 -c "import json; print(json.load(open('/var/lib/rp/transaction/state.json'))['phase'])") || exit 2
  if [[ $phase == INSTALLING ]]; then
    : >"${0%/*}/hit"
    echo "RP_LAB_INJECTED_WRITE_FAILURE: $stage" >&2
    exit 1
  fi
fi
exec "/usr/bin/$tool" "$@"
'''.replace('@STAGE@', shlex.quote(a.stage))
attempted = False
try:
    generate = "source <(sed '$d' /usr/local/bin/rp)\nlock\nblock_make \"$1\" single\n"
    r = remote(a.lab1, shlex.join(['bash', '-c', generate, 'bash', directory]), 'generate-bundle', 180)
    if r.returncode:
        raise RuntimeError('Bundle generation failed')
    block = out/'block.sh'
    subprocess.run(['scp', '-q', a.lab1+':'+directory+'/block.sh', str(block)], check=True)
    block.chmod(0o600)
    r = remote(a.lab2, shlex.join(['install', '-d', '-m', '700', directory]), 'prepare-fixture')
    if r.returncode:
        raise RuntimeError('Fixture directory failed')
    subprocess.run(['scp', '-q', str(block), a.lab2+':'+directory+'/block.sh'], check=True)
    command = 'umask 077; cat >' + shlex.quote(directory+'/install') + '; chmod 700 ' + shlex.quote(directory+'/install')
    if remote(a.lab2, command, 'install-fixture', input_text=wrapper).returncode:
        raise RuntimeError('Cannot install scoped fault fixture')
    command = shlex.join(['bash', '-c', 'for tool in mv chmod systemctl; do cp "$1/install" "$1/$tool" || exit 1; done', 'bash', directory])
    if remote(a.lab2, command, 'install-fixture-tools').returncode:
        raise RuntimeError('Cannot install scoped command wrappers')
    attempted = True
    started = time.time()
    command = shlex.join(['systemd-run', '--quiet', '--wait', '--pipe', '--unit='+unit,
        '--property=RuntimeMaxSec=900', '/usr/bin/env', 'RP_SAFE=1',
        'PATH='+directory+':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        '/bin/bash', directory+'/block.sh'])
    r = remote(a.lab2, command, 'installer', timeout=960)
    phase = state()['phase']
    hit = remote(a.lab2, shlex.join(['test', '-f', directory+'/hit']), 'fault-hit').returncode == 0
    result = dict(stage=a.stage, installer_rc=r.returncode, observed_phase=phase, injected=hit,
                  seconds=time.time()-started,
                  result='PASS' if hit and r.returncode != 0 and phase=='ROLLED_BACK' else 'FAIL')
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result), flush=True)
finally:
    if attempted:
        remote(a.lab2, 'systemctl stop '+unit, 'stop-installer')
        phase = state()['phase']
        if phase not in ['COMMITTED', 'ROLLED_BACK']:
            r = remote(a.lab2, 'python3 /var/lib/rp/transaction/runner.py rollback', 'explicit-rollback', 180)
            if r.returncode:
                raise RuntimeError('Recovery failed; keep fixture/evidence for inspection')
    for host in [a.lab1, a.lab2]:
        remote(host, shlex.join(['rm', '-rf', directory]), 'cleanup-'+host)
    (out/'block.sh').unlink(missing_ok=True)
after = remote(a.lab2, hash_cmd, 'hashes-after')
healthy = remote(a.client, client_probe, 'client-after')
watch = remote(a.lab2, 'systemctl is-active --quiet rp-watch', 'watch-after')
staged = remote(a.lab2, staging_clear, 'staging-after')
result.update(restored_hashes=after.returncode==0 and before.stdout==after.stdout,
              client_restored=healthy.returncode==0, watch_restored=watch.returncode==0,
              staging_removed=staged.returncode==0,
              final_phase=state()['phase'])
if not all(result[k] for k in ['restored_hashes','client_restored','watch_restored','staging_removed']):
    result['result']='FAIL'
(out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result), flush=True)
raise SystemExit(0 if result['result']=='PASS' else 1)
