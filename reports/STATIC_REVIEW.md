# ShellCheck info-level review

Snapshot: commit dcee312 (1.2.9-lab.2), ShellCheck 0.10.0.
Warning/error severity is enforced by tools/static-check.py; info diagnostics remain visible.
This review does not waive runtime acceptance. The backup-retention robustness item remains open.

| Diagnostic | Count | Disposition |
|---|---:|---|
| SC1091 | 3 | Trusted host /etc/os-release is read on the target host; static analysis does not source the controller copy. |
| SC2012 | 1 | Backup names are currently generated timestamp/PID paths. Parsing ls remains a robustness concern for operator-added names; replace with NUL-delimited retention before final acceptance. |
| SC2015 | 26 | Reviewed as a command-success chain: failure of either command invokes error handling, or the final || true intentionally ignores a best-effort action. It is not used to validate unverified push success. |
| SC2016 | 6 | Intentional delayed expansion in bash -c or an installer generated for another machine; double quotes would expand in the wrong shell. |
| SC2018 | 3 | ASCII case conversion of protocol headers or hexadecimal hashes; locale-aware Unicode mapping is unnecessary here. |
| SC2019 | 3 | ASCII case conversion of protocol headers or hexadecimal hashes; locale-aware Unicode mapping is unnecessary here. |
| SC2059 | 3 | Intentional printf wrapper: callers supply the format and separate value arguments; not a user-supplied format. |

Locations at the reviewed commit (generated line numbers refer to the emitted scripts):

- SC1091: rp.sh:320, rp.sh:320, rp.sh:3153
- SC2012: rp.sh:982
- SC2015: rp.sh:960, rp.sh:1197, rp.sh:3037, rp.sh:3525, rp.sh:3538, rp.sh:4022, rp.sh:4115, rp.sh:4151, rp.sh:4163, rp.sh:4164, rp.sh:4167, rp.sh:4175, rp.sh:4178, rp.sh:4180, rp.sh:4249, rp.sh:4301, rp.sh:4329, rp.sh:4331, rp.sh:4347, rp.sh:4367, rp.sh:4373, generated-vps2-rp:140, generated-vps2-rp:276, generated-vps2-rp:454, generated-vps2-rp:538, generated-vps2-rp:551
- SC2016: rp.sh:3349, rp.sh:3814, generated-vps2-rp:198, generated-vps2-rp:203, generated-vps2-rp:254, generated-vps2-rp:298
- SC2018: rp.sh:576, rp.sh:1218, rp.sh:1224
- SC2019: rp.sh:576, rp.sh:1218, rp.sh:1224
- SC2059: rp.sh:155, rp.sh:157, rp.sh:160

The generated watchdog has no info-level diagnostics. No blanket exclusions were added.
