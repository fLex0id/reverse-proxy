"""Use an exact build of the standalone fallback for existing CLI fixtures."""
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
BUILD = TemporaryDirectory(prefix='rp-tests-')
SINGLE = Path(BUILD.name) / 'rp-single.sh'
subprocess.run([str(ROOT / 'tools/build.sh'), '--output', BUILD.name], check=True)
