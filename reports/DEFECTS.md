# Defect register (work in progress)

## RP-001 P0: unverified update confirmed
Baseline push_wait calls confirm before reading transport results. Empty results
print FULL_OK; a failed transport is committed as DEGRADED; route sync failure
is only a warning. Reproduced in tests/test_push_acceptance.py with controlled
remote replies: 7/10 baseline failures. Candidate: 10/10 pass. Two-host push
validation and rollback remain outstanding; this is not an E2E PASS.

## RP-002 P1: routing override success assumed without readback
Baseline route_api_override only checks the bo exit code. Verified Xray 26.4.25
supports `api bi --json BALANCER`, returning balancer.override.target.
Added readback and reject mismatch/missing response. Four of six negative/positive
regressions fail against baseline; all six pass against candidate.

## RP-003 P1: rollback durability/completeness (inspection, not yet reproduced)
Transient rollback timer does not survive reboot. Confirm and rollback lack a
shared transaction lock. Backup omits binaries and most runtime state, and restores
whole authorized_keys, risking unrelated changes. Failed-new files can remain.
Requires controlled real-systemd fault tests and a durable transaction design.

## RP-004 P1: reinstall destroys client inventory (inspection)
vps1_install unconditionally truncates clients.tsv and regenerates secrets despite
UI promise that client keys survive reinstall. Needs regression and correction.

## Environment findings
Rocky LAB-1 clock lagged ~7 days after snapshot; corrected with chronyc makestep.
Both LAB hosts are Rocky 10.2 with SELinux Enforcing and active firewalld.
LAB-2 baseline T1-T3: all four transports PASS. LAB-1 baseline T1-T6b PASS;
T7 static only, T8 explicitly skipped without --restart. Shared NAT means the
built-in equal-public-IP check alone is not accepted as egress provenance.

## Candidate regression: installer mutation lock
First durable-transaction E2E push rejected its own fixnet subprocess because
RP_TX_INTERNAL was only set for select. The new automatic rollback actually ran
on LAB-2 and restored the old active tunnel; independent SSH keys compared equal
to the baseline after removing only rp's own key. Backup was cleaned and watcher
active. Fixed installer-internal fixnet authorization; repeat push pending.

## RP-005 P2: intermittent DoH probe failure
During the four-transport matrix, hy2-wg T6 to Quad9 failed once while client HTTPS
and DNS succeeded. Other transports passed that probe. Not dismissed as flaky;
repeat and packet capture required to distinguish upstream refusal from transport
or probe implementation defects.

## Candidate regression: rollback readiness
Real rollback restored the old files and started the correct transport, but an
immediate _func probe ran before the reverse bridge/observatory was ready. The
helper correctly retained ROLLING_BACK plus its backup instead of claiming success.
A later independent probe passed. Added bounded readiness polling before declaring
ROLLED_BACK and restarting the watcher; complete transaction tests repeated.

## Confirmed intermediate E2E evidence
- Successful candidate push completed all four T1-T3 and reached COMMITTED.
- Isolated WG client obtained HTTPS and DNS with each of four manually selected transports.
- In each controlled HTTPS capture to 1.1.1.1:443, LAB-1 had zero direct destination
  packets while LAB-2 had the corresponding flow. This is a scoped observation,
  not proof of all possible paths.
- Stopping rp-xray blocked HTTPS (curl timeout), forced foreign DNS to 8.8.8.8
  (DNS socket timeout), and IPv6 HTTPS (timeout); client HTTPS recovered after start.
  LAB-1 capture contained zero direct packets to the HTTPS target and no plaintext
  failclosed-control DNS query. Native provider IPv6 remains NOT_TESTED.
