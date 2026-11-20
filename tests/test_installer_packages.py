"""A repeated VPS-2 deployment must not depend on an unused package mirror."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'rp.sh').read_text()
HELPER = SOURCE.split('rp_pkg_install() {', 1)[1].split('\nrp_main() {', 1)[0]

class Packages(unittest.TestCase):
    def run_case(self, missing='', dnf_rc=0, installs=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'missing').write_text(missing)
            script = '''set -uo pipefail
rpm() {
  shift
  for p in "$@"; do
    if grep -Fxq "$p" "$TEST_DIR/missing"; then return 1; fi
  done
}
dnf() {
  printf '%s\\n' "$*" >>"$TEST_DIR/calls"
  [[ $TEST_DNF_RC == 0 ]] || return "$TEST_DNF_RC"
  [[ $TEST_INSTALLS == yes ]] && : >"$TEST_DIR/missing"
  return 0
}
rp_pkg_install() {''' + HELPER + '\nrp_pkg_install chrony nftables curl unzip tar\n'
            r = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                env=dict(os.environ, TEST_DIR=tmp, TEST_DNF_RC=str(dnf_rc), TEST_INSTALLS='yes' if installs else 'no'))
            calls = (root / 'calls').read_text().splitlines() if (root / 'calls').exists() else []
            return r.returncode, calls

    def test_installed_dependencies_work_with_unavailable_repository(self):
        self.assertEqual(self.run_case(dnf_rc=1), (0, []))

    def test_only_missing_packages_are_requested(self):
        self.assertEqual(self.run_case('nftables\nunzip\n'), (0, ['-y install nftables unzip']))

    def test_fresh_install_requires_all_packages(self):
        self.assertEqual(self.run_case('chrony\nnftables\ncurl\nunzip\ntar\n'),
                         (0, ['-y install chrony nftables curl unzip tar']))

    def test_repository_failure_is_not_ignored_for_missing_package(self):
        rc, calls = self.run_case('nftables\n', dnf_rc=1)
        self.assertNotEqual(rc, 0)
        self.assertEqual(calls, ['-y install nftables'])

    def test_success_exit_without_installed_dependency_is_rejected(self):
        self.assertNotEqual(self.run_case('nftables\n', installs=False)[0], 0)

if __name__ == '__main__':
    unittest.main()
