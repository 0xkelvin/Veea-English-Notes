"""Run release build argument tests using a stub Flutter executable."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("build_ios_release.sh")
PRODUCT = "com.nintran.veeaEnglishApp.pro"


class BuildIOSReleaseTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        flutter = Path(temp.name) / "flutter"
        flutter.write_text("#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
        flutter.chmod(0o755)
        self.env = {"PATH": f"{temp.name}:{os.environ['PATH']}", "VEEA_APPLE_PRO_PRODUCT_ID": PRODUCT}

    def run_build(self, url, *args, product=PRODUCT):
        env = {**self.env, "VEEA_API_BASE_URL": url, "VEEA_APPLE_PRO_PRODUCT_ID": product}
        return subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True)

    def test_normalizes_origin_and_passes_safe_arguments(self):
        result = self.run_build("HTTPS://API.Example.Test:443///", "--build-number", "42",
                                "--build-name=1.2.3", "--export-options-plist", "Release Options.plist", "--no-pub")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            "build", "ipa", "--release", "--dart-define=VEEA_API_BASE_URL=https://api.example.test",
            f"--dart-define=VEEA_APPLE_PRO_PRODUCT_ID={PRODUCT}", "--build-number=42",
            "--build-name=1.2.3", "--export-options-plist=Release Options.plist", "--no-pub",
        ])

    def test_default_build_and_nondefault_port(self):
        result = self.run_build("https://api.example.test:8443/")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--dart-define=VEEA_API_BASE_URL=https://api.example.test:8443", json.loads(result.stdout))

    def test_rejects_invalid_or_missing_inputs(self):
        for url in ("", "http://api.example.test", "https://api.example.test/path",
                    "https://user@example.test", "https://api.example.test:99999",
                    "https://api.example.test?", "https://-api.example.test",
                    "https://api.example.test/#fragment", "https://api.example.test:",
                    "https://[::1].example.test", "https://999.0.0.1"):
            with self.subTest(url=url):
                result = self.run_build(url)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(result.stdout)
        for product in ("", "another-product"):
            self.assertEqual(self.run_build("https://api.example.test", product=product).returncode, 2)

    def test_conflicting_flags_cannot_reach_flutter(self):
        for args in (("--dart-define=VEEA_API_BASE_URL=https://other.example.test",),
                     ("--dart-define", f"VEEA_APPLE_PRO_PRODUCT_ID={PRODUCT}"),
                     ("--dart-define-from-file=build.json",), ("--target=alternate.dart",),
                     ("--build-number", "--dart-define=OTHER=value"), ("--build-number",)):
            with self.subTest(args=args):
                result = self.run_build("https://api.example.test", *args)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(result.stdout)

    def test_rejects_localhost_and_ip_literals(self):
        for host in ("localhost", "localhost.localdomain", "api.localhost", "LOCALHOST",
                     "127.0.0.1", "127.1", "127.0.0.2", "2130706433", "017700000001",
                     "0x7f000001", "0x7f.0.0.1", "[::1]", "[::ffff:127.0.0.1]",
                     "192.0.2.25", "[2001:db8::25]", "[v1.example.test]", "api[v1.example.test]"):
            with self.subTest(host=host):
                result = self.run_build(f"https://{host}:443/")
                self.assertEqual(result.returncode, 2)
                self.assertFalse(result.stdout)

    def test_build_number_preserves_valid_ios_components(self):
        for number in ("1", "9999", "42.7", "1.0.2", "9999.99.99", "001.02.03"):
            with self.subTest(number=number):
                result = self.run_build("https://api.example.test", f"--build-number={number}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"--build-number={number}", json.loads(result.stdout))

    def test_build_number_rejects_invalid_ios_components(self):
        for number in ("0", "0000.1", "-1", "+1", "1..2", ".1", "1.", "3.1.2b4",
                       "1.2.3.4", "10000", "1.100", "1.1.100", " 2", "２"):
            for arguments in (("--build-number", number), (f"--build-number={number}",)):
                with self.subTest(arguments=arguments):
                    result = self.run_build("https://api.example.test", *arguments)
                    self.assertEqual(result.returncode, 2)
                    self.assertFalse(result.stdout)


if __name__ == "__main__":
    unittest.main()
