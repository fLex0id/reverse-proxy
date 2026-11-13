# Changelog

## 1.2.9-lab.1 (unreleased, NOT_READY)

- Reject empty, partial, duplicated and degraded transport results before confirming a push.
- Verify Xray routing overrides by reading the actual RoutingService JSON state.
- Preserve existing WireGuard clients and complete key groups on reinstall.
- Add a durable VPS-2 transaction helper with a private verified backup,
  serialized confirm/rollback, a persistent wall-clock timer and boot recovery.
  Restore only rp-managed SSH keys; retain unrelated authorized_keys entries.
- Add orchestration regression tests, static checks and laboratory evidence tooling.

Acceptance is incomplete. No 24/7 readiness or completed final soak is claimed.
