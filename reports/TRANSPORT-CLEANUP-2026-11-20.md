# Transport subset deployment and restoration

Candidate `e50929e`, rp 1.2.9-lab.11; existing Rocky 10.2 endpoints and isolated
Debian WG client. These are development cycles, not final clean installation.

Baseline lab.10's 4 → two XHTTP → 4 cycle committed both pushes and served the
client, but incorrectly retained two unused inner-WG configuration files with
credentials. A controlled legacy `xray-tcp.json` fixture also survived. The
harness restored all four transports and removed only its own legacy fixture.

Lab.11 generates WG credentials only when Hysteria is selected. It stops and
verifies the old inner-WG interface before deleting its configurations, and
removes the obsolete TCP configuration. Private VPS-1 identity is preserved.

| Real cycle | Result | Checks |
|---|---|---:|
| Four → both XHTTP → four | PASS | 39 |
| Four → both Hysteria → four | PASS | 39 |

Each cycle checks selected order, COMMITTED state, presence of selected configs,
absence of excluded/legacy configs, WG config presence according to selection,
and real client HTTPS, DNS and HTTP/3 at both the two- and four-transport stages.
Every push retains complete configured T1–T3; the restored deployment tests all
four. Original VPS-1 config, client inventory/WG and Hysteria certificate/key
hashes match afterward. Auto mode is restored; owned fixtures/private temporary
bundles and backups are cleaned. The final four-transport deployment committed.

Local bundle tests also cover all 15 nonempty transport subsets and XHTTP-only
generation without unused WG keys. Total local suite: 118 tests PASS; generated
shell/Python and embedded-helper static checks PASS.

Private artifacts: `order-roundtrip-before-lab10`,
`order-roundtrip-lab11/xhttp`, `order-roundtrip-lab11/hy2`.
Reproduce using `lab/transport_roundtrip.py --keep TRANSPORT TRANSPORT`.

This does not prove every interruption point, concurrency case or clean install.
F04 remains partial/UNKNOWN and the project remains NOT_READY. The operator's
cleanup gate and unchanged six-hour soak are still outstanding.
