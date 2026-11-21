"""Run the generated watchdog with controlled services, preserving its decision logic."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
ROOT=Path(__file__).resolve().parents[1]

class WatchdogPolicy(unittest.TestCase):
    def starts(self,mode):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);state=d/'state';state.mkdir();(state/'active').write_text('reality-xhttp2\n')
            conf=d/'rp2.conf';conf.write_text('TRANSPORT_ORDER="reality-xhttp2 reality-xhttp"\nWATCH_MIN=10\nWATCH_MAX=15\n')
            source=d/'functions';source.write_text((ROOT/'rp.sh').read_text().rsplit('main "$@"',1)[0])
            subprocess.run(['bash','-c','source "$1"; vps2_files "$2"','bash',str(source),str(d/'generated')],check=True)
            bin_dir=d/'bin';bin_dir.mkdir()
            mock=bin_dir/'rp';mock.write_text('''#!/bin/bash
case "$2" in
 tr_order) if [[ $TEST_MODE == auto ]]; then echo 'reality-xhttp2 reality-xhttp'; else echo reality-xhttp2; fi ;;
 mode_get) echo "$TEST_MODE" ;;
 func_ok) [[ ${3:-} == reality-xhttp ]] ;;
 tr_start) echo "$3" >>"$TEST_STARTS" ;;
 t2_check|t3_check|tr_stop_all) exit 0 ;;
 *) exit 1 ;;
esac
''');mock.chmod(0o700)
            (bin_dir/'sleep').write_text('#!/bin/sh\n/bin/sleep 0.01\n');(bin_dir/'sleep').chmod(0o700)
            (bin_dir/'logger').write_text('#!/bin/sh\nexit 0\n');(bin_dir/'logger').chmod(0o700)
            watch=(d/'generated/usr/local/lib/rp/watch.sh').read_text()
            watch=watch.replace('ST=/var/lib/rp','ST='+str(state)).replace('/etc/rp/rp2.conf',str(conf)).replace('/usr/local/bin/rp',str(mock))
            script=d/'watch.sh';script.write_text(watch)
            starts=d/'starts';env=dict(os.environ,PATH=str(bin_dir)+':'+os.environ['PATH'],TEST_MODE=mode,TEST_STARTS=str(starts))
            proc=subprocess.Popen(['bash',str(script)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,start_new_session=True)
            try:
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    values=starts.read_text().splitlines() if starts.exists() else []
                    if len(values)>=2:return values
                    if proc.poll() is not None: self.fail(proc.stderr.read().decode())
                    time.sleep(.02)
                self.fail('watchdog did not attempt recovery')
            finally:
                if proc.poll() is None:os.killpg(proc.pid,signal.SIGTERM)
                proc.wait(timeout=5);proc.stderr.close()

    def test_auto_tries_reserve_before_failed_primary(self):
        self.assertEqual(self.starts('auto')[:2],['reality-xhttp2','reality-xhttp'])
    def test_manual_retries_only_pinned_transport(self):
        self.assertEqual(self.starts('manual:reality-xhttp2')[:2],['reality-xhttp2','reality-xhttp2'])

if __name__=='__main__':unittest.main()
