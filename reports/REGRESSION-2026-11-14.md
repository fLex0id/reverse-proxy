# Intermediate four-transport regression

Candidate: `a1f7ba6`, rp 1.2.9-lab.3, Xray 26.4.25, Hysteria2 2.8.2.
Both endpoints are Rocky Linux 10.2; the isolated WG client is on Debian 13.
Existing installations, not the final clean-install acceptance. Verdict: **NOT_READY**.

| Check | packet-up | stream-up | HY2 | HY2 + Salamander |
|---|---|---|---|---|
| Manual transport selection | PASS | PASS | PASS | PASS |
| VPS-2 full T1–T3 | PASS | PASS | PASS | PASS |
| Additional full T3 repetitions | 30/30 | 30/30 | 30/30 | 30/30 |
| VPS-1 built-in checks including restart | PASS* | PASS* | PASS* | PASS* |
| DNS configured behaviors | 192/192 | 192/192 | 192/192 | 192/192 |
| HTTP / HTTPS / DoH / DoT | PASS | PASS | PASS | PASS |
| HTTP/3-only from WG client | PASS | PASS | PASS | PASS |
| HTTP/3 duration | 0.377 s | 0.347 s | 0.347 s | 0.353 s |
| Cloudflare STUN | PASS | PASS | PASS | PASS |
| Google STUN | FAIL | FAIL | FAIL | FAIL |
| IPv6 HTTPS when disabled | blocked | blocked | blocked | blocked |

*T7 is only a static check; shared public NAT prevents T5 from proving the
egress host. These built-in results do not substitute for packet-level acceptance.
The earlier intermittent Quad9 failure did not recur here, but remains unresolved.

All application captures show two-way control QUIC on LAB-2 and no direct LAB-1
traffic to the tested application endpoints. LAB-1's stream-up capture contains
two system DNS queries for the configured REALITY target www.mos.ru; these are
service control traffic, not any name queried by the application probes.
The DNS captures contain only tested RU-direct queries (sberbank.ru, gosuslugi.ru,
ozon.ru) to the configured RU resolver; none of the tested foreign/blocked control
names appears in LAB-1 plaintext queries. This is scoped evidence from the captured
intervals, not full policy/fault/IPv6-provider acceptance.

The 768 ordinary DNS checks do not close RP-013. A separate same-source-port
regression produced 6 wrong-source responses out of 9, with matching DNS IDs.
The conntrack DNS-redirect prototype subsequently passed 90 same-port requests,
192 ordinary DNS behaviors and application probes except Google STUN. It also had
four initial five-second DNS timeouts after Xray restart; these are retained as
failures. The prototype is separate from the lab.3 results above.

Google STUN to the same real numeric target also times out directly from LAB-2.
The upstream gateway synthesizes DNS answers for system lookups, so a successful
system-resolved control cannot be substituted for that numeric comparison.
Cloudflare STUN provides independent positive UDP coverage; it does not erase
the Google result.

Artifacts remain private in `lab/artifacts/regression-lab3`, `mtu-comparison`,
`prepare-enospc` and `dns-redirect-trial`. The six-hour soak has not started.
The user must complete machine cleanup before final clean installation and soak.
