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
Further interruption/SSH/concurrency coverage is still required; this report
does not replace the full acceptance
matrix or the final clean installation and six-hour soak.

## SIGKILL during the actual installer, followed by real reboot

Installed lab.11 (`e50929e`), with the same durable helper. The private wrapper
records INSTALLING and the installer PID/start identity, then sends SIGKILL to
that exact process. Its EXIT trap cannot perform rollback. The controller first
confirms the interrupted phase and then requests a real VPS-2 reboot. Recovery
uses the installed boot service and immutable runner, with no manual rollback
before observation and no change to the production 30-minute deadline.

| Interruption point | Staging file observed | Boot rollback completed | Final verification |
|---|---|---:|---|
| Before Xray publication rename | xray.new | 29.769 s | PASS |
| Before Hysteria publication rename | hysteria.new | 30.154 s | PASS |
| Before daemon-reload, after config writes | none | 30.106 s | PASS |

All three observations began at the reboot request and ended when ROLLED_BACK
was persisted. SSH returned in approximately 22.5 seconds. These are boot
recovery timings, not continuous client outage/SLA measurements. Each case
verified changed boot ID, old configuration/binary/CLI/helper/WG hashes, absence
of staging files, active watcher and a real isolated-client HTTPS response.
Fixtures were removed and all transactions ended ROLLED_BACK. This is a
controlled reboot after SIGKILL, not an assertion about arbitrary power loss.

Artifacts: `installer-kill-reboot-lab11-xray`,
`installer-kill-reboot-lab11/{hy2-publish,daemon-reload}`.

The first expanded download fixture was invalid: its command passthrough
assumed `/usr/bin/sysctl`, whereas Rocky has sysctl in sbin. This also impeded
rollback; an explicit normal runner invocation restored the baseline and client.
Its recorded FAIL is retained in `installer-network-files-lab11/xray-download`,
classified as a harness error, not candidate evidence. The corrected passthrough
uses the normal system PATH; results from that repeat are tracked separately.

## Download, integrity, extraction and network setup failures

The corrected lab.11 repeat passed all nine additional cases:

| Failure | Injected attempts | Installer rc | Automatic rollback and final hashes/watch/client |
|---|---:|---:|---|
| Xray download | 5 | 1 | PASS |
| Hysteria download | 5 | 1 | PASS |
| Xray payload checksum | 1 | 1 | PASS |
| Hysteria payload checksum | 1 | 1 | PASS |
| Xray unzip | 1 | 1 | PASS |
| Bundle extraction | 1 | 1 | PASS |
| NAT service restart | 1 | 1 | PASS |
| firewalld reload | 1 | 1 | PASS |
| sysctl application | 1 | 1 | PASS |

Both download cases retain the real five-attempt backoff. Checksum cases return
a successful transfer with deliberately invalid local payload bytes; the real
installer digest check rejects them. Other cases inject one exact command error
only during INSTALLING. All observed terminal states are ROLLED_BACK before any
fixture fallback, and all final hash, watcher, client and staging checks pass.
Durations were approximately 18–83 seconds including installation and rollback,
not continuous client outage measurements. No root-disk exhaustion was involved.

Artifacts: `installer-network-files-lab11-repeat/{STAGE}`. Alongside the earlier
nine lab.10 command failures and three lab.11 kill/reboot points, this expands
scoped evidence without claiming every installer/state/concurrency combination.
