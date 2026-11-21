#!/usr/bin/env python3
"""Real authenticated HY2/Salamander ACL checks with allowed-path packet control.

Run alone: no overlapping captures, transport changes or fault tests. Creates
only private temporary client config/processes; never changes the server ACL.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
for name in ['lab1', 'lab2', 'client', 'client-ip', 'output']:
    p.add_argument('--'+name, required=True)
a = p.parse_args()
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
root = Path(__file__).resolve().parent
rows = []


def run(host, command, label, input_text=None):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                       input=input_text, capture_output=True, text=True, timeout=60)
    (out/(label+'.log')).write_text(r.stdout+r.stderr)
    return r


def checked(host, command, label, input_text=None):
    r = run(host, command, label, input_text)
    if r.returncode:
        raise RuntimeError(label+' failed; inspect private log')
    return r


def launch(host, command, stdout, stderr):
    return subprocess.Popen(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host,
                             shlex.join(command)], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)


probe = 'ip netns exec rp-lab-client curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace -o /dev/null'
checked(a.client, probe, 'client-before')
version = checked(a.lab2, '/usr/local/bin/hysteria version', 'hysteria-version')
if '2.8.2' not in version.stdout:
    raise SystemExit('This fixture expects the pinned Hysteria 2.8.2')
controls = '''import json,socket,sys
rows=[]
for host,port in [('127.0.0.1',22),('127.0.0.1',1080),('127.0.0.1',10085),('127.0.0.1',7000),(sys.argv[1],22)]:
 with socket.create_connection((host,port),timeout=3): rows.append(dict(host=host,port=port,reachable=True))
print(json.dumps(rows))
'''
checked(a.lab1, shlex.join(['python3', '-c', controls, a.client_ip]), 'direct-listener-controls')
for transport, config in [('hy2-wg', 'hy2.yaml'), ('hy2o-wg', 'hy2o.yaml')]:
    token = uuid.uuid4().hex[:10]
    directory = '/root/rp-lab/acl-'+token
    service = 'rp-lab-acl-client-'+token
    capture_unit = 'rp-lab-acl-capture-'+token
    cap = out/(transport+'.pcap')
    client_process = capture_process = None
    handles = []
    try:
        checked(a.lab2, shlex.join(['install', '-d', '-m', '700', directory]), transport+'-private-dir')
        prepare = '''import os,socket,sys
from pathlib import Path
os.umask(0o077)
source=Path('/etc/rp')/sys.argv[1]
text=source.read_text()
assert text.count('udpForwarding:\\n') == 1
with socket.socket() as sock:
 sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
Path(sys.argv[2]+'/client.yaml').write_text(text.split('udpForwarding:\\n')[0]+'fastOpen: false\\nsocks5:\\n  listen: 127.0.0.1:%d\\n'%port)
print(port)
'''
        port = int(checked(a.lab2, shlex.join(['python3', '-c', prepare, config, directory]),
                           transport+'-prepare').stdout.strip())
        subprocess.run(['scp', '-q', str(root/'hy2_acl_probe.py'), a.lab2+':'+directory+'/probe.py'], check=True)
        packet_file = cap.open('wb'); handles.append(packet_file)
        packet_log = (out/(transport+'-capture.log')).open('w'); handles.append(packet_log)
        capture_process = launch(a.lab1, ['systemd-run', '--quiet', '--wait', '--pipe',
            '--unit='+capture_unit, '--property=RuntimeMaxSec=100', '/usr/sbin/tcpdump',
            '-i', 'any', '-U', '-nn', '-w', '-', 'udp'], packet_file, packet_log)
        for _ in range(50):
            if cap.stat().st_size >= 24:
                break
            if capture_process.poll() is not None:
                raise RuntimeError('Capture exited before readiness')
            time.sleep(0.1)
        if cap.stat().st_size < 24:
            raise RuntimeError('Capture header not received')
        checked(a.lab1, 'systemctl is-active --quiet '+capture_unit, transport+'-capture-active')
        client_log = (out/(transport+'-hysteria.log')).open('w'); handles.append(client_log)
        client_process = launch(a.lab2, ['systemd-run', '--quiet', '--wait', '--pipe',
            '--unit='+service, '--property=RuntimeMaxSec=100', '/usr/local/bin/hysteria',
            'client', '--disable-update-check', '-c', directory+'/client.yaml'], client_log, client_log)
        listen = 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),timeout=1).close()'
        ready = False
        for attempt in range(20):
            if run(a.lab2, shlex.join(['python3', '-c', listen, str(port)]), transport+'-listener-'+str(attempt)).returncode == 0:
                ready = True
                break
            time.sleep(0.25)
        if not ready:
            raise RuntimeError('Dedicated Hysteria SOCKS listener unavailable')
        result = checked(a.lab2, shlex.join(['python3', directory+'/probe.py', '--port', str(port),
                                            '--client-ip', a.client_ip]), transport+'-probes')
        items = json.loads(result.stdout)
        checked(a.lab2, 'systemctl is-active --quiet '+service, transport+'-client-still-active')
        time.sleep(1)
    finally:
        for host, unit in [(a.lab2, service), (a.lab1, capture_unit)]:
            run(host, 'systemctl stop '+unit, transport+'-stop-'+unit)
            run(host, 'systemctl reset-failed '+unit, transport+'-reset-'+unit)
        for process in [client_process, capture_process]:
            if process is not None:
                process.wait(timeout=15)
        for handle in handles:
            handle.close()
        checked(a.lab2, shlex.join(['rm', '-rf', directory]), transport+'-cleanup')
    captured = cap.read_bytes()
    positive = False
    for item in items:
        item['transport'] = transport
        if item['protocol'] == 'udp':
            occurrences = captured.count(item.pop('token').encode())
            item['captured_payloads'] = occurrences
            item.pop('reason')
            item['result'] = 'PASS' if bool(occurrences) == item['allowed'] else 'FAIL'
            if item['allowed']:
                positive = bool(occurrences)
        rows.append(item)
    if not positive:
        for item in rows:
            if item['transport'] == transport and item['result'] == 'PASS':
                item.update(result='UNKNOWN', reason='allowed UDP path not confirmed')
    (out/'results.json').write_text(json.dumps(rows, indent=2)+'\n')
    print(json.dumps(dict(transport=transport, cases=len(items), allowed_path=positive,
                         nonpassing=[r for r in items if r['result']!='PASS'])), flush=True)
checked(a.client, probe, 'client-after')
raise SystemExit(0 if rows and all(r['result']=='PASS' for r in rows) else 1)
