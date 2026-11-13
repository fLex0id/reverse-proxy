# Authorized laboratory tooling

These programs change the designated lab hosts. Do not run them on production.
Use SSH aliases/config supplied by the operator; never commit private keys or
client configurations. Store artifacts below `lab/artifacts` and secret inputs
below `lab/private` (both ignored, mode 0700).

- `setup-client.sh LAB1_IP CLIENT_CONFIG`: on the auxiliary Debian host, create an
  independent WireGuard client namespace with a veth underlay. It adds only its
  own NAT table, but enables host IPv4 forwarding; previous value is recorded.
- `transport_matrix.py --lab1 ALIAS --lab2 ALIAS --client ALIAS --output DIR`:
  select each transport, run built-in checks, generate actual client HTTPS/DNS,
  and capture packets on both external interfaces. A successful capture command
  alone is not a leak-test PASS. Review skipped T8/static T7 explicitly.
- `dns-probe.py RESOLVER NAME [--type NUMBER] [--tcp]`: standard-library DNS probe
  with no alternate/system resolver fallback.
- `failclosed.py --lab1 ALIAS --client ALIAS --output DIR`: stop only rp-xray after
  arming independent systemd restoration; verify blocked client requests and recovery.
- `transaction_e2e.py`: run on LAB-2 with `/root/rp-lab/transaction-current.py` from
  `src/transaction.py`. Exercises real backup, corruption rejection, rollback,
  preservation of unrelated SSH changes and confirm/rollback races. Requires an
  already healthy candidate and independent SSH. Never run concurrently with
  other mutation/fault suites.

A final six-hour soak has NOT started. The acceptance matrix remains NOT_READY.
Reboots and broad resource-exhaustion scenarios require the snapshot operator
available for recovery. Test artifacts may contain network metadata: keep private
and publish only sanitized evidence summaries.

## Development validation

Run `python3 tools/embed-transaction.py` after modifying `src/transaction.py`.
The deployed artifact remains a single `rp.sh`; src/ is not needed to install it.
Run `python3 tools/static-check.py` and `python3 -m unittest discover -s tests -v`.
Static checks require ShellCheck and pyflakes. CI also stores a formatting audit;
legacy formatting is not silently rewritten.
