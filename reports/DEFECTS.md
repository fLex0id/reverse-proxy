# Defect register (work in progress)

## RP-013 P1: DNS reply source reused across resolver destinations
The lab.2 full regression had one timeout out of 768 DNS behaviors. Packet
analysis confirms a real reply-address defect, not just a slow RU resolver:
client 10.66.0.2:40640 queried 192.0.2.53:53 for ozon.ru A (ID 2625), but the
response was sourced from 8.8.8.8:53 to the same port with matching ID and answer.
The connected UDP client correctly rejected it. Both resolvers are intercepted;
this does not show a direct foreign DNS leak. Deterministic source-port reuse
reproduction and a correction are pending. Do not extend timeouts to conceal it.

## RP-012 follow-up: live WireGuard MTU was not applied
Real migration changed the generated file to 1280 but the link stayed at 1080:
`wg syncconf` strips wg-quick fields including MTU. Apply now explicitly sets
the live MTU from the installed file. Rollback uses the restored file rather
than pending rp.conf values. Full apply also reconciles existing links when
the generated file is unchanged. A fixture reproduces the old failure and
verifies both interfaces on apply and restoration. 79 local tests PASS.

## RP-012 P1: inner WireGuard MTU prevents QUIC over both Hysteria transports
Packet captures on LAB-2 show 1200-byte QUIC Initial/reply datagrams followed by
ICMP fragmentation-needed (MTU 1080). With unchanged candidate lab.2, runtime-only
changes to MTU 1280 on both inner WG interfaces change HTTP/3 from timeout to PASS:
hy2-wg 8.280s timeout -> 0.357s; hy2o-wg 8.206s timeout -> 0.375s.
Independent restore timers were armed before changing either interface. HTTP,
HTTPS, DoH and DoT still pass; LAB-1 has no direct control-destination packets.
Google STUN still fails, including a direct numeric LAB-2 control; it is not
counted as a fix or removed from regression. A second Cloudflare STUN endpoint
is added separately for positive UDP coverage.

Candidate lab.3 migrates missing/old factory EXIT_MTU to 1280 and validates
1228..65535 when rendering both ends; other operator settings are not overwritten.
The lower bound is 1200 + IPv4 20 + UDP 8, per
[RFC 9000 section 14](https://www.rfc-editor.org/rfc/rfc9000.html#section-14).
Hysteria's own UDP fragmentation is part of its
[specified protocol](https://v2.hysteria.network/docs/developers/Protocol/#fragmentation),
not a DF-clearing workaround. Deployment and full lab.3 regression are pending.

## RP-008 additional real ENOSPC coverage
A 128-KiB tmpfs mounted only on the transaction directory caused real kernel
ENOSPC while preparing the backup, without filling the root filesystem.
Six assertions PASS: actual ENOSPC, ROLLED_BACK, partial archive/markers removed,
old config byte-identical, watcher active, old tunnel live in both directions.
The temporary filesystem was unmounted and its independent cleanup timer stopped.
This covers preparation failure, not every installation disk-write failure.

## RP-011 P1: menu mutations bypass the CLI operation lock
The client, RU, DNS and main menus called mutating functions without the lock
used by their CLI equivalents. Concurrent menu/CLI operations could overwrite
configuration or interfere with an update. Actual menu branches driven with
fixture input and a second flock process reproduced 19 failures out of 28 cases.
All 28 pass after locking each mutation; read-only menus do not hold the lock
while waiting for input. Installation, save and bundle entry points also acquire
the operation lock. Full suite: 74 tests PASS; generated-code static checks PASS.
Concurrent live push/menu fault acceptance remains outstanding.

## RP-001 P0: unverified update confirmed
Baseline push_wait calls confirm before reading transport results. Empty results
print FULL_OK; a failed transport is committed as DEGRADED; route sync failure
is only a warning. Reproduced in tests/test_push_acceptance.py with controlled
remote replies: 7/10 baseline failures. Candidate: 10/10 pass. Two-host push
validation and rollback remain outstanding; this is not an E2E PASS.

## RP-002 P1: routing override success assumed without readback
Baseline route_api_override only checks the bo exit code. Verified Xray 26.4.25
supports `api bi --json BALANCER`, returning balancer.override.target.
Added readback and reject mismatch/missing response. Four of six negative/positive
regressions fail against baseline; all six pass against candidate.

## RP-003 P1: rollback durability/completeness (inspection, not yet reproduced)
Transient rollback timer does not survive reboot. Confirm and rollback lack a
shared transaction lock. Backup omits binaries and most runtime state, and restores
whole authorized_keys, risking unrelated changes. Failed-new files can remain.
Requires controlled real-systemd fault tests and a durable transaction design.

## RP-004 P1: reinstall destroys client inventory (inspection)
vps1_install unconditionally truncates clients.tsv and regenerates secrets despite
UI promise that client keys survive reinstall. Needs regression and correction.

## Environment findings
Rocky LAB-1 clock lagged ~7 days after snapshot; corrected with chronyc makestep.
Both LAB hosts are Rocky 10.2 with SELinux Enforcing and active firewalld.
LAB-2 baseline T1-T3: all four transports PASS. LAB-1 baseline T1-T6b PASS;
T7 static only, T8 explicitly skipped without --restart. Shared NAT means the
built-in equal-public-IP check alone is not accepted as egress provenance.

## Candidate regression: installer mutation lock
First durable-transaction E2E push rejected its own fixnet subprocess because
RP_TX_INTERNAL was only set for select. The new automatic rollback actually ran
on LAB-2 and restored the old active tunnel; independent SSH keys compared equal
to the baseline after removing only rp's own key. Backup was cleaned and watcher
active. Fixed installer-internal fixnet authorization; repeat push pending.

## RP-005 P2: intermittent DoH probe failure
During the four-transport matrix, hy2-wg T6 to Quad9 failed once while client HTTPS
and DNS succeeded. Other transports passed that probe. Not dismissed as flaky;
repeat and packet capture required to distinguish upstream refusal from transport
or probe implementation defects.

## Candidate regression: rollback readiness
Real rollback restored the old files and started the correct transport, but an
immediate _func probe ran before the reverse bridge/observatory was ready. The
helper correctly retained ROLLING_BACK plus its backup instead of claiming success.
A later independent probe passed. Added bounded readiness polling before declaring
ROLLED_BACK and restarting the watcher; complete transaction tests repeated.

## Confirmed intermediate E2E evidence
- Successful candidate push completed all four T1-T3 and reached COMMITTED.
- Isolated WG client obtained HTTPS and DNS with each of four manually selected transports.
- In each controlled HTTPS capture to 1.1.1.1:443, LAB-1 had zero direct destination
  packets while LAB-2 had the corresponding flow. This is a scoped observation,
  not proof of all possible paths.
- Stopping rp-xray blocked HTTPS (curl timeout), forced foreign DNS to 8.8.8.8
  (DNS socket timeout), and IPv6 HTTPS (timeout); client HTTPS recovered after start.
  LAB-1 capture contained zero direct packets to the HTTPS target and no plaintext
  failclosed-control DNS query. Native provider IPv6 remains NOT_TESTED.

## RP-006 P1: auto failover exceeds the 60-second objective
A real output drop limited to LAB-2 -> LAB-1 TCP/8443 caused client outage longer
than 60 seconds despite a working stream-up/Hysteria reserve. The watchdog waits
15..35 seconds between samples, allows long per-probe timeouts, waits 8..15 seconds
between failures, and retries the already failed transport's full T2/T3 BEFORE
trying reserves. Route synchronization can add another 20..35 seconds.
Candidate keeps three consecutive failed health samples and all complete T1-T3,
but bounds lightweight health samples, uses shorter retry gaps, tries reserves
first in auto only, and polls route state more frequently. Manual pin behavior
is preserved. Factory cadence migration is explicit; custom settings remain.
A repeated real-packet fault measurement is required; no SLA PASS claimed yet.

Follow-up: the first identical TCP/8443 block with the new watcher restored client
HTTPS through stream-up in 48.855 seconds (previously >200 seconds). This is one
scenario/repetition, not acceptance of the entire failover matrix.

## RP-007 P1: removal deletes unrelated services
Both removal functions used rp-*.service/timer globs; VPS-1 also removed the whole
wg-quick@wg0.service.d directory. Both fixture regressions reproduced deletion of
an unrelated rp-unrelated.service. Use explicit unit lists and remove only rp.conf
from the WireGuard drop-in directory. Tests now pass; clean-host removal E2E pending.

## RP-008 P1: preparation crash can leave supervision disabled
The first durable helper stopped the watcher before arming recovery, leaving a
SIGKILL/power-loss window while compressing the backup. A fault regression failed
before the change. Persist PREPARING and arm recovery before stopping supervision.
On LAB-2, a real SIGKILL inside archive creation left the real timer active; its
recovery service restored the watcher without extracting the partial archive.
All eight checks passed. The unchanged full 30-minute confirmation deadline was
also observed: rollback finished after 1810.397 seconds; old configuration and
live tunnel restored, synthetic new file/archive/pending markers removed.

## RP-009 P1: reinstall resets network policy and Hysteria certificate pin
The prior client/key fix did not preserve custom ports, DNS, transport selection,
MTUs, doors or the pinned TLS certificate. A real-OpenSSL fixture reproduced four
identity failures, and the installer fixture reproduced settings resets. Candidate
preserves these values and rejects corrupt/partial/mismatched certificate identity.
Fixture tests pass; complete live reinstall regression remains pending.

## RP-010 P1: HTTP/3 through stream-up times out
Real WG-client HTTP/3-only requests to 1.1.1.1 time out, despite working HTTP,
HTTPS, DoH and DoT. The QUIC Initial reaches LAB-1 wg0 but no corresponding
UDP/443 packet appears on LAB-2 underlay. Direct numeric QUIC on LAB-2 responds;
direct Debian HTTP/3 succeeds. Root-cause investigation ongoing; no fix claimed.
STUN to its real numeric public destination also times out directly on LAB-2;
the gateway provides synthetic 198.18.x.x DNS answers for system-resolved names.
This environment difference must be separated from the QUIC forwarding defect.

Root cause confirmed with temporary private info logs: Xray receives QUIC from
the WG client but FakeUDP cannot bind the foreign reply address because Hysteria
already owns wildcard UDP/443 (`socket bind: address already in use`).
The same applies to Salamander's wildcard UDP/8443. Bind both Hysteria listeners
to an assigned underlay IPv4. PUBLIC_IP is used if assigned, otherwise detect its
local route source (NAT); optional HY2_BIND_IP must also be locally assigned.
After migration, client HTTP/3 succeeds in 0.367 s. PCAP shows UDP/443 in both
directions on LAB-2 and no direct control-destination flow on LAB-1. Other previously
working HTTP/HTTPS/DoH/DoT checks pass. Four-transport regression is pending.
The pinned implementation was checked in Xray 26.4.25,
`proxy/dokodemo/fakeudp_linux.go`, commit b4f08981becb71eaa995fa98ed2098ade92566bb.
