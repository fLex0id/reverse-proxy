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
- `doh_probe_matrix.py --lab1 ALIAS --candidate REMOTE_RP_PATH --output DIR`:
  source an uploaded candidate's strict DoH probe without installation, test
  all configured resolvers on each transport, retain every diagnostic and restore auto.
- `doh_path_compare.py --lab1 ALIAS --lab2 ALIAS --candidate REMOTE_RP_PATH --output DIR`:
  upload the same candidate path on both hosts first. Compare proxied and direct
  probes to identical numeric resolver destinations, both IP and hostname/SNI
  URLs, while capturing both underlays. `--transport` selects the tested tunnel.
- `wg_reset_probe.py --lab1 ALIAS --lab2 ALIAS --client-ip LAB_CLIENT_IPV4 --output DIR`:
  one synthetic TCP ACK through inner WG to a closed LAB-1 port must get its
  reset through WG, never LAB-1 underlay. The source address must be the authorized
  lab client. `--expect guard-drop` verifies the secondary output guard with
  counter evidence when the source rule is deliberately absent. The fixture
  does not remove that rule itself; arm independent restoration before doing so.
- `diag_fault_probe.py --lab1 ALIAS --client ALIAS --candidate REMOTE_RP_PATH --output DIR`:
  temporarily stop the actual network service, compare installed/candidate
  diagnostics, restore it and client WG, verify client HTTPS. Arms an independent
  120-second restoration timer. Never overlap a transport/capture/fault suite.
- `installer_write_fault.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --output DIR`:
  generate the installed VPS-1 bundle and inject one exact command failure into
  its real VPS-2 safe installer. `--stage` selects binary/data writes/publication,
  WG installation, configuration permissions or systemd reload. Record return
  status/transaction state, restore even a falsely successful baseline, verify
  original hashes, staging cleanup, watcher and client. The scoped wrapper does
  not alter global PATH or exhaust the disk. Do not overlap other mutations.
  Additional stages cover download exhaustion, corrupted checksums, extraction,
  NAT service, firewalld reload and sysctl. Download failures retain all five
  attempts and original backoff. `--failure kill-reboot` sends SIGKILL to the
  exact installer PID/start identity, observes INSTALLING, then really reboots
  VPS-2 and waits for its installed boot-recovery service. It never shortens the
  production 30-minute deadline or calls rollback before observing boot recovery.
- `restart_fault_probe.py --lab1 ALIAS --client ALIAS --candidate REMOTE_RP_PATH --output DIR`:
  compare restart behavior after stopping actual client WG and echo services,
  then use a private runtime drop-in to make WG start fail. Verify command status,
  actual service state and restored client HTTPS; an independent 180-second timer
  removes the exact drop-in and restores the core services if interrupted.
- `restart_vps2_fault.py --lab2 ALIAS --client ALIAS --candidate REMOTE_VPS2_CLI --output DIR`:
  stop the watcher, inject a private runtime ExecStart failure into the currently
  selected transport, and compare installed/candidate restart results against
  actual systemd failure state. An independent timer restores the exact service;
  require the functional reverse probe, watcher and client HTTPS after recovery.
- `transport_roundtrip.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --output DIR`:
  retain a selected pair (`--keep TRANSPORT TRANSPORT`, defaults to both XHTTP),
  deploy it, check stale/current configs and client HTTPS/DNS/HTTP3, then restore
  all four with full push validation. Preserve and compare original settings,
  client keys and Hysteria identity; restore auto and clean only owned fixtures.
  Its finally block restores the original configuration; independent SSH and
  the private backup support recovery if the controller is interrupted.
- `review_lab1_captures.py --directory ARTIFACT_DIRECTORY --reader ALIAS --output DIR`:
  decode every LAB-1 PCAP using tcpdump on the authorized lab reader. Include all
  source addresses, especially inner-WG kernel replies; collect addresses and DNS
  questions for policy review. Zero packets alone is not an acceptance verdict.
- `hy2_acl_matrix.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --client-ip IP --output DIR`:
  launch private authenticated Hysteria 2.8.2 clients for both variants using the
  existing certificate pin and credentials, with a dedicated loopback SOCKS port.
  Test TCP denial to known reachable lab services and UDP delivery/denial using
  unique payload markers in a real VPS-1 capture. The allowed UDP/51821 positive
  control must succeed; otherwise negative results remain UNKNOWN. Server ACLs
  are unchanged. Only owned lab destinations are probed. Temporary clients and
  captures have bounded service runtimes; credentials/PCAPs stay private.
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

- `conf_write_fault.py --baseline FILE --candidate FILE --output NEW_DIR`:
  run on an authorized Linux lab host as root. Compare configuration writes in
  separate 96-KiB tmpfs mounts using synthetic input. Verify actual ENOSPC, status,
  original bytes, permissions and cleanup. Installed rp files/services and the
  root filesystem capacity are unchanged. Mounts are always unmounted in finally.

- `migration_fault.py --candidate FILE --helper FILE --output NEW_DIR [--failure exit|kill]`:
  run on authorized VPS-1 only. Take an independent private backup and arm a
  fallback timer, then fail or kill a real migration after unit/config mutation.
  Require exact owned-file hashes/modes, selected runtime state and unit states
  after automatic recovery. Verify isolated client traffic separately. Never
  overlap any other mutation suite. On failure the fallback stays armed.

- `migration_reboot.py --lab1 ALIAS --client ALIAS --candidate REMOTE_FILE
  --helper REMOTE_FILE --fixture REMOTE_MIGRATION_FAULT --output NEW_DIR`:
  upload the candidate, `src/migration.py` and `migration_fault.py` first. The
  controller pauses the fixture after real mutation, kills its exact supervisor
  and reboots VPS-1. Require a changed boot ID, installed boot recovery, baseline
  hashes/runtime/unit states and client HTTPS. Independent management SSH and
  the fixture backup are required; never overlap another mutation suite.

## Development validation

Run `python3 tools/embed-transaction.py` after modifying `src/transaction.py`.
Run `python3 tools/embed-migration.py` after modifying `src/migration.py`.
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
