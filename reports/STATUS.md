# rp laboratory status

Baseline: 3d3077d8940ac136b25cae4a6667a26531843a11, version 1.2.8-audit-fixes.
Branch: codex/rp-24x7-lab.

User amendments: use two Rocky 10.2 machines; Rocky 9 remains NOT_TESTED.
Final soak: six hours on an unchanged final commit (replaces 72 hours).
Recovery objective: <=60 seconds with a healthy available alternative; start
counting after connectivity is restored for total outages. Manual pin remains fail-closed.

Lab: LAB-1=hy2-rpm, LAB-2=hy2-rpm2; hy2-deb available as auxiliary client/endpoint.
Snapshots exist, but user cannot restore until returning. Preserve independent
management SSH. Defer reboots, whole-disk/memory exhaustion and failures requiring
console recovery until the user is available. Do not modify the router or other hosts.

Read both supplied specifications in full. Implementation must preserve all four
transports, full SNI coverage, T1-T3, and the F01-F13 acceptance matrix.
Final verdict: NOT_READY (work in progress; no acceptance or soak claimed).
