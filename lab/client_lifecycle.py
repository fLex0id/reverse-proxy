#!/usr/bin/env python3
"""Real add/show/duplicate/delete and simultaneous traffic from two lab clients."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['lab1', 'client', 'lab1-ip', 'output']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    out = Path(args.output).resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    records = []
    client_name = 'lab-release-two'
    remote_dir = '/root/rp-lab/client-lifecycle-' + str(int(time.time()))

    def remote(host, command, name, timeout=180):
        result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                                capture_output=True, text=True, timeout=timeout)
        log = out / (name + '.log')
        log.write_text(result.stdout + result.stderr)
        log.chmod(0o600)
        return result

    def record(name, passed, detail=None):
        row = dict(id=name, result='PASS' if passed else 'FAIL', detail=detail)
        records.append(row)
        (out / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
        print(json.dumps(row), flush=True)

    state_command = "sha256sum /etc/rp/clients.tsv; systemctl show rp-xray rp-net rp-hy2 rp-hy2o -p MainPID"
    before = remote(args.lab1, state_command, 'before')
    if before.returncode:
        raise RuntimeError('cannot read baseline')
    preflight = remote(args.lab1, 'rp client list', 'list-before')
    if preflight.returncode or client_name in preflight.stdout:
        raise RuntimeError('fixture client already exists or baseline cannot be read')
    check_ns = remote(args.client, 'ip netns list; ip link show rp-lab-host2; nft list table ip rp_lab_client2', 'namespace-before')
    if ('rp-lab-client2' in check_ns.stdout or 'rp-lab-host2:' in check_ns.stdout or
            'table ip rp_lab_client2' in check_ns.stdout):
        raise RuntimeError('fixture namespace or network objects already exist')
    added = False
    try:
        add = remote(args.lab1, 'rp client add ' + client_name, 'add')
        added = True  # inspect/remove the fixture even if output/export failed
        record('add-live-peer-and-export', add.returncode == 0, {'rc': add.returncode})
        if add.returncode:
            raise RuntimeError('client addition failed')
        after_add = remote(args.lab1, state_command, 'after-add')
        record('client-only-services-preserved', before.stdout.splitlines()[1:] == after_add.stdout.splitlines()[1:])
        duplicate = remote(args.lab1, 'rp client add ' + client_name, 'duplicate')
        after_duplicate = remote(args.lab1, state_command, 'after-duplicate')
        record('duplicate-rejected-without-mutation', duplicate.returncode != 0 and after_duplicate.stdout == after_add.stdout)
        show = remote(args.lab1, 'rp client show ' + client_name, 'show')
        record('show-existing-client', show.returncode == 0)
        unique = remote(args.lab1, "python3 - <<'PY'\nfrom pathlib import Path\nrows=[x.split('\\t') for x in Path('/etc/rp/clients.tsv').read_text().splitlines() if x and not x.startswith('#')]\nassert len(rows)>=2\nassert all(len({r[i] for r in rows})==len(rows) for i in [0,1,2,3,4])\nassert Path('/root/rp-clients/" + client_name + ".conf').stat().st_mode & 0o777 == 0o600\nprint('unique private/public keys, PSKs, names and addresses; export 0600')\nPY", 'uniqueness')
        record('unique-client-identities-and-private-export', unique.returncode == 0)
        subprocess.run(['scp', '-q', args.lab1 + ':/root/rp-clients/' + client_name + '.conf', str(out / 'client.conf')], check=True)
        (out / 'client.conf').chmod(0o600)
        setup = (Path(__file__).with_name('setup-client.sh')).read_text()
        for old, new in [('rp-lab-client', 'rp-lab-client2'), ('rp-lab-host', 'rp-lab-host2'),
                         ('rp-lab-net', 'rp-lab-net2'), ('rp_lab_client', 'rp_lab_client2'),
                         ('10.253.66.', '10.253.67.'), ('/root/rp-lab', remote_dir)]:
            setup = setup.replace(old, new)
        (out / 'setup.sh').write_text(setup)
        prepare = remote(args.client, 'install -d -m 700 ' + shlex.quote(remote_dir), 'prepare')
        if prepare.returncode:
            raise RuntimeError('cannot prepare private directory')
        subprocess.run(['scp', '-q', str(out / 'client.conf'), str(out / 'setup.sh'), args.client + ':' + remote_dir + '/'], check=True)
        setup_result = remote(args.client, shlex.join(['bash', remote_dir + '/setup.sh', args.lab1_ip, remote_dir + '/client.conf']), 'setup')
        if setup_result.returncode:
            raise RuntimeError('second namespace setup failed')

        def probe(namespace):
            command = shlex.join(['ip', 'netns', 'exec', namespace, 'curl', '-4', '-fsS',
                '--max-time', '15', 'https://1.1.1.1/cdn-cgi/trace', '-o', '/dev/null'])
            return remote(args.client, command, 'traffic-' + namespace).returncode

        with ThreadPoolExecutor(max_workers=2) as pool:
            traffic = list(pool.map(probe, ['rp-lab-client', 'rp-lab-client2']))
        record('simultaneous-two-client-https', traffic == [0, 0], {'return_codes': traffic})
        delete = remote(args.lab1, 'rp client del ' + client_name, 'delete')
        record('delete-live-peer', delete.returncode == 0)
        if delete.returncode == 0:
            added = False
        after = remote(args.lab1, state_command, 'after-delete')
        record('original-clients-and-services-restored', after.stdout == before.stdout)
        missing = remote(args.lab1, 'rp client del ' + client_name, 'delete-missing')
        record('missing-client-rejected', missing.returncode != 0)
        record('existing-client-still-works', probe('rp-lab-client') == 0)
    finally:
        if added:
            cleanup = remote(args.lab1, 'rp client del ' + client_name, 'cleanup-peer')
            record('cleanup-peer', cleanup.returncode == 0)
        remote(args.client, 'ip netns del rp-lab-client2 2>/dev/null; ip link del rp-lab-host2 2>/dev/null; nft delete table ip rp_lab_client2 2>/dev/null; rm -rf /etc/netns/rp-lab-client2', 'cleanup-network')
    return 0 if all(x['result'] == 'PASS' for x in records) else 1


if __name__ == '__main__':
    raise SystemExit(main())
