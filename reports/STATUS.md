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

## Current checkpoint (2026-11-14)

Installed candidate: a1f7ba6, 1.2.9-lab.3. Ordinary VPS-1 migration and VPS-2
push completed; all four full T1-T3 passed and transaction reached COMMITTED.
79 local regression tests and generated-code static checks pass.
Final clean installation and six-hour soak have NOT started.

New commits since dcee312:
- 4650bdd: serialize mutating menu/installer/save/bundle entry points.
- 7e2905f: inner WG MTU 1280 with explicit factory migration and validation;
  actual ENOSPC/MTU comparison and four-transport regression tooling.
- a1f7ba6: update live WG MTU on apply and restore it from rollback files.

Actual ENOSPC during transaction preparation: 6/6 checks PASS, cleanup complete.
HTTP/3 with each Hysteria variant: FAIL at MTU 1080, PASS at 1280, with simultaneous
client/LAB-1/LAB-2 PCAPs; no direct LAB-1 packets to the control destination.
Expanded lab.3 regression is running. Earlier lab.2 run passed 120 consecutive
T3 payload checks (30 per transport), but exposed HY2 HTTP/3 and a DNS reply-source
defect. DoH/Quad9 remained intermittent. Google numeric STUN also fails directly
from LAB-2; an additional independent Cloudflare STUN case is now retained.

RP-013 remains OPEN: one reused client UDP source port can receive a DNS answer
from a previous resolver address. Packet proof is retained. A dedicated same-port
test and isolated DNS redirect prototype are prepared; the prototype is not
deployed in the candidate and must be tested after the current regression.
