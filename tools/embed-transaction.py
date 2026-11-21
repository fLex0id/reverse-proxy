#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=root/'rp.sh';s=p.read_text()
start='# BEGIN GENERATED TRANSACTION HELPER\n'
end='# END GENERATED TRANSACTION HELPER\n'
block=start+"transaction_source() { cat <<'RP_TRANSACTION_PY'\n"+(root/'src/transaction.py').read_text()+"RP_TRANSACTION_PY\n}\n"+end
if start in s:
    a=s.index(start);b=s.index(end,a)+len(end);s=s[:a]+block+s[b:]
else:
    marker='vps2_files() {';s=s.replace(marker,block+'\n'+marker,1)
p.write_text(s)
