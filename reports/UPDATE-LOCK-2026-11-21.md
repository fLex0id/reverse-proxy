# Self-update operation-lock handover

Candidate: 1.2.9-lab.13. Installed endpoints remain lab.12.

The previous self-updater unlocked fd 9 before launching the candidate's
`migrate`. Another mutation could enter during that gap. Retaining the lock
without changing the child caused the child to time out against its parent.

`lock()` now verifies fd 9 against the actual lock inode and attempts `flock`
on that descriptor before opening another. The self-updater never releases it
before migration or rollback. No environment flag bypasses lock acquisition.

Evidence from `tests/test_update_lock.py`, using actual Bash/flock processes:

| Case | Previous source | Candidate |
|---|---|---|
| Child inherits lock; parent keeps it after child exit | FAIL | PASS |
| Unrelated fd 9 cannot stand in for rp lock | PASS | PASS |
| Matching but initially unlocked descriptor is locked | PASS | PASS |
| Competitor cannot enter before child's lock or during failed update | FAIL | PASS |

All four candidate tests also passed on the authorized Rocky 10.2 LAB-1 host
in an isolated temporary fixture. No installed services/configurations changed.
The complete local suite passed 128 tests; Bash/generated-code static checks
passed. Private logs: `lab/artifacts/update-lock-20261121/`.

This closes the concurrency window only. The updater still restores only its
executable after migration failure. Full configuration/service rollback,
interrupted-update recovery and final live acceptance remain open. NOT_READY.
