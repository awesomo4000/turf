#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Check page visibility and animation progress using Turf's Cocoa bridge.

Requires an unlocked macOS GUI session. Briefly changes focus, covers, and
minimizes test windows. Leave the desktop undisturbed during the test.
Prints JSONL with native state, page state, and timestamped page events.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="turf-visibility-", dir="/tmp") as directory:
        binary = Path(directory) / "visibility"
        subprocess.run([
            "clang", "-fobjc-arc", "-fblocks", "-Wno-incompatible-pointer-types",
            "-framework", "Cocoa", "-framework", "WebKit",
            "-framework", "CoreGraphics",
            str(ROOT / "tests/visibility_macos.m"),
            str(ROOT / "src/platforms/macos/automation.m"), "-o", str(binary),
        ], env={**os.environ, "TMPDIR": directory}, check=True)
        for args in (["--no-focus"], []):
            subprocess.run([str(binary), *args], check=True, timeout=60)


if __name__ == "__main__":
    main()
