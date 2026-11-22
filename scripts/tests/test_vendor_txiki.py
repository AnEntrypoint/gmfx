import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECK = REPO_ROOT / "scripts" / "check_vendor_txiki.py"
SHARED_DIR = REPO_ROOT / "scripts" / "txiki"


class CheckVendorTxikiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.copy = pathlib.Path(self.temp.name) / "txiki"
        shutil.copytree(SHARED_DIR, self.copy)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def check(self, *roots: pathlib.Path) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(CHECK), *map(str, roots)], capture_output=True, text=True, timeout=60)

    def flip_last_byte(self, name: str) -> None:
        path = self.copy / name
        data = bytearray(path.read_bytes())
        data[-1] ^= 1
        path.write_bytes(bytes(data))

    def test_fx_copy_matches_the_shared_record(self) -> None:
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("match gm", result.stdout)

    def test_untouched_copy_passes(self) -> None:
        self.assertEqual(self.check(self.copy).returncode, 0)

    def test_changed_script_fails(self) -> None:
        self.flip_last_byte("vendor.mjs")
        result = self.check(self.copy)
        self.assertEqual(result.returncode, 1)
        self.assertIn("vendor.mjs: sha256", result.stderr)

    def test_changed_pin_file_fails(self) -> None:
        self.flip_last_byte("pins.json")
        result = self.check(self.copy)
        self.assertEqual(result.returncode, 1)
        self.assertIn("pins.json: sha256", result.stderr)

    def test_changed_patch_fails(self) -> None:
        self.flip_last_byte("patches/txiki-dns-flags.patch")
        result = self.check(self.copy)
        self.assertEqual(result.returncode, 1)
        self.assertIn("txiki-dns-flags.patch: sha256", result.stderr)

    def test_missing_pin_file_fails(self) -> None:
        os.remove(self.copy / "pins.json")
        result = self.check(self.copy)
        self.assertEqual(result.returncode, 1)
        self.assertIn("pins.json: missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
