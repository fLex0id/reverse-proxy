#!/usr/bin/env python3
"""Regenerate the standalone VPS-1 migration helper embedded in rp.sh."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
p = root / 'rp.sh'
s = p.read_text()
start = '# BEGIN GENERATED MIGRATION HELPER\n'
end = '# END GENERATED MIGRATION HELPER\n'
block = (start + "migration_source() { cat <<'RP_MIGRATION_PY'\n" +
         (root / 'src/migration.py').read_text() + 'RP_MIGRATION_PY\n}\n' + end)
if start in s:
    a = s.index(start)
    b = s.index(end, a) + len(end)
    s = s[:a] + block + s[b:]
else:
    s = s.replace('self_version_of() {', block + '\nself_version_of() {', 1)
p.write_text(s)
