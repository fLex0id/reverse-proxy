# VPS-2 installation write-failure checks

Candidate: `7471fb3`, rp lab.10, transaction helper SHA256
`6f6595c8eda20923e7d6aa51b8a3889a07e36e9bb2d6ee76d0f1710367825237`.
Actual Rocky VPS-2 installation, immutable transaction runner, independent SSH,
real systemd service lifecycle and isolated WG-client HTTPS before/after.

The fixture wraps only an exact installer command in a private per-process PATH.
It injects one nonzero exit in INSTALLING, never during PREPARING or rollback.
These are command-failure injections, not physical disk faults or new ENOSPC
measurements. Earlier real ENOSPC coverage applies to backup preparation only.

Baseline lab.9: failure of the Xray staging write printed an error but returned
zero and reached READY after full T1–T3. The fixture did not confirm it; it
explicitly rolled back and verified old hashes, watcher and client recovery.

| Injected failure | Candidate installer rc | Automatic phase | Original hashes | Watch/client | New staging files removed |
|---|---:|---|---|---|---|
| Xray staging write | 1 | ROLLED_BACK | PASS | PASS | PASS |
| Xray publication rename | 1 | ROLLED_BACK | PASS | PASS | PASS |
| Xray data-directory creation | 1 | ROLLED_BACK | PASS | PASS | PASS |
| Xray geodata write | 1 | ROLLED_BACK | PASS | PASS | PASS |
| Hysteria staging write | 1 | ROLLED_BACK | PASS | PASS | PASS |
| Hysteria publication rename | 1 | ROLLED_BACK | PASS | PASS | PASS |
| Inner-WG config installation | 1 | ROLLED_BACK | PASS | PASS | PASS |
| Configuration-directory permissions | 1 | ROLLED_BACK | PASS | PASS | PASS |
| systemd daemon-reload | 1 | ROLLED_BACK | PASS | PASS | PASS |

The compared files include the main configuration, both binaries, installed CLI,
transaction helper and WG configuration. Each case started without staging files
and finished without them. Both binary publication failures therefore exercise
the newly owned `.new` paths, not only pre-write rejection. Fixtures, private
bundle copies and transient failed test units were cleaned after restoration.

Installer-plus-rollback durations were approximately 21–44 seconds. These include
backup/download/installation and readiness work; they are **not** a measured
traffic outage or failover SLA. The watcher and a real WG-client HTTPS request
were verified after restoration, not inferred from process state alone.

Artifacts: `lab/artifacts/installer-write-before-lab9`,
`installer-write-lab10-xray-stage`, `installer-write-matrix-lab10`.
Reproduce with `lab/installer_write_fault.py --stage NAME`; never overlap another
network mutation or fault suite.

F04 remains **UNKNOWN / partial coverage**, and the project remains **NOT_READY**.
Further download/extraction/interruption/SSH/concurrency and complete stale-file
coverage are still required; this report does not replace the full acceptance
matrix or the final clean installation and six-hour soak.
