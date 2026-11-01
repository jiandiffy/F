#!/usr/bin/env python3
"""Compile the actual app source with an isolated whiteboard regression entry point."""
from pathlib import Path
import subprocess
import tempfile
import plistlib
import os

root = Path(__file__).resolve().parents[1]
source = (root / "main.swift").read_text()
entry = "\nlet app = NSApplication.shared\n"
assert source.count(entry) == 1, "App entry point changed; update the test runner"
with tempfile.TemporaryDirectory(prefix="f-whiteboard-tests-") as directory:
    work = Path(directory)
    bundle = work / "WhiteboardTests.app/Contents"
    (bundle / "MacOS").mkdir(parents=True)
    (bundle / "Resources").symlink_to(root / "Resources", target_is_directory=True)
    agent = work / "agent"
    (agent / "sessions").mkdir(parents=True)
    (agent / "settings.json").write_text('{"defaultModel":"test-default","defaultThinkingLevel":"medium"}')
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.f.whiteboard-tests",
        "CFBundleExecutable": "WhiteboardTests", "CFBundlePackageType": "APPL",
        "PiAgentDir": str(agent),
    }))
    swift = work / "main.swift"
    swift.write_text(source.split(entry)[0] + "\n" + "\n".join(p.read_text() for folder in ["Core", "Plugins"] for p in sorted((root / folder).rglob("*.swift"))) + "\n" +
                     (root / "tests/project-export-regression.swift").read_text() + "\n" +
                     (root / "tests/whiteboard-regression.swift").read_text())
    binary = bundle / "MacOS/WhiteboardTests"
    subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=90, env=dict(os.environ, F_TEST_ROOT=str(work)))
