# VPS-1 migration error propagation

Candidate: 1.2.9-lab.15. This is preparation for full migration rollback, not a
claim that rollback or final release acceptance is complete.

The baseline returned success for 12 injected failure subcases. A failed daemon
reload was already propagated by the unit generator, but the migration caller
could ignore that result. Explicit status checks now cover every unit/helper
write, chmod, sysctl-file write/application and daemon reload. Both installation
and migration stop if unit generation fails.

Migration now requires creation of a private configuration backup before its
first installation change. It stops on network-service startup failure and
verifies local service readiness even when generated configs did not change.
Failure to start the route-sync timer prevents a success report. Configuration
apply failure no longer claims that the entire migration has rolled back.

`tests/test_migrate_failures.py` covers eight generator failures and five
migration-stage failures, plus successful migration and both IPv6 settings.
File-write failures use actual filesystem redirection errors in isolated paths;
service/sysctl calls are mocked. Existing services are not modified by these
fixtures. The same new test set (13 methods across three files) passes on the
Rocky 10.2 LAB-1 host. The full local suite passes 137 tests; static checks pass.
Private logs: `lab/artifacts/migrate-failures-20261121/`.

Remaining: full private snapshot/restoration of configuration, generated files,
units and runtime state; interrupted self-update recovery; live migration and
network regression of the new build. Installed endpoints remain lab.12.
