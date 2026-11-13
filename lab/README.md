# Authorized laboratory tooling

These programs change the designated lab hosts. Do not run them on production.
Use SSH aliases/config supplied by the operator; never commit private keys or
client configurations. Store artifacts below `lab/artifacts` and secret inputs
below `lab/private` (both ignored, mode 0700).

- `setup-client.sh LAB1_IP CLIENT_CONFIG`: on the auxiliary Debian host, create an
  independent WireGuard client namespace with a veth underlay. It adds only its
  own NAT table, but enables host IPv4 forwarding; previous value is recorded.
- `transport_matrix.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --output DIR`:
  select each transport, run built-in checks, generate actual client HTTPS/DNS,
  and capture packets on both external interfaces. A successful capture command
  alone is not a leak-test PASS. Review skipped T8/static T7 explicitly.
- `dns-probe.py RESOLVER NAME [--type NUMBER] [--tcp]`: standard-library DNS probe
  with no alternate/system resolver fallback.
- `failclosed.py --lab1 ALIAS --client ALIAS --output DIR`: stop only rp-xray after
  arming independent systemd restoration; verify blocked client requests and recovery.
- `transaction_e2e.py`: run on LAB-2 with `/root/rp-lab/transaction-current.py` from
  `src/transaction.py`. Exercises real backup, corruption rejection, rollback,
  preservation of unrelated SSH changes and confirm/rollback races. Requires an
  already healthy candidate and independent SSH. Never run concurrently with
  other mutation/fault suites.
- `prepare_crash.py`: on LAB-2, kill the transaction helper during archive creation
  and verify recovery through its actual systemd service.
- `rollback_deadline.py`: on LAB-2, leave a READY transaction unconfirmed for the
  full default 30 minutes and verify timer-driven rollback. No clock/deadline changes.
- `dns_matrix.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --output DIR`: 192 DNS
  queries through the existing isolated client, with PCAP streamed from all hosts.
  Install `dns-probe.py` at `/root/rp-lab/dns-probe.py` on the auxiliary host first.
- `application_matrix.py` takes the same arguments; install `application_probe.py`
  under `/root/rp-lab/` on the auxiliary host. Tests HTTP, HTTPS, DoH, DoT, HTTP/3,
  STUN and the explicitly disabled IPv6 case. Requires curl with HTTP/3 support.
- `failover.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --lab1-ip IP --output DIR`:
  block only LAB-2's packet-up TCP/8443 and measure real client recovery, with
  an independent timed rule cleanup. Other configured ports require adapting
  the fixture; this is not a generic firewall-management tool.

A final six-hour soak has NOT started. The acceptance matrix remains NOT_READY.
Notify the user and wait for their machine cleanup before the final clean install
and six-hour soak. Test artifacts may contain network metadata: keep private
and publish only sanitized evidence summaries.

## Development validation

Run `python3 tools/embed-transaction.py` after modifying `src/transaction.py`.
The deployed artifact remains a single `rp.sh`; src/ is not needed to install it.
Run `python3 tools/static-check.py` and `python3 -m unittest discover -s tests -v`.
Static checks require ShellCheck and pyflakes. CI also stores a formatting audit;
legacy formatting is not silently rewritten.

Hysteria now binds an assigned underlay IPv4 rather than all addresses, avoiding
collisions with Xray transparent UDP reply sockets. The renderer uses PUBLIC_IP
when locally assigned, otherwise the local source of the route to PUBLIC_IP
(NAT deployments). Set `HY2_BIND_IP` in rp.conf for an explicit local interface
address. Unassigned/wildcard addresses are rejected. Apply configuration again
after interface-address changes; the current CLI accepts an IPv4 public endpoint.
