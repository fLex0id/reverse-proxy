# Client file publication: lab.19

Three negative fixtures reproduced false success on lab.18: failure to read the
list while deleting a client, failure to restore the previous list after apply
failure, and failure to create the client export directory. The first case also
truncated the live list. These are command-failure fixtures, not disk-exhaustion
or live network measurements.

Lab.19 writes client additions/deletions to private temporary files on the same
filesystem and publishes them by rename only after successful generation.
Rollback uses a private backup and retains it with an explicit diagnostic if
restoration fails. Exported configurations are likewise published only after a
successful write and permission check. Errors no longer print a successful file
path or falsely claim that the previous list was restored.

All 11 client tests pass locally and on Rocky 10.2 in isolated directories.
They cover successful addition/export, deletion of the last client, partial
write, source read failure, publication failure, apply failure, missing live
confirmation and failed restoration. The complete local suite passes 166 tests;
Bash/generated-shell syntax, ShellCheck, Python/pyflakes and embedded-helper
consistency pass. Live multi-client traffic and real storage-failure acceptance
remain pending. Installed VPS-1 is still lab.18 while its deadline test runs.

Reproduce: `python3 -m unittest discover -s tests -p test_clients_write.py -v`.

The interrupted 2026-11-21 VPS-1 deadline run is UNKNOWN: its six concurrent
commands were blocked, but sampling ended early and the independent fallback
ran. It is not a deadline PASS. A separate unchanged 1800-second run was started
on 2026-11-27 as a systemd service, with results to be recorded separately.
