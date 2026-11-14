# Authorized laboratory tooling

These programs change the designated lab hosts. Do not run them on production.
Use SSH aliases/config supplied by the operator; never commit private keys or
client configurations. Store artifacts below `lab/artifacts` and secret inputs
below `lab/private` (both ignored, mode 0700).

- `setup-client.sh LAB1_IP CLIENT_CONFIG`: on the auxiliary Debian host, create an
  independent WireGuard client namespace with a veth underlay. It adds only its
  own NAT table, but enables host IPv4 forwarding; previous value is recorded.
- `transport_matrix.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --output DIR`:
  historical baseline runner; use `full_transport_regression.py` for new runs.
  Select each transport, run built-in checks, generate actual client HTTPS/DNS,
  and capture packets on both external interfaces. A successful capture command
  alone is not a leak-test PASS. Review skipped T8/static T7 explicitly.
- `dns-probe.py RESOLVER NAME [--type NUMBER] [--tcp]`: standard-library DNS probe
  with no alternate/system resolver fallback.
- `failclosed.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --output DIR`: verify a
  working client, arm independent restoration, then stop only rp-xray. Record
  blocked requests and recovery with valid streamed captures on all three hosts.
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
  Google and Cloudflare STUN independently, and the explicitly disabled IPv6 case.
  Requires curl with HTTP/3 support. A failure at one STUN endpoint is retained
  even if the other succeeds; compare the same numeric destination directly.
- `full_transport_regression.py` takes the same four host/output arguments:
  verify the deployed script hash, select each transport, run complete built-in
  checks including restart, repeat full T3 30 times, then run DNS/application
  matrices with three simultaneous PCAP streams and 90 same-port DNS queries.
  Install `dns_source_reuse.py` under `/root/rp-lab/` on the auxiliary host first.
  Restores auto after completion.
  Stop and inspect remote state on a harness/SSH timeout; do not blindly rerun.
- `mtu_probe.py` takes the same arguments and compares actual application traffic
  at inner WG MTU 1080 and 1280 on both Hysteria transports. Runtime changes have
  independent systemd restoration timers; saved configuration is unchanged.
- `prepare_enospc.py`: run on LAB-2 with the same helper path as transaction E2E.
  Cause real ENOSPC in a 128-KiB transaction-directory tmpfs, verify recovery,
  then unmount it. The root filesystem is not filled.
- `reboot_recovery.py` takes the four host/output arguments. Pin packet-up, prepare
  a durable transaction, mutate two rp-owned fixture files, actually reboot LAB-2,
  then check automatic restoration, cleanup, supervision, manual pin and client
  HTTPS. Requires independent management SSH; never overlap another fault suite.
- `dns_source_reuse.py`: run inside the client namespace; send DNS queries to
  three resolver addresses from one UDP source port and validate the reply source.
- `dns_redirect_trial.py`: LAB-1-only experimental regression fixture. Temporarily
  redirect DNS through conntrack into a separate inbound with the existing DNS
  policy. Validates nft/Xray first; restores files/services after 180 seconds or
  via an independent 240-second timer. It is not part of the installed candidate.
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

The inner WireGuard factory MTU is now 1280. `rp migrate` replaces the former
factory value 1080, preserving other operator values; `rp push` updates the peer.
Both runtime link MTUs must match their generated files. Values below 1228 cannot
carry QUIC's minimum UDP datagram over IPv4 and are rejected during rendering.
