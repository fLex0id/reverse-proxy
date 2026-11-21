# Recoverable VPS-1 migration and self-update

Candidate: 1.2.9-lab.16. Final acceptance remains NOT_READY.

`rp migrate` and the updated `rp update` implementation now use the same private
transaction before replacing the executable or applying configuration. The
standalone Python supervisor is embedded into rp.sh; installation still needs
only that one script. The previous VPS-2 transaction is unchanged.

The transaction saves rp configuration/client data, generated helpers and unit
files, binaries, WG files, RU assets and route-state files. It records active/
enabled states of owned units, rp's nft tables, rules/routes in its reserved
routing tables, affected sysctls and individual managed firewalld ports. It does
not replace the entire host firewall, SSH settings or unrelated unit files.

The archive is SHA256-verified and rejects links/devices and paths outside the
explicit owned-path list. Directory permissions are 0700; archive and metadata
are 0600. A verified snapshot precedes candidate execution. A gated child cannot
start mutation before its process identity is durably recorded. The operation
lock remains held across the supervisor, candidate and synchronous rollback.
New mutating commands and background route synchronization defer while recovery
is pending.

An ordinary migration failure triggers immediate restoration. A separate
systemd timer detects a dead supervisor or the fixed 30-minute deadline and
recovers without the initiating SSH connection. `rp migrate-recover` retries
recovery. A live owner before the deadline is left alone. Recovery checks process
start identity and boot identity before signalling its own child session.

Restoration verifies the archive before stopping services, restores previous
files and absence of newly created owned files, restores runtime state and
checks previously active services using the previous implementation. Owned files
and directory entries are flushed before publishing COMMITTED/ROLLED_BACK.
Restoration failure leaves a nonterminal state and the archive available; it
never becomes success. The most recent private archive is retained for diagnosis.
Uninstall also removes the two recovery units.

## Evidence and scope

- Local tests cover scoped archive restoration, permissions, preservation of
  unrelated units/drop-ins, corruption and unsupported-member rejection, failed
  restoration/fsync, pending-operation guards, PID/boot identity and runtime scope.
- On Rocky LAB-1 an actual candidate was installed, generated units and config
  were changed, then a deliberate failure was injected. The previous hashes,
  modes, selected kernel state and active/enabled service states were restored.
- A separate run killed the actual supervisor with SIGKILL after mutation. The
  installed timer restored the same state without explicit rollback invocation.
- Both used an independent fallback timer; it was not needed. Client HTTPS
  through the isolated WG client was checked separately after restoration.
- Full scenario durations include compression, preparation and readiness checks;
  they are not continuous client-outage or SLA measurements.

The final ordinary-failure repeat took 48.687 seconds and the final SIGKILL
repeat 66.786 seconds including preparation. All 152 local tests and static
checks passed. A repeated explicit recovery on terminal ROLLED_BACK returned 0.
Published scalar results: [MIGRATION_ROLLBACK.json](results/MIGRATION_ROLLBACK.json).

Private evidence is under `lab/artifacts/migration-20261121/` and the matching
root-only LAB-1 directory. Only scalar outcome summaries are published.

Remaining acceptance includes actual reboot during migration, the real 30-minute migration deadline, full disk-failure
coverage of restoration itself, concurrent live operations, all stream-launch
paths, native IPv6 restoration, successful immutable-URL self-update and complete
four-transport network regression of the resulting candidate. The final clean
installation/three regressions/six-hour soak still require the operator cleanup
gate. No claim about those unfinished cases is made by these scoped passes.
