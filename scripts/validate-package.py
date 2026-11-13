"""Fail a package build on unexpected app files or leaked local build paths."""
import os
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1]).resolve()
expected = {
    "Contents/Info.plist",
    "Contents/MacOS/Spleen",
    "Contents/_CodeSignature/CodeResources",
    "Contents/CodeResources",  # Apple's stapled notarization ticket, when present.
    "Contents/Resources/Spleen.icns",
}
for path in app.rglob("*"):
    relative = path.relative_to(app).as_posix()
    if path.is_symlink() or (path.is_file() and relative not in expected):
        raise SystemExit(f"Unexpected package file: {relative}")
with (app / "Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if info["CFBundleIdentifier"] != "com.davidkim.spleen" or info["CFBundleExecutable"] != "Spleen":
    raise SystemExit("Unexpected application identity")
binary = (app / "Contents/MacOS/Spleen").read_bytes()
private_paths = [str(pathlib.Path.home()), str(pathlib.Path(__file__).resolve().parent.parent)]
if os.environ.get("SPLEEN_BUILD_ROOT"):
    private_paths.append(str(pathlib.Path(os.environ["SPLEEN_BUILD_ROOT"]).resolve()))
if any(path.encode() in binary for path in private_paths if len(path) > 1):
    raise SystemExit("Executable retains a local home, source, or build path; refusing to package")
if b"/Users/" in binary or b"/home/runner/" in binary:
    raise SystemExit("Executable retains a user-specific absolute path; refusing to package")
print("App file allowlist and local-path checks passed.")
