# Configuration application and RU edits: lab.21

Negative fixtures reproduced application continuing after backup failure,
ignored private staging permissions, leftover publication files and an
unreported failure to restore the original file. Lab.21 checks these operations,
uses unique private backup directories, restores files via same-filesystem
staging/rename and reports incomplete restoration with the backup location.
Automatic retention only removes older committed application backups; script
update backups and failed application backups are retained.

RU exception changes now stage both source lists, validate deletions as domain
names and compare literal strings. Publication or application failure restores
the original lists (including original absence); restoration errors are explicit.
The existing foreign-domain direct-route guard remains unchanged. `rp ru off`
no longer reports success if configuration or timer changes fail.

Fourteen new command-failure tests pass locally and on Rocky 10.2. The complete
suite passes 187 tests and static checks. Real ENOSPC tests use an isolated
96-KiB tmpfs, unmounted in finally: client staging and application backup failure
both return nonzero, preserve original bytes/mode, remove staging, and never
reach application of services. Installed rp paths and the root disk are not
used for these storage fixtures. Sanitized results: results/STORAGE_ENOSPC_LAB21.json.

These checks do not establish power-loss durability for ordinary `rp apply`
or replace the final live RU routing and multiple-client acceptance tests.
