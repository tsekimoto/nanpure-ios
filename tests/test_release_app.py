import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-release-app.py"
SPEC = importlib.util.spec_from_file_location("check_release_app", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
PRODUCTION = b"ca-app-pub-7659346445516782/8870201118\0ca-app-pub-7659346445516782/4139518536"


class ReleaseAppChecks(unittest.TestCase):
    def check_binary(self, binary, app_id="ca-app-pub-7659346445516782~6278596713"):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / "Nanpure").write_bytes(binary)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Nanpure", "GADApplicationIdentifier": app_id,
            }))
            CHECK.check_release_app(app)

    def test_accepts_production_executable(self):
        self.check_binary(PRODUCTION)

    def test_rejects_demo_ads_and_diagnostics(self):
        for marker in (b"ca-app-pub-3940256099942544/2435281174",
                       b"ca-app-pub-3940256099942544/1712485313", b"Ad: build=",
                       b"NANPURE_DIAGNOSTICS", b"Banner ad failed to load:",
                       b"Rewarded ad failed to load:"):
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                self.check_binary(PRODUCTION + b"\0" + marker)

    def test_rejects_missing_production_units(self):
        with self.assertRaises(ValueError):
            self.check_binary(b"app without production ad configuration")

    def test_rejects_wrong_app_identifier(self):
        with self.assertRaises(ValueError):
            self.check_binary(PRODUCTION, "ca-app-pub-unexpected")


if __name__ == "__main__":
    unittest.main()
