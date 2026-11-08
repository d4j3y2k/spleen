"""Counts-only wrapper around the bounded compiled catalog checker."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--folder", action="append", required=True, help="Exact absolute project folder (repeat up to ten times).")
args = parser.parse_args()
if not 1 <= len(args.folder) <= 10 or any(not Path(folder).is_absolute() or "\0" in folder for folder in args.folder):
    parser.error("Supply one to ten absolute project folders.")
binary = Path(__file__).resolve().parents[1] / "build/Spleen.app/Contents/MacOS/Spleen"
if not binary.is_file():
    parser.error("Build Spleen first with ./scripts/build.sh.")
command = [str(binary), "--catalog-check"]
for folder in args.folder:
    command.extend(["--catalog-folder", folder])
raise SystemExit(subprocess.run(command, check=False).returncode)
