# Changelog

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
