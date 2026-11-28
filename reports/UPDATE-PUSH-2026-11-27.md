# Installed lab.23 update and push checks

File-based migration and process-substitution migration both reached COMMITTED.
The streamed launch fetched its matching source from immutable GitHub commit
c8ba2c74caee60bb19e6b778c5416c1457c7c5d9. Installed script SHA256 remains
2d6e6d7962c4d02a9c8f0b39a463265efd8419d29dec9a2accf00b6e722a5095.
Three installed-updater negative cases pass: unavailable source file, unrelated
text and a full script with a syntax error. All return 1 without changing the
installed script/config/client hashes, other-service PIDs or update staging.
These are download-source failures, not a whole-host Internet-outage test.

The initial push completed full T1-T3 for all four transports, then correctly
withheld confirmation because the saved exit-IP fingerprint no longer matched
the laboratory's external address. Both the SOCKS probe and VPS-2's direct
request returned the same new address; an independent management SSH check on
VPS-2 confirmed it. Only the laboratory's expected VPS2_IPH was refreshed. The
production guard and its timeout were not weakened or changed. The original
failed push remains a FAIL in the results.

The existing READY transaction then passed the unchanged production push_wait
checks and committed. A second, ordinary `rp push` of the same candidate passed
all four complete T1-T3 and reported FULL_OK/COMMITTED without manual intervention.
This distinguishes resuming a checked transaction from an ordinary successful CLI
run. Public scalar evidence: results/UPDATE_PUSH_LAB23.json and
results/UPDATE_REJECTION_LAB23.json. Private logs remain under lab/artifacts.

The full network regression is being prepared with its controller on the
auxiliary Debian host, so session interruption cannot terminate its collection.
Six-hour soak remains deferred; final clean installation has not started.
