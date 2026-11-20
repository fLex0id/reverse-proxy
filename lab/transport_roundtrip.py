#!/usr/bin/env python3
"""Real 4 -> 2 -> 4 deployment with retained management transport and cleanup.

Preserves a private VPS-1 configuration copy and restores it in finally. Every
push retains the complete configured T1-T3 validation. Uses independent SSH.
May expose stale legacy/WG configs; fixtures are removed only if still owned.
Never overlap another mutation/fault suite.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

TRANSPORTS = ['reality-xhttp2', 'reality-xhttp', 'hy2-wg', 'hy2o-wg']
CONFIGS = dict(zip(TRANSPORTS, ['xray-xhttp2.json', 'xray-xhttp.json', 'hy2.yaml', 'hy2o.yaml']))
p = argparse.ArgumentParser()
for arg in ['lab1', 'lab2', 'client', 'output']:
    p.add_argument('--' + arg, required=True)
p.add_argument('--keep', nargs=2, choices=TRANSPORTS, default=['reality-xhttp2', 'reality-xhttp'])
a = p.parse_args()
if len(set(a.keep)) != 2:
    p.error('select two different transports')
out = Path(a.output)
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
token = uuid.uuid4().hex
directory = '/root/rp-lab/order-' + token
rows = []

def remote(host, cmd, name, timeout=180):
    started = time.time()
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, cmd],
                       text=True, capture_output=True, timeout=timeout)
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    return r, time.time()-started

def required(host, cmd, name, timeout=180):
    r, elapsed = remote(host, cmd, name, timeout)
    rows.append(dict(id=name, result='PASS' if r.returncode==0 else 'FAIL', rc=r.returncode, seconds=elapsed))
    save()
    if r.returncode:
        raise RuntimeError(name+' failed; inspect log')
    return r

def save():
    (out/'results.json').write_text(json.dumps(rows, indent=2)+'\n')

def check(name, ok, detail):
    row = dict(id=name, result='PASS' if ok else 'FAIL', detail=detail)
    rows.append(row); save(); print(json.dumps(row), flush=True)

def functions(script, *args):
    return shlex.join(['bash', '-c', "source <(sed '$d' /usr/local/bin/rp)\nlock\nneed_vps1\n"+script, 'bash', *args])

def probe(stage):
    required(a.client, 'ip netns exec rp-lab-client curl -4 -fsS --max-time 20 https://1.1.1.1/cdn-cgi/trace -o /dev/null', stage+'-client')
    required(a.client, 'ip netns exec rp-lab-client python3 /root/rp-lab/dns-probe.py 8.8.8.8 example.com', stage+'-dns')
    required(a.client, shlex.join(['ip','netns','exec','rp-lab-client','curl','-4','-fsS',
        '--http3-only','--max-time','20','--resolve','cloudflare-dns.com:443:1.1.1.1',
        '-H','accept: application/dns-message','-o','/dev/null',
        'https://cloudflare-dns.com/dns-query?dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE']), stage+'-http3')

def inspect(stage, expected):
    code = '''import json,pathlib
root=pathlib.Path('/etc/rp')
conf={}
for line in (root/'rp2.conf').read_text().splitlines():
 if '=' in line:
  k,v=line.split('=',1);conf[k]=v.strip('"')
print(json.dumps(dict(order=conf['TRANSPORT_ORDER'].split(),
 configs={x:(root/x).exists() for x in ['hy2.yaml','hy2o.yaml','xray-xhttp.json','xray-xhttp2.json','xray-tcp.json','rp-wg.conf']},
 wg=pathlib.Path('/etc/wireguard/rp-wg.conf').exists(),
 phase=json.load(open('/var/lib/rp/transaction/state.json'))['phase'])))
'''
    r = required(a.lab2, shlex.join(['python3', '-c', code]), stage+'-inspect')
    state = json.loads(r.stdout)
    check(stage+'-order', set(state['order'])==set(expected), state['order'])
    check(stage+'-committed', state['phase']=='COMMITTED', state['phase'])
    for t, name in CONFIGS.items():
        check(stage+'-'+name, state['configs'][name]==(t in expected), state['configs'][name])
    check(stage+'-legacy-config-removed', not state['configs']['xray-tcp.json'], state['configs']['xray-tcp.json'])
    want_wg = any(t.startswith('hy2') for t in expected)
    check(stage+'-inner-wg-configs', state['configs']['rp-wg.conf']==want_wg and state['wg']==want_wg,
          dict(needed=want_wg, generated=state['configs']['rp-wg.conf'], installed=state['wg']))
    probe(stage)

original = required(a.lab1, functions('printf "%s\\n" "$(cf TRANSPORT_ORDER)"'), 'preflight-order').stdout.strip().split()
if set(original) != set(TRANSPORTS):
    raise SystemExit('Expected an existing four-transport lab installation')
required(a.lab1, functions('install -d -m 700 "$1" && cp -p "$CONF" "$1/rp.conf"', directory), 'backup-config')
identity_command = 'sha256sum /etc/rp/rp.conf /etc/rp/clients.tsv /etc/wireguard/wg0.conf /etc/rp/hy2.key /etc/rp/hy2.crt'
identity_before = required(a.lab1, identity_command, 'identity-before').stdout
created_legacy = False
try:
    required(a.lab1, 'rp tunnel '+a.keep[0], 'pin-retained', 420)
    code = '''import json,pathlib,sys
p=pathlib.Path('/etc/rp/xray-tcp.json')
if not p.exists():
 p.write_text(json.dumps({'rp_lab_fixture':sys.argv[1]})+'\\n');p.chmod(0o600);print('created')
else:print('existing')
'''
    r = required(a.lab2, shlex.join(['python3', '-c', code, token]), 'legacy-fixture')
    created_legacy = r.stdout.strip()=='created'
    required(a.lab1, functions('vps1_set TRANSPORT_ORDER "$1"', ' '.join(a.keep)), 'configure-two')
    required(a.lab1, 'rp push', 'push-two', 1800)
    inspect('two', a.keep)
finally:
    # Resolve any interrupted safe update before launching another push.
    code = "import json; print(json.load(open('/var/lib/rp/transaction/state.json'))['phase'])"
    r = required(a.lab2, shlex.join(['python3', '-c', code]), 'restore-transaction-state')
    if r.stdout.strip() not in ['COMMITTED', 'ROLLED_BACK']:
        required(a.lab2, 'python3 /var/lib/rp/transaction/runner.py rollback', 'resolve-pending', 300)
    required(a.lab1, functions('cp -p "$1/rp.conf" "$CONF" && conf_load && vps1_apply', directory), 'restore-four-config')
    required(a.lab1, 'rp push', 'restore-four-push', 1800)
    inspect('four', TRANSPORTS)
    required(a.lab1, 'rp tunnel auto', 'restore-auto', 420)
    identity_after = required(a.lab1, identity_command, 'identity-after').stdout
    check('identity-and-settings-preserved', identity_before==identity_after,
          'Complete configuration, clients, client WG and Hysteria certificate/key hashes')
    if created_legacy:
        code = '''import json,pathlib,sys
p=pathlib.Path('/etc/rp/xray-tcp.json')
if p.exists() and json.loads(p.read_text()).get('rp_lab_fixture')==sys.argv[1]:p.unlink()
'''
        required(a.lab2, shlex.join(['python3', '-c', code, token]), 'remove-owned-fixture')
    required(a.lab1, shlex.join(['rm', '-rf', directory]), 'remove-private-backup')
raise SystemExit(0 if all(r['result']=='PASS' for r in rows) else 1)
