"""Verify real route_api_override logic rejects missing/mismatched API readback."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class RouteReadback(unittest.TestCase):
    def run_override(self, target, response):
        with tempfile.TemporaryDirectory() as d:
            Path(d, 'functions.sh').write_text((ROOT/'rp.sh').read_text().rsplit('main "$@"',1)[0])
            fake=Path(d,'xray')
            fake.write_text('#!/bin/bash\ncase "$2" in bo) exit 0;; bi) printf "%s\\n" "$API_RESPONSE";; *) exit 1;; esac\n')
            fake.chmod(0o700)
            env=dict(os.environ, TEST_DIR=d, API_RESPONSE=response, TARGET=target)
            return subprocess.run(['bash','-c','source "$TEST_DIR/functions.sh"; XRAY_BIN=$TEST_DIR/xray; route_api_override exit "$TARGET"'],env=env,capture_output=True).returncode

    def test_matching_override(self):
        self.assertEqual(self.run_override('r-xhttp2',json.dumps({'balancer':{'override':{'target':'r-xhttp2'}}})),0)
    def test_wrong_override(self):
        self.assertNotEqual(self.run_override('r-xhttp2',json.dumps({'balancer':{'override':{'target':'r-xhttp'}}})),0)
    def test_empty_response(self): self.assertNotEqual(self.run_override('r-xhttp2',''),0)
    def test_clear_verified(self): self.assertEqual(self.run_override('clear','{"balancer":{"override":{}}}'),0)
    def test_clear_wrong(self): self.assertNotEqual(self.run_override('clear','{"balancer":{"override":{"target":"r-xhttp"}}}'),0)
    def test_missing_balancer(self): self.assertNotEqual(self.run_override('clear','{}'),0)

if __name__=='__main__': unittest.main()
