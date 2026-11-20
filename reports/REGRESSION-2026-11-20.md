# Lab.7 four-transport regression and diagnostic follow-up

Network candidate: `9fdb646`, rp 1.2.9-lab.7; harness checkpoint `5814784`.
Installed rp.sh SHA256: `2b4ce06407ab2eb809fae820b71aab80c0432fb151cb953355804a293d257659`.
Existing Rocky 10.2 endpoints, Debian 13 isolated WG client. Xray 26.4.25 and
Hysteria2 2.8.2 remain pinned. This is not final clean-install or soak acceptance.

| Check | packet-up | stream-up | HY2 | HY2 + Salamander |
|---|---|---|---|---|
| Manual selection | PASS | PASS | PASS | PASS |
| Complete VPS-2 T1–T3 | PASS | PASS | PASS | PASS |
| Additional complete T3 repetitions | 30/30 | 30/30 | 30/30 | 30/30 |
| VPS-1 built-in run with restart | PASS* | PASS* | FAIL: T6 Quad9 | PASS* |
| DNS configured behaviors | 192/192 | 192/192 | 192/192 | 192/192 |
| Same-source-port DNS replies | 90/90 | 90/90 | 90/90 | 90/90 |
| HTTP / HTTPS / DoH / DoT | PASS | PASS | PASS | PASS |
| HTTP/3-only | PASS | PASS | PASS | PASS |
| HTTP/3 duration | 0.390 s | 0.376 s | 0.334 s | 0.404 s |
| Cloudflare STUN | PASS | PASS | PASS | PASS |
| Google STUN | FAIL | FAIL | FAIL | FAIL |
| Disabled IPv6 HTTPS | blocked | blocked | blocked | blocked |
| Inner-WG kernel reset follows WG | not applicable | not applicable | PASS | PASS |

*T7 is static; T5's equal public IP cannot prove the egress host behind shared
NAT. T8 actually restarts services. SVCB/HTTPS DNS query timeouts count only as
the configured blocking behavior, never a successful DNS answer. All required
T1–T3 checks and both-direction 200-KiB payloads were retained.

The four Google STUN failures and Quad9 T6 failure remain FAIL. Separate controls
reproduce Google STUN failure at the same numeric destination directly on LAB-2;
paired Quad9 TLS failures also occur directly. The operator confirms upstream
VPN/TSPU conditions. See DOH-2026-11-20.md for attribution and limits: an external
cause is probable, but the exact source is unproven. These results are not removed
or converted to success, and they do not block unrelated engineering indefinitely.

## Packet evidence

LAB-1 captures were re-read with **all source addresses**, including internal-WG
addresses. Application captures contain no direct control-destination traffic.
Stream-up contains only two system DNS queries (A and AAAA) for the configured
REALITY target www.mos.ru and their replies. The four DNS captures each contain
only sberbank.ru, gosuslugi.ru and ozon.ru A queries to the configured RU resolver,
and their replies. No tested foreign/blocked query appears in LAB-1 plaintext.

LAB-2 QUIC captures confirm traffic to/from 1.1.1.1: packet-up 8/13 packets,
stream-up 8/13, HY2 11/11, Salamander 13/14. Both inner-WG reset probes see the
injected ACK and one returned RST on WG, with zero matching underlay resets.
The additional paired DoH repeat likewise has zero LAB-1 control-destination
packets despite external TLS failures. This is scoped packet evidence, not
proof for all policy exceptions, native IPv6, overload or every failure mode.

The old lab.4 LAB-1 captures were also re-read without the former source-address
filter: the same limited RU/control DNS pattern appears, with no inner-source
reset during those particular intervals. That does not invalidate the later
deterministic RP-015 reset leak reproduced outside those intervals.

## Diagnostics and update behavior

Lab.6's real push encountered HTTP 404 from the configured Rocky mirror while
all base dependencies were already installed. It failed and automatically rolled
back, restoring the old working tunnel. Lab.7 installs only missing dependencies;
repeat push passed complete T1–T3 for all transports and reached COMMITTED without
changing repositories, package verification or unrelated installed OS versions.

Stopping the actual rp-net service reproduced lab.7 `rp diag` returning zero
despite its printed error. Candidate lab.8 returned one for the same sustained
fault. Independent restoration was armed first; network service, client WG and
Xray were individually checked after restoration, and client HTTPS succeeded.
Lab.8 adds complete status propagation and post-repair revalidation. Its generated
VPS-2 files were proven byte-identical to all ten installed lab.7 files.

That live diagnostic exposed RP-018: the old VPS-2 egress report queried intra-zone
forwarding despite using an active inter-zone policy. Candidate lab.9 corrects
runtime policy inspection, without changing firewall access rules. Its sourced
helper reports yes on the real healthy policy; installed baseline reported no.
Lab.9 migration and push then passed complete T1–T3 and reached COMMITTED;
installed `rp diag` passed on all four transports with one `fw_forward=yes` line.

Private artifacts: `regression-lab7`, `review-lab7-all-sources`,
`review-lab4-all-sources`, `diag-net-fault-lab8`, `push-lab6.log`, `push-lab7.log`,
`lab7-lab8-vps2-equivalence.json`, plus the paths in DOH-2026-11-20.md.

Verdict: **NOT_READY**. Installer fault/write coverage, self-update rollback,
complete CLI/menu acceptance, broader DNS/leak/fault/load tests, final clean
regressions and the unchanged six-hour soak remain outstanding. The user must
finish machine cleanup before final clean installation and soak; no soak began.
