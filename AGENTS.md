# Project continuity

Before changing rp, read `reports/STATUS.md`, `reports/WORK_SUMMARY_RU.md`,
`reports/ACCEPTANCE.json` and the latest relevant evidence under `reports/results/`.
Check Git status and actual host state before assuming a prior operation is still
running or an ephemeral client still exists. Preserve correct existing changes;
do not repeat completed acceptance without a relevant change or unresolved concern.

## Saved checkpoint: 2026-11-28

- Working branch: `codex/rp-24x7-lab`. Commit and push completed stages there.
  Do not merge into or change `main`, or change
  `backup/rp-lab12-20261121-021344`, without the user's new instruction.
- Published first preliminary release: `v1.2.9-lab.23`, source commit
  `8aebd7d6a41b5ff30f305d4e835d728489b9cdda`. Publication verification:
  `reports/results/RELEASE_PUBLICATION_LAB23.json`.
- This is a Pre-release; stable acceptance remains NOT_READY. Do not equate
  publication with completion of F01-F13 or demonstrated 24/7 endurance.
- Preserve the existing architecture, all four transports, full SNI checks and
  complete T1-T3. Do not weaken checks or turn failed/unknown results into PASS.
- The six-hour soak is deferred until after the user's additional changes and
  later instruction. Before final clean installation, notify the user and wait
  for their agreed machine cleanup; preserve independent management SSH.
- Authorized lab aliases: `hy2-rpm` (VPS-1), `hy2-rpm2` (VPS-2), `hy2-deb`
  (auxiliary isolated WG client). Both VPS roles use Rocky 10.2; Debian 13 is
  auxiliary. Rocky 9 and other server platforms are not accepted by this evidence.
- The Debian client namespace is temporary and disappears on reboot. Restore
  and verify it before network fault injection; missing test infrastructure is
  not a product failure or evidence of fail-closed behavior.
- External VPN/network faults are possible. Preserve failed observations and
  independent direct controls; do not attribute every failure to rp or claim
  the external cause is proven without evidence.
- Do not investigate or attempt to fix vulnerabilities in the underlying
  protocols; the user explicitly excluded that work. Do not run the archived
  `hy2_acl*` probes or add that topic to new user-facing reports.
- Never commit credentials, private configurations, raw captures or temporary
  files. Existing private artifacts remain under ignored `lab/private/` and
  `lab/artifacts/`. Keep previous unsuccessful attempts as evidence.

New user instructions take precedence over this checkpoint.
