#!/usr/bin/env python3
"""Private, recoverable VPS-1 migration; embedded into the single-file rp.sh.

Restores only rp-owned files and network state. Never restores the host's whole
firewall, SSH configuration or unrelated systemd units. Terminal success means
local migration readiness, not remote transport acceptance.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path('/')
TX = Path('/var/lib/rp/migration')
LOCK = Path('/run/rp.lock')
TIMER = 'rp-migration-recover.timer'
SERVICE = 'rp-migration-recover.service'
CORE = ['rp-net.service', 'wg-quick@wg-exit.service', 'wg-quick@wg0.service',
        'rp-xray.service', 'rp-hy2.service', 'rp-hy2o.service', 'rp-echo.service']
TIMERS = ['rp-route-sync.timer', 'rp-ru.timer']
UNITS = CORE + TIMERS
UNIT_FILES = ['rp-net.service', 'rp-xray.service', 'rp-hy2.service', 'rp-hy2o.service',
              'rp-echo.service', 'rp-ru.service', 'rp-ru.timer',
              'rp-route-sync.service', 'rp-route-sync.timer', 'wg-quick@wg0.service.d/rp.conf']
PATHS = ['etc/rp', 'usr/local/lib/rp', 'usr/local/bin/rp', 'usr/local/bin/xray',
         'usr/local/bin/hysteria', 'usr/local/bin/xray.new', 'usr/local/bin/hysteria.new',
         'etc/wireguard/wg0.conf', 'etc/wireguard/wg-exit.conf',
         'etc/wireguard/wg0.conf.rp-new', 'etc/wireguard/wg-exit.conf.rp-new',
         'etc/sysctl.d/99-rp.conf', 'var/lib/rp/assets'] + [
             'etc/systemd/system/' + name for name in UNIT_FILES] + [
             'var/lib/rp/' + name for name in
             ['route-target', 'route-policy', 'route-transition', 'vps2-active-cache', 'linked']]
TABLES = [('inet', 'rp_guard'), ('ip', 'rp_tp'), ('ip6', 'rp_block6')]
TERMINAL = {'COMMITTED', 'ROLLED_BACK'}


def command(*args, check=True, timeout=90, input_text=None):
    r = subprocess.run(args, input=input_text, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=timeout,
                       env=dict(os.environ, LC_ALL='C'))
    if check and r.returncode:
        raise RuntimeError('command failed: ' + ' '.join(args[:2]))
    return r


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, data, mode=0o600):
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            os.fchmod(f.fileno(), mode)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save(meta):
    atomic(TX / 'state.json', json.dumps(meta, indent=2) + '\n')


def load():
    return json.loads((TX / 'state.json').read_text())


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for data in iter(lambda: f.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()


def pid_start(pid):
    try:
        # comm may contain spaces or parentheses. Fields after the final ')'
        # begin at field 3; starttime is field 22.
        return Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[19]
    except FileNotFoundError:
        return None


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def own_lock():
    a, b = os.fstat(9), LOCK.stat()
    if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
        raise RuntimeError('inherited operation lock is missing')
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)


def guard(internal=False):
    own_lock()
    if not (TX / 'state.json').exists():
        if internal:
            raise RuntimeError('migration has not been prepared')
        return
    meta = load()
    child = (meta['phase'] == 'MIGRATING' and
             secrets.compare_digest(os.environ.get('RP_MIGRATION_TOKEN', ''), meta['token']))
    if internal and not child:
        raise RuntimeError('migration child is not authorized by the prepared transaction')
    if not internal and meta['phase'] not in TERMINAL and not child:
        raise RuntimeError('unfinished migration; wait for recovery or run rp migrate-recover')


def unit_state(unit):
    r = command('systemctl', 'show', unit, '-p', 'LoadState', '-p', 'ActiveState',
                '-p', 'UnitFileState', check=False)
    values = dict(line.split('=', 1) for line in r.stdout.splitlines() if '=' in line)
    if not values.get('LoadState') or not values.get('ActiveState'):
        raise RuntimeError('cannot read unit state: ' + unit)
    if values['ActiveState'] not in ('active', 'inactive', 'failed'):
        raise RuntimeError('unit is transitioning: ' + unit)
    return values


def capture_runtime():
    sysctls = {}
    keys = ['net.core.default_qdisc', 'net.ipv4.tcp_congestion_control',
            'net.ipv4.conf.all.rp_filter', 'net.ipv4.conf.default.rp_filter']
    keys += ['net.ipv4.conf.' + i + '.rp_filter' for i in ['wg0', 'wg-exit']]
    keys += ['net.ipv6.conf.' + p.parent.name + '.disable_ipv6'
             for p in Path('/proc/sys/net/ipv6/conf').glob('*/disable_ipv6')]
    for key in keys:
        r = command('sysctl', '-n', key, check=False)
        if r.returncode == 0:
            sysctls[key] = r.stdout.strip()
    nft = {}
    for family, table in TABLES:
        r = command('nft', 'list', 'table', family, table, check=False)
        if r.returncode and 'No such file' not in r.stderr:
            raise RuntimeError('cannot inspect owned nft table: ' + table)
        nft[family + ' ' + table] = r.stdout if r.returncode == 0 else ''
    routes = {}
    for n in [100, 200]:
        r = command('ip', '-4', 'route', 'show', 'table', str(n), check=False)
        if r.returncode and 'FIB table does not exist' not in r.stderr:
            raise RuntimeError('cannot inspect owned routing table')
        routes[str(n)] = r.stdout
    rules = [line for line in command('ip', '-4', 'rule', 'show').stdout.splitlines()
             if owned_rule(line)]
    firewall = []
    if command('systemctl', 'is-active', '--quiet', 'firewalld', check=False).returncode == 0:
        zone = command('firewall-cmd', '--get-default-zone').stdout.strip()
        cfg = read_conf()
        # Migration keeps configured ports; the two legacy migration defaults
        # are included before any new settings are written.
        ports = {'8443/tcp', '8443/udp'}
        for key, proto in [('WG_PORT', 'udp'), ('HY2_PORT', 'udp'), ('HY2O_PORT', 'udp'),
                           ('RXH_PORT', 'tcp'), ('RXH2_PORT', 'tcp'), ('RTCP_PORT', 'tcp')]:
            if cfg.get(key, '').isdigit():
                ports.add(cfg[key] + '/' + proto)
        for permanent in [False, True]:
            for port in sorted(ports):
                args = ['firewall-cmd', '--zone=' + zone]
                if permanent:
                    args.append('--permanent')
                r = command(*args, '--query-port=' + port, check=False)
                if r.returncode not in (0, 1):
                    raise RuntimeError('cannot inspect firewalld port')
                firewall.append(dict(zone=zone, permanent=permanent, port=port, present=r.returncode == 0))
    return dict(sysctls=sysctls, nft=nft, routes=routes, rules=rules, firewall=firewall)


def owned_rule(line):
    pref, separator, body = line.partition(':')
    if not separator:
        return False
    words = body.split()
    expected = {
        '90': [['from', 'all', 'fwmark', '0x1', 'lookup', '100']],
        '100': [['from', 'all', 'fwmark', '0xff', 'lookup', '200']],
        '101': [['from', address, 'lookup', '200'] for address in ['10.77.0.1', '10.77.0.1/32']],
    }
    return words in expected.get(pref.strip(), [])


def read_conf():
    return dict((k, v.strip('"')) for line in (ROOT / 'etc/rp/rp.conf').read_text().splitlines()
                if '=' in line for k, v in [line.split('=', 1)])


def restore_runtime(runtime):
    for item in runtime['firewall']:
        args = ['firewall-cmd', '--zone=' + item['zone']]
        if item['permanent']:
            args.append('--permanent')
        current = command(*args, '--query-port=' + item['port'], check=False)
        if current.returncode not in (0, 1):
            raise RuntimeError('cannot inspect firewalld during rollback')
        if (current.returncode == 0) != item['present']:
            action = '--add-port=' if item['present'] else '--remove-port='
            command(*args, action + item['port'])
    batch = []
    for family, table in TABLES:
        if command('nft', 'list', 'table', family, table, check=False).returncode == 0:
            batch.append('delete table ' + family + ' ' + table)
        batch.append(runtime['nft'][family + ' ' + table])
    command('nft', '-f', '-', input_text='\n'.join(batch) + '\n')
    for table, lines in runtime['routes'].items():
        command('ip', '-4', 'route', 'flush', 'table', table)
        for line in lines.splitlines():
            command('ip', '-4', 'route', 'replace', 'table', table, *shlex.split(line))
    current = command('ip', '-4', 'rule', 'show').stdout.splitlines()
    for line in current:
        if owned_rule(line):
            pref, body = line.split(':', 1)
            command('ip', '-4', 'rule', 'del', 'pref', pref.strip(), *shlex.split(body))
    for line in runtime['rules']:
        pref, body = line.split(':', 1)
        command('ip', '-4', 'rule', 'add', 'pref', pref.strip(), *shlex.split(body))
    for key, value in runtime['sysctls'].items():
        # A previously present WG device is restored before this step.
        command('sysctl', '-q', '-w', key + '=' + value)


def valid_member(member):
    name = member.name.rstrip('/')
    return (not name.startswith('/') and '..' not in Path(name).parts and
            any(name == p or name.startswith(p + '/') for p in PATHS) and
            (member.isfile() or member.isdir()))


def archive():
    path = TX / 'preparing.tgz'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.close(fd)
    with tarfile.open(path, 'w:gz', dereference=False) as tf:
        for rel in PATHS:
            target = ROOT / rel
            if target.exists() or target.is_symlink():
                tf.add(target, arcname=rel)
    with tarfile.open(path, 'r:gz') as tf:
        if not all(valid_member(member) for member in tf):
            raise RuntimeError('unsupported link/device in managed backup paths')
    with path.open('rb') as f:
        os.fsync(f.fileno())
    os.replace(path, TX / 'backup.tgz')
    sync_dir(TX)
    return digest(TX / 'backup.tgz')


def verify_archive(meta):
    if digest(TX / 'backup.tgz') != meta['sha256']:
        raise RuntimeError('backup checksum mismatch; no restoration attempted')
    with tarfile.open(TX / 'backup.tgz', 'r:gz') as tf:
        if not all(valid_member(member) for member in tf):
            raise RuntimeError('unsafe backup entry; no restoration attempted')


def restore_files(meta):
    verify_archive(meta)
    for rel in PATHS:
        target = ROOT / rel
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target)
        else:
            target.unlink(missing_ok=True)
    with tarfile.open(TX / 'backup.tgz', 'r:gz') as tf:
        options = {'filter': 'fully_trusted'} if hasattr(tarfile, 'fully_trusted_filter') else {}
        tf.extractall(ROOT, **options)
    command('restorecon', '-R', '/etc/rp', '/usr/local/lib/rp', '/etc/wireguard',
            '/var/lib/rp/assets', '/usr/local/bin/rp', '/usr/local/bin/xray',
            '/usr/local/bin/hysteria', check=False)


def arm():
    directory = ROOT / 'etc/systemd/system'
    atomic(directory / SERVICE, '''[Unit]
Description=rp: recover interrupted VPS-1 migration
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /var/lib/rp/migration/runner.py recover
TimeoutStartSec=300
''', 0o644)
    atomic(directory / TIMER, '''[Unit]
Description=rp: supervise VPS-1 migration recovery
[Timer]
OnBootSec=15s
OnUnitInactiveSec=15s
AccuracySec=1s
Unit=rp-migration-recover.service
[Install]
WantedBy=timers.target
''', 0o644)
    command('systemctl', 'daemon-reload')
    command('systemctl', 'enable', '--now', TIMER)
    command('systemctl', 'is-active', '--quiet', TIMER)


def disarm():
    command('systemctl', 'disable', '--now', TIMER)


def restore_timers(meta):
    for unit in TIMERS:
        if meta['units'][unit]['ActiveState'] == 'active':
            command('systemctl', 'start', unit)


def sync_owned():
    # A durable terminal marker must not get ahead of restored/published files.
    # Flush only managed regular files plus their directory entries.
    directories = set()
    for rel in PATHS:
        path = ROOT / rel
        entries = [path] + (list(path.rglob('*')) if path.is_dir() else [])
        for entry in entries:
            if entry.is_symlink():
                raise RuntimeError('unexpected symlink in migrated paths')
            if entry.is_file():
                with entry.open('rb') as f:
                    os.fsync(f.fileno())
            if entry.is_dir():
                directories.add(entry)
            if entry.parent.is_dir():
                directories.add(entry.parent)
    for directory in (ROOT / 'etc/systemd/system').glob('*.wants'):
        if directory.is_dir():
            directories.add(directory)
    for directory in sorted(directories, key=lambda p: len(p.parts), reverse=True):
        sync_dir(directory)


def finish(meta, phase):
    if meta['phase'] != 'PREPARING':
        sync_owned()
    terminal = dict(meta, phase=phase)
    save(terminal)
    meta.update(terminal)
    disarm()
    # Keep the last private archive for diagnosis; overwrite only when the
    # next transaction has obtained the operation lock and checked its state.


def rollback(meta):
    if meta['phase'] == 'PREPARING':
        # No candidate mutation has begun; an incomplete archive is unusable.
        restore_timers(meta)
        finish(meta, 'ROLLED_BACK')
        return
    verify_archive(meta)  # verify before stopping even a single service
    meta['phase'] = 'ROLLING_BACK'
    save(meta)
    for unit in TIMERS + list(reversed(CORE)):
        command('systemctl', 'stop', unit, check=False)
        if command('systemctl', 'is-active', '--quiet', unit, check=False).returncode == 0:
            raise RuntimeError('cannot stop unit for rollback: ' + unit)
    for unit, state in meta['units'].items():
        if state['LoadState'] == 'not-found' and unit_state(unit)['LoadState'] != 'not-found':
            command('systemctl', 'disable', unit)
    restore_files(meta)
    command('systemctl', 'daemon-reload')
    for unit, state in meta['units'].items():
        mode = state['UnitFileState']
        if state['LoadState'] == 'not-found':
            continue
        if mode in ('enabled', 'disabled'):
            command('systemctl', 'enable' if mode == 'enabled' else 'disable', unit)
        elif mode == 'enabled-runtime':
            command('systemctl', '--runtime', 'enable', unit)
    for unit in CORE:
        if meta['units'][unit]['ActiveState'] == 'active':
            command('systemctl', 'start', unit)
    restore_runtime(meta['runtime'])
    for unit in CORE:
        if meta['units'][unit]['ActiveState'] == 'active':
            command('systemctl', 'is-active', '--quiet', unit)
    # Verify restored service readiness using the OLD implementation without
    # calling its CLI lock (older versions cannot inherit that lock).
    if all(meta['units'][u]['ActiveState'] == 'active' for u in
           ['rp-net.service', 'rp-xray.service', 'rp-echo.service', 'wg-quick@wg0.service']):
        old = (ROOT / 'usr/local/bin/rp').read_text().rsplit('main "$@"', 1)[0]
        atomic(TX / 'check-restored.sh', old + '\nneed_vps1; vps1_check\n', 0o700)
        command('bash', str(TX / 'check-restored.sh'), timeout=120)
    restore_timers(meta)
    finish(meta, 'ROLLED_BACK')
    print('Migration rolled back: previous files and local service readiness restored', flush=True)


def stop_child(meta):
    if meta['boot_id'] != boot_id():
        return
    pid = meta.get('child_pid')
    if pid and pid_start(pid) == meta.get('child_start'):
        # Child is a new session leader; never signal the management SSH group.
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run(candidate):
    guard()
    if not (ROOT / 'etc/rp/rp.conf').is_file():
        raise RuntimeError('migration requires an installed VPS-1')
    text = Path(candidate).read_text()
    if 'migrate_apply() {' not in text:
        raise RuntimeError('candidate does not support transactional migration')
    TX.mkdir(parents=True, exist_ok=True, mode=0o700)
    TX.chmod(0o700)
    atomic(TX / 'runner.py', Path(__file__).read_text())
    atomic(TX / 'candidate.sh', text, 0o700)
    meta = dict(phase='PREPARING', boot_id=boot_id(), owner=os.getpid(),
                owner_start=pid_start(os.getpid()), deadline=time.time() + 1800,
                token=secrets.token_hex(32), units={u: unit_state(u) for u in UNITS})
    save(meta)
    child = None
    gate = None
    try:
        arm()  # durable recovery BEFORE pausing supervision or changing files
        for unit in TIMERS:
            command('systemctl', 'stop', unit)
        command('systemctl', 'stop', 'rp-route-sync.service', 'rp-ru.service', check=False)
        meta['runtime'] = capture_runtime()
        meta['sha256'] = archive()
        meta['phase'] = 'MIGRATING'
        save(meta)
        # Descriptor 9 is the original locked open-file description inherited
        # from the CLI. The candidate cannot open a concurrency window.
        reader, gate = os.pipe()
        try:
            child = subprocess.Popen([sys.executable, str(TX / 'runner.py'), 'child', str(reader)],
                                     env=dict(os.environ, RP_MIGRATION_TOKEN=meta['token']),
                                     pass_fds=(9, reader), start_new_session=True)
        finally:
            os.close(reader)
        try:
            meta['child_pid'], meta['child_start'] = child.pid, pid_start(child.pid)
            save(meta)
            os.write(gate, b'g')
        finally:
            os.close(gate)
            gate = None
        rc = child.wait(timeout=max(1, meta['deadline'] - time.time()))
        if rc:
            raise RuntimeError('candidate migration returned nonzero status')
        verify_archive(meta)
        restore_timers(meta)
        finish(meta, 'COMMITTED')
        print('Migration COMMITTED after local readiness checks', flush=True)
    except BaseException:
        if gate is not None:
            os.close(gate)
        stop_child(meta)
        if child is not None:
            child.wait(timeout=10)
        # Do not roll back a durable commit because final timer cleanup failed.
        if meta['phase'] != 'COMMITTED':
            rollback(meta)
        raise


def recover():
    if not (TX / 'state.json').exists():
        return
    meta = load()
    same_boot = meta['boot_id'] == boot_id()
    alive = same_boot and pid_start(meta['owner']) == meta['owner_start']
    if meta['phase'] not in TERMINAL:
        # The deadline ends candidate execution, not an already-running
        # rollback. Do not kill restoration halfway through its checked writes.
        if alive and (meta['phase'] == 'ROLLING_BACK' or time.time() < meta['deadline']):
            return
        stop_child(meta)
        if alive:
            try:
                os.kill(meta['owner'], signal.SIGKILL)
            except ProcessLookupError:
                pass
    with LOCK.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # another operation is completing; the timer retries
        meta = load()
        if meta['phase'] in TERMINAL:
            disarm()
        else:
            rollback(meta)


def main():
    if os.geteuid() != 0:
        raise RuntimeError('root required')
    os.umask(0o077)
    action = sys.argv[1]
    if action == 'guard':
        guard('--internal' in sys.argv)
    elif action == 'run':
        def interrupted(signum, _frame):
            raise RuntimeError('migration interrupted by signal ' + str(signum))
        for sig in [signal.SIGHUP, signal.SIGTERM, signal.SIGINT]:
            signal.signal(sig, interrupted)
        run(sys.argv[2])
    elif action == 'recover':
        recover()
    elif action == 'child':
        gate = int(sys.argv[2])
        if os.read(gate, 1) != b'g':
            raise RuntimeError('supervisor exited before publishing child identity')
        os.close(gate)
        os.set_inheritable(9, True)
        os.execvpe('bash', ['bash', str(TX / 'candidate.sh'), '_migrate_apply'], os.environ)
    else:
        raise RuntimeError('unknown migration action')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('rp migration FAILED/UNKNOWN: ' + str(exc), file=sys.stderr)
        sys.exit(1)
