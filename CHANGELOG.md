# Changelog

## 1.2.9-lab.14 (unreleased, NOT_READY)

- Preserve the previous configuration and return an error on copy/read/write,
  staging, permissions or rename failure. Distinguish empty grep output from
  actual I/O errors; keep every intermediate file in a private directory.
- Reproduce actual ENOSPC in a bounded Rocky tmpfs: the baseline corrupted its
  config with rc=0; the candidate preserves it with rc=1.

## 1.2.9-lab.13 (unreleased, NOT_READY)

- Hold the operation lock across self-update, child migration and executable
  rollback. Validate the inherited lock descriptor instead of releasing it
  between commands. Four real-process regression cases pass locally and on Rocky.
- Full configuration/service rollback remains pending; this change closes the
  concurrent-operation window only.

## 1.2.9-lab.11 (unreleased, NOT_READY)

- Omit inner-WG credentials from VPS-2 bundles when neither Hysteria variant is
  selected. Stop and verify any old inner-WG interface before removing its
  generated/installed configs. Remove the unsupported legacy TCP config.
- Add all-subset bundle checks and real 4-to-2-to-4 deployment/client/identity
  regression tooling. Retain complete T1–T3 checks for every configured transport.

## 1.2.9-lab.10 (unreleased, NOT_READY)

- Abort VPS-2 installation when binary/data writes, publication, configuration
  permissions, WG installation, sysctl, service reload or management-key updates
  fail. Safe updates enter rollback instead of reaching READY using old files.
- Include owned binary staging paths in durable rollback, so interrupted
  publication does not leave newly created `.new` binaries behind.

## 1.2.9-lab.9 (unreleased, NOT_READY)

- VPS-2 egress diagnostics inspect the active runtime `rp-tunnel-egress` policy,
  its ACCEPT target and both zone directions. The unrelated intra-zone switch
  no longer falsely reports a broken inter-zone route. Runtime-query failures
  are unknown; no firewalld is explicitly not applicable. Firewall rules are
  unchanged and each report field occupies one line.

## 1.2.9-lab.8 (unreleased, NOT_READY)

- `rp diag` returns a nonzero status for failed or unconfirmed checks and checks
  every configured DoH endpoint. A partial failed HTTPS transfer cannot count
  as success just because its recorded HTTP status is 204.
- `rp diag --fix` repeats diagnostics after repair; a successful repair command
  alone no longer implies a healthy system. Reject unsupported arguments.

## 1.2.9-lab.7 (unreleased, NOT_READY)

- On VPS-2, query installed RPM dependencies before requesting only missing
  packages from DNF. Code updates no longer refresh repositories or upgrade
  already installed base packages unnecessarily. Missing dependencies remain
  fatal; verify installed packages and required commands before proceeding.
- Keep DNF diagnostics in a private package log instead of discarding them.

## 1.2.9-lab.6 (unreleased, NOT_READY)

- Route kernel-generated replies from the inner WG address through its exit
  table even after the application socket loses its mark. Keep the prohibit
  route and add an output firewall guard against direct underlay escape.
- Add a deterministic, lab-only closed-socket TCP reset leak probe and paired
  direct/proxied strict DoH diagnostics with packet capture.

## 1.2.9-lab.5 (unreleased, NOT_READY)

- Validate DoH HTTP status/content type, transfer completion, DNS question,
  response flags, record boundaries and an actual A answer. Reject HTML,
  truncated/error responses and partial transfers instead of accepting byte count.
- Store private structured probe diagnostics, including curl's failure reason.
  `rp dns test` now returns failure for any failed resolver, an empty resolver list
  or an error generating the list, while still checking all configured servers.

## 1.2.9-lab.4 (unreleased, NOT_READY)

- Preserve the requested resolver address in intercepted DNS replies when a
  client reuses its UDP source port. Redirect WG DNS through conntrack to a
  dedicated Xray inbound, retaining the existing split-DNS policy and kill switch.
  Restrict the new listener to WG/loopback ingress. General UDP forwarding and
  the pinned Xray version are unchanged.
- Add repeated same-source-port DNS checks to each transport regression.

## 1.2.9-lab.3 (unreleased, NOT_READY)

- Serialize mutating menu actions, installation, save and bundle creation with
  the same operation lock as CLI commands.
- Raise the inner WireGuard factory MTU from 1080 to 1280 on migration/reinstall
  and new installation. QUIC's minimum 1200-byte UDP payload cannot cross an
  IPv4 tunnel with MTU 1080 when DF is set. Preserve other operator values and
  reject invalid or QUIC-incompatible MTUs when rendering either endpoint.
- Updating the MTU requires `rp migrate` on VPS-1 and `rp push` to VPS-2.
- Add actual isolated ENOSPC and before/after MTU tests, plus full per-transport
  restart, repeated T3, DNS and application capture regression tooling.

## 1.2.9-lab.2 (unreleased, NOT_READY)

- Arm persistent recovery before stopping the watcher or creating its backup;
  recover interrupted PREPARING transactions without extracting partial archives.
- Recheck the confirmation deadline after the live probe. Make rollback cleanup
  retryable and restore supervision before publishing the terminal state.
- Try reserves before restarting a failed auto-mode primary, retaining three
  failure samples and full T2/T3 validation. Migrate the previous factory cadence
  to 10..15 seconds and reconcile routes every 3..4 seconds.
- Preserve configured networks, transport choices, ports, DNS, doors and pinned
  Hysteria certificates on reinstall; reject incomplete or mismatched identities.
- Remove explicit rp-owned unit files and only rp's WireGuard drop-in; preserve
  unrelated rp-prefixed services and operator drop-ins.
- Bind Hysteria to an assigned underlay IPv4, avoiding UDP/443 wildcard collisions
  with Xray's transparent UDP reply sockets. Detect NAT source addresses and allow
  an explicitly validated HY2_BIND_IP.
- Add real SIGKILL preparation recovery, full 30-minute timer, DNS and application
  traffic tests. Final acceptance and the operator-gated six-hour soak remain pending.

## 1.2.9-lab.1 (unreleased, NOT_READY)

- Reject empty, partial, duplicated and degraded transport results before confirming a push.
- Verify Xray routing overrides by reading the actual RoutingService JSON state.
- Preserve existing WireGuard clients and complete key groups on reinstall.
- Add a durable VPS-2 transaction helper with a private verified backup,
  serialized confirm/rollback, a persistent wall-clock timer and boot recovery.
  Restore only rp-managed SSH keys; retain unrelated authorized_keys entries.
- Add orchestration regression tests, static checks and laboratory evidence tooling.

Acceptance is incomplete. No 24/7 readiness or completed final soak is claimed.
