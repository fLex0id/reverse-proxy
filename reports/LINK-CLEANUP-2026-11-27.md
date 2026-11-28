# Link firewall cleanup and real menu locks: lab.22

Lab.21 fixtures reproduced ignored firewall open/close errors and removal of a
port rule that existed before link creation. Lab.22 records ownership outside
the rp-user-writable serving directory, removes only its own temporary rule,
keeps retry metadata when removal fails, and publishes cleanup-failed rather
than success. Secret files are removed even if firewall cleanup fails.
Preparation now checks file moves, permissions and positive TTL before serving.
Messages distinguish temporary rules from preexisting administrator rules.

Four new tests pass locally and on Rocky. A real firewalld test on an unused
port (19444/tcp) confirms owned-rule removal, preservation of a preexisting
fixture rule, truthful injected removal failure, and a successful cleanup retry.
The fixture rule is finally removed; an independent timed cleanup protects the
run. It does not change installed rp files or tunnel ports. Results:
results/LINK_FIREWALL_LAB22.json. Whole `rp link` service lifecycle remains to be
checked after installation of this candidate.

Six actual SSH-terminal menu cases pass on the installed lab.18 while its
migration owns the operation lock: restart, save and update in Unicode and
ASCII modes all report the lock and return to the menu. No mutation is invoked.
Results: results/MENU_LIVE_LOCKS.json. These are supplemental to the existing
28 branch fixtures, not a claim of complete interactive menu acceptance.

Complete local suite: 191 tests; static checks pass. The client lifecycle runner
is prepared but has not yet run; it will test two real isolated WG clients after
the migration deadline completes and the new candidate is installed.
