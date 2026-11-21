# Configuration publication on storage failure

Candidate: 1.2.9-lab.14. Installed endpoints remain lab.12.

The configuration setter ignored copy, grep, append, chmod and rename failures.
In particular, it treated every grep error like an empty result and could replace
`rp.conf` with incomplete content, then return success after reloading that file.
This affects migration and other configuration-changing commands.

The setter now stops on each I/O error, keeps all intermediates in a private
0700 staging directory, sets 0600 before publication and replaces the old file
only after successful preparation. Empty grep output (status 1) remains valid;
read/write errors are rejected. Odd argument counts are rejected. Memory is
reloaded only after publication. This is not a full migration transaction or
proof of persistence through a power failure.

`tests/test_conf_write.py` exercises seven distinct storage-failure stages,
missing/existing configs, empty filter results, argument validation, permissions,
preservation of unrelated settings and memory reload. The baseline produced
eight failing subcases. Candidate checks pass.

`lab/conf_write_fault.py` ran on Rocky 10.2 with real kernel ENOSPC in private
96-KiB tmpfs mounts. Synthetic configuration input; no installed rp files or
services were changed. Both mounts were unmounted afterwards.

| Result | Baseline | Candidate |
|---|---|---|
| Actual ENOSPC observed | yes | yes |
| Command status | 0 (incorrect success) | 1 |
| Original configuration preserved | no | yes |
| Final permissions | 0600 | 0600 |
| Staging removed | yes | yes |
| Success reported | yes (incorrect) | no |

Published measurements: [CONFIG_WRITE_ENOSPC.json](results/CONFIG_WRITE_ENOSPC.json).
Private logs: `lab/artifacts/conf-write-20261121/`. Full rollback of all migration
state and units remains pending. NOT_READY.
