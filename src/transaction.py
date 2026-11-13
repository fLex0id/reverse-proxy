#!/usr/bin/env python3
"""Durable VPS-2 update transaction. Embedded verbatim into the deployable rp.sh.

Only rp-owned paths are restored. Services are stopped during restoration; this
is a recoverable transaction, not a claim of a filesystem-wide atomic rename.
"""
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

STATE = Path('/var/lib/rp')
TX = STATE / 'transaction'
META = TX / 'state.json'
BACKUP = STATE / 'backup.tgz'
TIMER = 'rp-transaction-rollback.timer'
UNITS = ['rp-watch.service', 'rp-xray@xhttp.service', 'rp-xray@xhttp2.service',
         'rp-hy2.service', 'rp-hy2o.service', 'wg-quick@rp-wg.service', 'rp-nat.service']
BASE_PATHS = ['etc/rp', 'usr/local/lib/rp', 'usr/local/bin/rp',
              'usr/local/bin/xray', 'usr/local/bin/hysteria', 'usr/local/share/rp',
              'etc/wireguard/rp-wg.conf', 'etc/sysctl.d/99-rp.conf',
              'etc/firewalld/zones/rp-tunnel.xml',
              'etc/firewalld/policies/rp-tunnel-egress.xml']
STATE_NAMES = ['mode', 'active', 'since', 'usable', 'results', 'mode-request', 'mode-result']
OWN_UNITS = ['rp-hy2.service', 'rp-hy2o.service', 'rp-xray@.service',
             'rp-watch.service', 'rp-nat.service', 'rp-rollback.service']
TRANSPORTS = {'reality-xhttp', 'reality-xhttp2', 'hy2-wg', 'hy2o-wg'}


def command(*args, check=True, timeout=90):
    r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True, timeout=timeout, env=dict(os.environ, RP_TX_INTERNAL='1'))
    if check and r.returncode:
        raise RuntimeError('command failed: ' + args[0] + ' ' + args[1])
    return r


def atomic(path, data, mode=0o600):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            os.fchmod(f.fileno(), mode)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(name): os.unlink(name)


def save(meta): atomic(META, json.dumps(meta, indent=2) + '\n')
def load(): return json.loads(META.read_text())
def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()


def owned_keys():
    p = Path('/root/.ssh/authorized_keys')
    return [line for line in p.read_text().splitlines() if line.endswith(' rp@vps1')] if p.exists() else []


def restore_keys(lines):
    p = Path('/root/.ssh/authorized_keys')
    existing = p.read_text().splitlines() if p.exists() else []
    # Preserve every unrelated key, including additions made after prepare.
    preserved = [line for line in existing if not line.endswith(' rp@vps1')]
    atomic(p, '\n'.join(preserved + lines) + '\n')
    command('restorecon', str(p), check=False)


def paths():
    return BASE_PATHS + ['var/lib/rp/' + n for n in STATE_NAMES] + [
        'etc/systemd/system/' + n for n in OWN_UNITS]


def valid_member(member, roots):
    name = member.name.rstrip('/')
    if name.startswith('/') or '..' in Path(name).parts:
        return False
    if not any(name == p or name.startswith(p + '/') for p in roots):
        return False
    # Configs and binaries are regular files/directories. Refuse extraction of
    # devices, FIFOs and links instead of following an attacker-controlled path.
    return member.isfile() or member.isdir()


def arm(meta):
    deadline = datetime.datetime.fromtimestamp(meta['deadline'], datetime.timezone.utc)
    unit_dir = Path('/etc/systemd/system')
    atomic(unit_dir/'rp-transaction-rollback.service', '''[Unit]
Description=rp: durable transaction rollback
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /var/lib/rp/transaction/runner.py rollback
TimeoutStartSec=300
''', 0o644)
    atomic(unit_dir/TIMER, '[Unit]\nDescription=rp: unconfirmed update deadline\n[Timer]\nOnCalendar=' +
           deadline.strftime('%Y-%m-%d %H:%M:%S UTC') + '\nPersistent=true\nAccuracySec=1s\n[Install]\nWantedBy=timers.target\n', 0o644)
    atomic(unit_dir/'rp-transaction-recover.service', '''[Unit]
Description=rp: recover interrupted update after reboot
After=local-fs.target network-online.target
Before=rp-watch.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /var/lib/rp/transaction/runner.py recover
TimeoutStartSec=300
[Install]
WantedBy=multi-user.target
''', 0o644)
    command('restorecon', '-R', str(TX), str(unit_dir), check=False)
    command('systemctl', 'daemon-reload')
    command('systemctl', 'enable', 'rp-transaction-recover.service')
    command('systemctl', 'enable', '--now', TIMER)
    command('systemctl', 'is-active', '--quiet', TIMER)


def disarm():
    command('systemctl', 'disable', '--now', TIMER, check=False)
    command('systemctl', 'disable', 'rp-transaction-recover.service', check=False)
    if command('systemctl', 'is-active', '--quiet', TIMER, check=False).returncode == 0:
        raise RuntimeError('rollback timer remains active')


def prepare(pid):
    if META.exists() and load()['phase'] not in ('COMMITTED', 'ROLLED_BACK'):
        raise RuntimeError('a previous transaction is unresolved; confirm or rollback it first')
    if not Path('/etc/rp/rp2.conf').exists():
        raise RuntimeError('safe update requires an installed VPS-2')
    TX.mkdir(mode=0o700, parents=True, exist_ok=True)
    TX.chmod(0o700)
    if command('systemctl', 'is-active', '--quiet', 'rp-rollback-run.timer', check=False).returncode == 0:
        raise RuntimeError('legacy update still pending; resolve it before migration')
    old_watch = command('systemctl', 'is-active', '--quiet', 'rp-watch', check=False).returncode == 0
    command('systemctl', 'stop', 'rp-watch', check=False)
    roots = paths()
    published = False
    archive = None
    try:
        atomic(TX/'installing', 'installing\n')
        atomic(TX/'pending', 'pending\n')
        fd, archive = tempfile.mkstemp(prefix='.backup.', dir=STATE)
        os.close(fd)
        with tarfile.open(archive, 'w:gz') as tf:
            for p in roots:
                actual = Path('/') / p
                if actual.exists() or actual.is_symlink(): tf.add(actual, arcname=p, recursive=True)
        with tarfile.open(archive, 'r:gz') as tf:
            if not all(valid_member(m, roots) for m in tf):
                raise RuntimeError('unsupported link/device in managed backup paths')
        with open(archive, 'rb') as f: os.fsync(f.fileno())
        os.replace(archive, BACKUP)
        directory_fd = os.open(STATE, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(directory_fd)
        finally: os.close(directory_fd)
        atomic(TX/'runner.py', Path(__file__).read_text())
        meta = dict(phase='INSTALLING', created=time.time(), deadline=int(time.time()) + 1800,
                    boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                    pid=pid, pid_start=Path('/proc/%d/stat' % pid).read_text().split()[21],
                    paths=roots, sha256=digest(BACKUP), keys=owned_keys(), watch_active=old_watch)
        save(meta)
        published = True
        arm(meta)
    except Exception:
        # Preparation has not applied any bundle file. Restore the watchdog and
        # mark a published intent aborted without touching the working tunnel.
        if published:
            meta['phase'] = 'ROLLED_BACK'
            meta['reason'] = 'prepare failed before bundle mutation'
            save(meta)
            disarm()
        (TX/'installing').unlink(missing_ok=True)
        (TX/'pending').unlink(missing_ok=True)
        if archive and os.path.exists(archive): os.unlink(archive)
        if old_watch: command('systemctl', 'start', 'rp-watch', check=False)
        raise
    print('Transaction armed; verified private backup and reboot recovery ready')


def ready():
    meta = load()
    if meta['phase'] != 'INSTALLING': raise RuntimeError('not an installing transaction')
    meta['phase'] = 'READY'
    save(meta)
    (TX/'installing').unlink(missing_ok=True)
    command('systemctl', 'enable', '--now', 'rp-watch')
    command('systemctl', 'is-active', '--quiet', 'rp-watch')


def validate_results():
    conf = {}
    for line in Path('/etc/rp/rp2.conf').read_text().splitlines():
        if '=' in line:
            k, v = line.split('=', 1); conf[k] = v.strip('"')
    expected = conf.get('TRANSPORT_ORDER', '').split()
    if not expected or not set(expected) <= TRANSPORTS: raise RuntimeError('invalid transport order')
    seen = {}
    for line in (STATE/'results').read_text().splitlines():
        parts = line.split('=')
        if len(parts) != 2 or parts[0] in seen or parts[1] != 'ok':
            raise RuntimeError('incomplete, failed or duplicated transport results')
        seen[parts[0]] = parts[1]
    if set(seen) != set(expected): raise RuntimeError('missing transport results')
    if (STATE/'push.rc').read_text().strip() != '0': raise RuntimeError('installer has not succeeded')
    command('/usr/local/bin/rp', '_func', timeout=60)
    command('systemctl', 'is-active', '--quiet', 'rp-watch')


def confirm():
    meta = load()
    if meta['phase'] == 'COMMITTED':
        disarm()
        BACKUP.unlink(missing_ok=True)
        (TX/'pending').unlink(missing_ok=True)
        Path('/root/.rp-push.sh').unlink(missing_ok=True)
        return
    if meta['phase'] != 'READY' or time.time() >= meta['deadline']:
        raise RuntimeError('not ready or confirmation deadline expired')
    validate_results()
    if digest(BACKUP) != meta['sha256']: raise RuntimeError('backup checksum mismatch')
    # The shared lock serializes this durable commit with a running rollback.
    # A late timer sees COMMITTED and cannot restore old files.
    meta['phase'] = 'COMMITTED'; save(meta)
    disarm()
    BACKUP.unlink(missing_ok=True)
    (TX/'pending').unlink(missing_ok=True)
    Path('/root/.rp-push.sh').unlink(missing_ok=True)
    print('Update COMMITTED after complete transport results and live probe')


def stop_installer(meta):
    if meta['boot_id'] != Path('/proc/sys/kernel/random/boot_id').read_text().strip(): return
    pid = meta['pid']
    try:
        if Path('/proc/%d/stat' % pid).read_text().split()[21] != meta['pid_start']: return
    except FileNotFoundError: return
    # The installer is launched by setsid for push; never signal an unrelated
    # console process group. Kill only this exact process and its descendants.
    def children(parent):
        found = []
        try: ids = Path('/proc/%d/task/%d/children' % (parent, parent)).read_text().split()
        except FileNotFoundError: return found
        for n in ids:
            found.extend(children(int(n))); found.append(int(n))
        return found
    for target in children(pid) + [pid]:
        try: os.kill(target, signal.SIGKILL)
        except ProcessLookupError: pass


def rollback(from_installer=False, boot_recovery=False):
    meta = load()
    if meta['phase'] in ('COMMITTED', 'ROLLED_BACK'): return
    if digest(BACKUP) != meta['sha256']: raise RuntimeError('backup checksum mismatch; no extraction attempted')
    with tarfile.open(BACKUP, 'r:gz') as tf:
        members = tf.getmembers()
        if not all(valid_member(m, meta['paths']) for m in members):
            raise RuntimeError('unsafe backup member; no extraction attempted')
    if not from_installer: stop_installer(meta)
    meta['phase'] = 'ROLLING_BACK'; save(meta)
    for u in UNITS: command('systemctl', 'stop', u, check=False)
    for p in meta['paths']:
        target = Path('/') / p
        if target.is_dir() and not target.is_symlink(): shutil.rmtree(target)
        else: target.unlink(missing_ok=True)
    # Only verified regular files/directories below fixed rp-owned roots.
    with tarfile.open(BACKUP, 'r:gz') as tf:
        # Already validated every member: fixed owned roots, no links/devices.
        # Preserve owner/mode for service-readable secrets on older Python too.
        options = {'filter': 'fully_trusted'} if hasattr(tarfile, 'fully_trusted_filter') else {}
        tf.extractall('/', **options)
    restore_keys(meta['keys'])
    command('restorecon', '-R', '/etc/rp', '/usr/local/lib/rp', '/usr/local/bin', check=False)
    command('systemctl', 'daemon-reload')
    if command('systemctl', 'is-active', '--quiet', 'firewalld', check=False).returncode == 0:
        command('firewall-cmd', '--reload')
    command('/usr/local/bin/rp', 'fixnet')
    command('/usr/local/bin/rp', 'restart')
    # Service start is not tunnel readiness: the reverse bridge must connect,
    # then the remote observatory must publish its first observation.
    deadline = time.monotonic() + 90
    while True:
        if command('/usr/local/bin/rp', '_func', check=False, timeout=40).returncode == 0:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('restored files, but previous tunnel did not become ready')
        time.sleep(2)
    meta['phase'] = 'ROLLED_BACK'; save(meta)
    (TX/'pending').unlink(missing_ok=True)
    (TX/'installing').unlink(missing_ok=True)
    if meta['watch_active']:
        command('systemctl', 'enable', 'rp-watch')
        # During boot this recover service precedes rp-watch. Do not wait for
        # a start job whose ordering dependency is this very process.
        if boot_recovery:
            command('systemctl', '--no-block', 'start', 'rp-watch')
        else:
            command('systemctl', 'start', 'rp-watch')
            command('systemctl', 'is-active', '--quiet', 'rp-watch')
    disarm()
    Path('/root/.rp-push.sh').unlink(missing_ok=True)
    BACKUP.unlink(missing_ok=True)
    print('Rollback restored the previous version and verified its active tunnel')


def main():
    if os.geteuid() != 0: raise RuntimeError('root required')
    os.umask(0o077)
    with open('/run/rp-transaction.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        action = sys.argv[1]
        if action == 'prepare': prepare(int(sys.argv[2]))
        elif action == 'ready': ready()
        elif action == 'confirm': confirm()
        elif action == 'rollback': rollback('--from-installer' in sys.argv)
        elif action == 'recover':
            if META.exists():
                meta = load()
                boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
                if meta['phase'] == 'COMMITTED': confirm()
                elif meta['phase'] == 'ROLLED_BACK':
                    (TX/'installing').unlink(missing_ok=True)
                    (TX/'pending').unlink(missing_ok=True)
                    disarm()
                elif meta['boot_id'] != boot: rollback(boot_recovery=True)
        else: raise RuntimeError('unknown transaction command')

if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print('rp transaction FAILED/UNKNOWN: ' + str(exc), file=sys.stderr)
        sys.exit(1)
