# rp laboratory status

Baseline: 3d3077d8940ac136b25cae4a6667a26531843a11, version 1.2.8-audit-fixes.
Branch: codex/rp-24x7-lab.

User amendments: use two Rocky 10.2 machines; Rocky 9 remains NOT_TESTED.
Final soak: six hours on an unchanged final commit (replaces 72 hours).
Operator gate (2026-11-13): notify the user BEFORE final soak preparation and
wait for their machine cleanup to be completed. Then install the corrected script
from scratch, run the required complete regressions/leak checks, and only then
start the six-hour soak. Current short fault tests use the existing installations.
Recovery objective: <=60 seconds with a healthy available alternative; start
counting after connectivity is restored for total outages. Manual pin remains fail-closed.

Lab: LAB-1=hy2-rpm, LAB-2=hy2-rpm2; hy2-deb available as auxiliary client/endpoint.
Snapshots exist. Preserve independent management SSH. Do not modify the router
or other hosts. Whole-disk/memory exhaustion must not endanger management access.
On 2026-11-13 all three machines briefly stopped answering ARP; the user restored
availability. Both rp endpoints started after boot and the isolated client was rebuilt.

Read both supplied specifications in full. Implementation must preserve all four
transports, full SNI coverage, T1-T3, and the F01-F13 acceptance matrix.
Final verdict: NOT_READY (work in progress; no acceptance or soak claimed).

## Current candidate (2026-11-21)

Lab.18 adds candidate-owned migration supervision to self-update. Lab.17 added
exact routing-rule ownership and protection of active rollback from the deadline.
155 local tests and static checks pass. Ordinary error, actual supervisor SIGKILL
and actual VPS-1 reboot after mutation restored measured owned files, runtime
and service state. Client HTTPS after reboot timed out once, then passed.
Immutable-URL self-updates to lab.16 and lab.18 committed successfully;
configuration and clients were preserved, repeated updates were idempotent, and
the lab.18 installed script/helper hashes match source d2d4e67. LAB-1 currently
runs lab.18; LAB-2 remains on its previous generated installation. Installed lab.18 also passed a deliberately failing `rp update`: its candidate
helper was selected, the previous state was restored, client HTTPS passed and
read-only VPS-2/Xray exit/rev checks agreed in auto mode. See
MIGRATION-ROLLBACK-2026-11-21.md and published scalar results.
The full candidate transport regression, other crash/disk/concurrency/IPv6 cases
and the real migration deadline remain open. Final cleanup/soak has not started.

## Earlier resumed work (2026-11-21)

The working branch fast-forwarded to backup commit 0cb36b4 without rewriting
history. Lab.13 closes the self-update lock handover gap: 128 local tests and
static checks pass; four real-process lock tests also pass on Rocky 10.2. The
installed endpoints still run lab.12. Full migration rollback remains open.
See UPDATE-LOCK-2026-11-21.md. Lab.14 also fixes false success and configuration
loss on write failure. Actual ENOSPC reproduced in a private Rocky tmpfs; the
candidate preserved the original config and returned rc=1. See
CONFIG-WRITE-2026-11-21.md. Lab.15 propagates unit-generation and migration-stage
errors and checks local readiness before success. All 137 local tests and static
checks pass; all 13 newly added test methods pass on Rocky in isolated fixtures.
See MIGRATE-ERRORS-2026-11-21.md. The installed endpoints remain lab.12, and full
migration-state rollback is still the next priority. Final cleanup/soak has not started.

## Previous installed checkpoint (2026-11-21)

Both endpoints now run source 29f65ed, 1.2.9-lab.12. Migration and ordinary push
passed complete T1–T3 on all four transports and reached COMMITTED, with auto mode
and watcher active. Actual failed/inactive-service restart tests pass on both
roles, including immediate Type=simple process exit; see RESTART-2026-11-20.md.
124 local tests and generated-code static checks pass. The lab.12 NAT-failure
and kill/reboot recovery repeat and full four-transport regression completed
under `lab/artifacts/lab12-validation-20261121`. All complete T1–T3, 120 extra
T3 checks, 768 DNS behaviors, 360 same-source DNS checks, HTTP/HTTPS/DoH/DoT/HTTP3
and Cloudflare STUN passed. Google STUN failed on all four transports; its direct
controls and external-path limitations remain documented. Auto mode was restored.
The lab.12 boot rollback completed in 33.416 seconds; original hashes, watcher,
staging cleanup and client HTTPS passed. See WORK_SUMMARY_RU.md and the sanitized
snapshots in reports/results. These observations are not final acceptance.

Lab.11 completed XHTTP-pair and Hysteria-pair 4-to-2-to-4 deployment cycles.
Lab.9 push passed all four complete T1–T3 and reached COMMITTED. Its installed
`rp diag` passed on each of four transports after fixing both false-success
statuses and the incorrect firewalld intra-zone check. A real stopped-rp-net
test reproduced lab.7 rc=0 versus candidate lab.8 rc=1, with client recovery.

Lab.7's expanded regression completed: all four T1–T3, 120 additional T3,
768 ordinary DNS behaviors, 360 same-source DNS checks, HTTP/3 and Cloudflare
STUN passed. Both Hysteria kernel-reset probes passed. Quad9 failed one built-in
T6; Google STUN failed on all four. Complete scoped results and capture review:
REGRESSION-2026-11-20.md. Final policy/fault/native-IPv6 coverage remains open.

RP-019: a real scoped Xray staging-write failure on lab.9
still returned rc=0 and READY. The fixture explicitly rolled it back and verified
old hashes/watch/client recovery. Lab.10 adds checked writes/permissions/services
and durable cleanup of owned staging files. All nine real command-failure cases
passed with automatic rollback, old hashes/watch/client and staging cleanup.
See INSTALLER-FAULTS-2026-11-20.md; ordinary lab.10 push then passed all four
complete T1–T3 and committed. RP-020's baseline cycle exposed retained unused
WG secrets and a legacy TCP configuration. Lab.11 removes them correctly; both
repeat pair cycles passed 39 checks each, including client HTTPS/DNS/HTTP3,
identity/settings preservation, full four-transport restoration and auto mode.
See TRANSPORT-CLEANUP-2026-11-20.md. That checkpoint passed 118 local tests.
Nine additional lab.11 download/checksum/extraction/network faults all caused
automatic rollback and restored hashes/watch/client. Three actual installer
SIGKILL/reboot points passed installed boot recovery in approximately 30 seconds.
The first download fixture had an invalid sysctl passthrough and required explicit
recovery; its failure is retained separately from the corrected passing repeat.
Final clean installation and six-hour soak have NOT started.

All three machines became available again on 2026-11-20; their clocks were
checked and the isolated WG namespace rebuilt. The operator confirms that the
lab and controller use VPN under TSPU conditions. Independently reproduced
external failures must be documented without blocking unrelated engineering
indefinitely; they remain failures/limitations, never silently converted to PASS.

Quad9: 120 paired direct/proxied probes produced 17 TLS failures (7 through rp,
10 direct LAB-2); all 40 Cloudflare probes passed. Incoming Quad9-source resets
are visible on LAB-2. Exact origin is unproven; an external cause is probable.
RP-015, a separate local reset leak, reproduced without any external endpoint:
unmarked kernel RST escaped LAB-1 underlay. Source routing plus an independent
output guard passed both normal and deliberately missing-rule tests. See
DOH-2026-11-20.md for counts, captures, limitations and exact test scope.

New commits since dcee312:
- 4650bdd: serialize mutating menu/installer/save/bundle entry points.
- 7e2905f: inner WG MTU 1280 with explicit factory migration and validation;
  actual ENOSPC/MTU comparison and four-transport regression tooling.
- a1f7ba6: update live WG MTU on apply and restore it from rollback files.
- 61dbdf5: preserve intercepted DNS reply addresses across reused UDP ports.
- 65b3fed: reject malformed/partial DoH replies and propagate DNS test failures.
- 87f4f3a: prevent unmarked kernel resets escaping through LAB-1 underlay.
- 9fdb646: request only missing OS dependencies during repeated VPS-2 installs.
- cf9ab6f: propagate diagnostic errors and revalidate after --fix.
- 171a2c7: inspect the actual active inter-zone firewalld policy.
- 7471fb3: fail and roll back on installer write/permission/service errors;
  include binary staging files in durable restoration.
- e50929e: omit unused inner-WG credentials and remove obsolete VPS-2 configs;
  cover every nonempty transport subset and real pair round trips.
- 67e289b: record diagnostic, installer, packet and transport-cleanup evidence.
- 7a72456: exercise download/integrity/extraction/network and installer kill/reboot faults.
- 29f65ed: restart inactive client WG/echo, propagate errors and verify readiness
  before reporting successful restart on both roles.

Actual ENOSPC during transaction preparation: 6/6 checks PASS, cleanup complete.
HTTP/3 with each Hysteria variant: FAIL at MTU 1080, PASS at 1280, with simultaneous
client/LAB-1/LAB-2 PCAPs; no direct LAB-1 packets to the control destination.
Expanded lab.3 regression completed: all four HTTP/3 cases, 120 additional T3
checks, 768 ordinary DNS behaviors and Cloudflare STUN passed. Google STUN failed.
See REGRESSION-2026-11-14.md for packet attribution and limits. Earlier lab.2 run passed 120 consecutive
T3 payload checks (30 per transport), but exposed HY2 HTTP/3 and a DNS reply-source
defect. DoH/Quad9 remained intermittent. Google numeric STUN also fails directly
from LAB-2; an additional independent Cloudflare STUN case is now retained.

RP-013 candidate fix is installed: conntrack-backed DNS redirect preserves the
queried resolver address without changing general UDP behavior or split-DNS policy.
The prototype passed 90 same-port and 192 ordinary DNS checks after startup;
four initial timeout probes remain recorded. Full lab.4 regression subsequently
passed 360 same-port and 768 ordinary DNS cases, all four HTTP/3 and Cloudflare
STUN probes and 120 additional T3 checks. Quad9 and Google STUN failures remain
recorded separately; complete packet attribution and fault coverage are pending.

Lab.4 sustained-Xray-outage test: HTTPS/IPv6 blocked, DNS refused with no answer,
no direct control-destination flow or foreign control-name DNS on LAB-1; HTTPS
restored in 6.914 seconds. Route-sync supervision was paused during the sustained
fault and independently restored. The first unpaused attempt is UNKNOWN because
the timer automatically restarted Xray about three seconds into the probe window.
The new DNS port is blocked from underlay over TCP and UDP.

Real LAB-2 reboot in INSTALLING: seven scoped checks PASS. Boot changed, automatic
rollback completed in 30.365 seconds, old config hash restored, new owned file and
backup/pending removed, watch/live tunnel healthy, manual pin preserved, client
HTTPS working. This used controlled owned-file mutation, not every installer
failure point. Full clean/reboot/load/concurrency acceptance is still pending.

Next priorities: remaining installer
interruption/SSH/concurrent-operation coverage; complete self-update
rollback (the current self-updater restores only its executable on migration
failure; the lock handover gap is fixed in lab.13); full CLI/menu,
policy, load and failover coverage. Installer writes that are not explicitly
checked require fault reproduction before any broader atomicity claim.
