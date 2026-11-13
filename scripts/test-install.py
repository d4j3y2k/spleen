"""Real signed fixture apps; no user apps, data, permissions or networking touched."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().with_name("install-app.sh")
APP = "Spleen"
BUNDLE_ID = "com.davidkim.spleen"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="spleen-install-tests-")
        self.root = pathlib.Path(self.tmp.name)
        self.destination = self.root / "Applications With Spaces"
        self.destination.mkdir()
        self.source = self.make_app(self.root / "download", 10)
        self.installed = self.destination / f"{APP}.app"

    def tearDown(self):
        self.tmp.cleanup()

    def make_app(self, parent, build, identity=BUNDLE_ID):
        app = parent / f"{APP}.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        info = {"CFBundleIdentifier": identity, "CFBundleExecutable": APP,
                "CFBundleName": APP, "CFBundlePackageType": "APPL",
                "CFBundleVersion": str(build), "LSMinimumSystemVersion": "13.0"}
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-x", "c", "-",
                        "-o", str(app / f"Contents/MacOS/{APP}")],
                       input=b"#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n", check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                       check=True, capture_output=True)
        return app

    def install(self, *arguments, script=SCRIPT):
        env = dict(os.environ)
        env.pop("SPLEEN_INSTALL_DIR", None)
        return subprocess.run(["/bin/zsh", str(script), "--app", str(self.source),
                               "--destination", str(self.destination), *arguments],
                              text=True, capture_output=True, env=env)

    def assert_build(self, build):
        with (self.installed / "Contents/Info.plist").open("rb") as file:
            self.assertEqual(plistlib.load(file)["CFBundleVersion"], str(build))

    def assert_rejected(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_fresh_install_and_quarantine_preserved(self):
        marker = "0081;00000000;InstallerTest;"
        subprocess.run(["/usr/bin/xattr", "-w", "com.apple.quarantine", marker, str(self.source)], check=True)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_build(10)
        value = subprocess.check_output(["/usr/bin/xattr", "-p", "com.apple.quarantine", str(self.installed)], text=True)
        # macOS may normalize the origin/flags when copying; quarantine must remain.
        self.assertEqual(int(value.split(";")[0], 16) & 0x0081, 0x0081)
        self.assertTrue(self.source.is_dir())
        self.assertEqual(sorted(p.name for p in self.destination.iterdir()), [f"{APP}.app"])

    def test_update_keeps_unrelated_data(self):
        self.make_app(self.destination, 9)
        marker = self.destination / "keep.txt"
        marker.write_text("user data")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_build(10)
        self.assertEqual(marker.read_text(), "user data")

    def test_downgrade_requires_explicit_flag(self):
        self.make_app(self.destination, 11)
        self.assert_rejected(self.install(), "newer build")
        self.assert_build(11)
        result = self.install("--allow-downgrade")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_build(10)

    def test_wrong_destination_identity_and_symlink(self):
        self.make_app(self.destination, 9, "org.example.someone-else")
        self.assert_rejected(self.install(), "another application")
        shutil.rmtree(self.installed)
        self.installed.symlink_to(self.source, target_is_directory=True)
        self.assert_rejected(self.install(), "symlink")
        self.assertTrue(self.source.is_dir())

    def test_modified_app_is_rejected_before_replacement(self):
        self.make_app(self.destination, 9)
        with (self.source / f"Contents/MacOS/{APP}").open("ab") as file:
            file.write(b"tampered")
        self.assert_rejected(self.install(), "signature is invalid")
        self.assert_build(9)

    def test_running_destination_is_not_replaced(self):
        self.make_app(self.destination, 9)
        process = subprocess.Popen([str(self.installed / f"Contents/MacOS/{APP}")])
        try:
            time.sleep(0.1)
            self.assert_rejected(self.install(), "before updating")
            self.assert_build(9)
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_failed_final_move_restores_previous_app(self):
        self.make_app(self.destination, 9)
        # Inject one failed filesystem operation in a private copy of the helper.
        content = SCRIPT.read_text()
        operation = '/bin/mv "$STAGE/$APP_NAME.app" "$INSTALL_APP"'
        self.assertEqual(content.count(operation), 1)
        failing = self.root / "install-failing.sh"
        failing.write_text(content.replace(operation, "false # injected move failure"))
        self.assertNotEqual(self.install(script=failing).returncode, 0)
        self.assert_build(9)
        self.assertEqual(sorted(p.name for p in self.destination.iterdir()), [f"{APP}.app"])

    def test_existing_lock_does_not_change_destination(self):
        self.make_app(self.destination, 9)
        (self.destination / ".spleen-install.lock").mkdir()
        self.assert_rejected(self.install(), "in progress")
        self.assert_build(9)


if __name__ == "__main__":
    unittest.main(verbosity=2)
