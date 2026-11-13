"""Drive actual menu branches with fixture input and check real flock ownership."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
CASES={'menu_clients':[1,3], 'menu_ru':[1,2,3,4,5], 'menu_dns':[1,2,3,4,5],
       'menu_upd':[1,2,3,4], 'menu_tunnel':[1,2,3,6,9,10], 'menu_main':[5,6,11,12,13,14]}

class MenuLocks(unittest.TestCase):
    def check_case(self,menu,choice):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); lock=root/'rp.lock'
            source=(ROOT/'rp.sh').read_text().rsplit('main "$@"',1)[0]
            (root/'functions').write_text(source.replace('/run/rp.lock',str(lock)))
            script=r'''
source "$TEST_DIR/functions"
STATE=$TEST_DIR
conf_load() { :; }; cf() { [[ $1 != CONF_VER ]] || echo 2; }
for name in cls banner mhead mi kv cl_list client_names cmd_status dot_state pause; do
  eval "$name() { :; }"
done
ask() { printf -v "$1" '%s' 'example.com'; }
count=0
mpick() { count=$((count+1)); if ((count==1)); then printf -v "$1" '%s' "$TEST_CHOICE"; else printf -v "$1" '%s' 0; fi; }
check_lock() {
  if flock -n "$TEST_LOCK" true; then echo UNLOCKED >>"$TEST_DIR/actions";
  else echo LOCKED >>"$TEST_DIR/actions"; fi
}
for name in cl_add cl_del cmd_link cmd_block cmd_push cmd_rotate cmd_prune cmd_tunnel cmd_test cmd_diag cmd_restart cmd_uninstall self_install self_upgrade cmd_migrate; do
  eval "$name() { check_lock; }"
done
cmd_door() { :; }
cmd_ru() { [[ ${1:-} == status ]] || check_lock; }
cmd_dns() { [[ ${1:-} == show ]] || check_lock; }
cmd_upgrade() { [[ ${1:-} == check ]] || check_lock; }
"$TEST_MENU"
'''
            r=subprocess.run(['bash','-c',script],capture_output=True,text=True,timeout=10,
                env=dict(os.environ,TEST_DIR=tmp,TEST_LOCK=str(lock),TEST_MENU=menu,TEST_CHOICE=str(choice)))
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertEqual((root/'actions').read_text().splitlines(),['LOCKED'])

for menu,choices in CASES.items():
    for choice in choices:
        def test(self,menu=menu,choice=choice): self.check_case(menu,choice)
        setattr(MenuLocks,'test_%s_%02d'%(menu,choice),test)

if __name__=='__main__':unittest.main()
