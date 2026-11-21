# Published test evidence

`LAB_RESULTS_SNAPSHOT.json` contains selected outcome and measurement fields
from 123 historical result files. Each entry identifies its local source and
SHA256. This preserves PASS/FAIL/SKIP/UNKNOWN observations, timings and return
codes, including unsuccessful baseline and fixture runs. Entries from different
builds are historical evidence, not additional passes of the final build.

The export uses an explicit field allowlist. Raw logs, command output, packet
payloads, DNS answers, live configurations, credentials and backup archives are
not published. Original files remain on the controller. No result is upgraded
to PASS during export; a successful harness exit is not an acceptance verdict.

`VALIDATION_LAB12.json` records the source hash and existing local validation
results. The full lab.12 network run is the entry whose source is
`lab/artifacts/lab12-validation-20261121/regression/results.json`.

`BACKUP_VALIDATION.json` records checks performed while preparing this backup.
Those checks do not deploy software or run laboratory network experiments.

The project's verdict remains **NOT_READY**. Clean-install acceptance and the
unchanged six-hour soak are still outstanding.
