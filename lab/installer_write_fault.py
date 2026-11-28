#!/usr/bin/env python3
"""Scoped installer failure or SIGKILL followed by real boot recovery.

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
    'config-permission', 'daemon-reload', 'xray-download', 'hy2-download',
    'xray-checksum', 'hy2-checksum', 'xray-extract', 'bundle-extract',
    'nat-service', 'firewall-reload', 'sysctl-apply'])
p.add_argument('--failure', choices=['command', 'kill-reboot'], default='command')
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
hash_cmd = ('sha256sum /etc/rp/rp2.conf /usr/local/bin/xray /usr/local/bin/hysteria '
            '/usr/local/bin/rp /usr/local/lib/rp/transaction.py /etc/wireguard/rp-wg.conf')
before = remote(a.lab2, hash_cmd, 'hashes-before')
if before.returncode:
    raise SystemExit('Cannot record baseline')
staging_clear = 'test ! -e /usr/local/bin/xray.new && test ! -e /usr/local/bin/hysteria.new'
if remote(a.lab2, staging_clear, 'staging-before').returncode:
    raise SystemExit('Pre-existing staging files require inspection; no fault injected')
old_boot = remote(a.lab2, 'cat /proc/sys/kernel/random/boot_id', 'boot-before')
if old_boot.returncode:
    raise SystemExit('Cannot inspect boot identity')

wrapper = '''#!/usr/bin/env bash
stage=@STAGE@
failure=@FAILURE@
tool=${0##*/}; inject=0
case "$stage:$tool:$*" in
  xray-stage:install:*'/usr/local/bin/xray.new'|xray-publish:mv:*'/usr/local/bin/xray'|\
hy2-stage:install:*'/usr/local/bin/hysteria.new'|hy2-publish:mv:*'/usr/local/bin/hysteria'|\
assets-dir:install:'-d -m 755 /usr/local/share/rp'|assets-write:install:'-m 644 '*'/usr/local/share/rp/'|\
wg-config:install:*'/etc/wireguard/rp-wg.conf'|config-permission:chmod:'750 /etc/rp'|\
daemon-reload:systemctl:'daemon-reload'|nat-service:systemctl:'restart rp-nat'|firewall-reload:firewall-cmd:'--reload'|sysctl-apply:sysctl:'-q -p /etc/sysctl.d/99-rp.conf'|xray-download:curl:*'/x.zip '*|hy2-download:curl:*'/h '*|xray-checksum:curl:*'/x.zip '*|hy2-checksum:curl:*'/h '*|xray-extract:unzip:*|bundle-extract:tar:'-xzf '*) inject=1 ;;
esac
if ((inject)) && [[ ! -e ${0%/*}/hit || $stage == *-download ]]; then
  phase=$(/usr/bin/python3 -c "import json; print(json.load(open('/var/lib/rp/transaction/state.json'))['phase'])") || exit 2
  if [[ $phase == INSTALLING ]]; then
    : >"${0%/*}/hit"
    echo "$stage" >>"${0%/*}/attempts"
    if [[ $failure == kill-reboot ]]; then
      /usr/bin/python3 - "${0%/*}/killed.json" <<'PY'
import json, os, signal, sys
from pathlib import Path
m = json.load(open('/var/lib/rp/transaction/state.json'))
pid = m['pid']
assert m['phase'] == 'INSTALLING'
assert Path('/proc/%d/stat' % pid).read_text().split()[21] == m['pid_start']
record = dict(pid=pid, phase=m['phase'],
              xray_staged=Path('/usr/local/bin/xray.new').exists(),
              hysteria_staged=Path('/usr/local/bin/hysteria.new').exists())
with open(sys.argv[1], 'w') as f:
    json.dump(record, f); f.flush(); os.fsync(f.fileno())
os.kill(pid, signal.SIGKILL)
PY
      exit 137
    fi
    echo "RP_LAB_INJECTED_WRITE_FAILURE: $stage" >&2
    if [[ $stage == *-checksum ]]; then
      previous=''
      for arg; do
        if [[ $previous == -o ]]; then printf 'corrupt laboratory payload\n' >"$arg"; exit 0; fi
        previous=$arg
      done
      exit 2
    fi
    exit 1
  fi
fi
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec "$tool" "$@"
'''.replace('@STAGE@', shlex.quote(a.stage)).replace('@FAILURE@', shlex.quote(a.failure))
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
    command = shlex.join(['bash', '-c', 'for tool in mv chmod systemctl curl unzip tar firewall-cmd sysctl; do cp "$1/install" "$1/$tool" || exit 1; done', 'bash', directory])
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
    attempts = remote(a.lab2, shlex.join(['cat', directory+'/attempts']), 'fault-attempts')
    result = dict(stage=a.stage, failure=a.failure, installer_rc=r.returncode, observed_phase=phase, injected=hit,
                  injection_attempts=len(attempts.stdout.splitlines()) if attempts.returncode==0 else 0,
                  seconds=time.time()-started,
                  result='PASS' if hit and r.returncode != 0 and phase=='ROLLED_BACK' else 'FAIL')
    if a.failure == 'kill-reboot':
        result['result'] = 'FAIL'
        evidence = remote(a.lab2, shlex.join(['cat', directory+'/killed.json']), 'kill-evidence')
        if not hit or r.returncode == 0 or phase != 'INSTALLING' or evidence.returncode:
            raise RuntimeError('Expected SIGKILL in INSTALLING was not confirmed; no reboot')
        result['kill_evidence'] = json.loads(evidence.stdout)
        # Keep the real 30-minute deadline unchanged. Reboot invokes the installed
        # boot recovery service; no fixture calls rollback before observing it.
        reboot_started = time.monotonic()
        remote(a.lab2, 'sync && systemctl reboot', 'request-reboot', 30)
        boot_changed = False
        recovered = False
        while time.monotonic() - reboot_started < 240:
            try:
                probe = remote(a.lab2, 'cat /proc/sys/kernel/random/boot_id', 'boot-probe', 12)
                if probe.returncode == 0 and probe.stdout.strip() != old_boot.stdout.strip():
                    if not boot_changed:
                        result['ssh_return_seconds'] = time.monotonic() - reboot_started
                    boot_changed = True
                    if state()['phase'] == 'ROLLED_BACK':
                        recovered = True
                        break
            except subprocess.TimeoutExpired:
                pass
            time.sleep(3)
        result.update(boot_changed=boot_changed, automatic_boot_rollback=recovered,
                      boot_recovery_seconds=time.monotonic()-reboot_started)
        if boot_changed and recovered:
            result['result'] = 'PASS'
        remote(a.lab2, 'journalctl -b -u rp-transaction-recover --no-pager', 'boot-recovery-journal')
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
        remote(a.lab2, 'systemctl reset-failed '+unit, 'clear-fixture-unit')
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
