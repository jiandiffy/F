#!/usr/bin/env python3
"""Test the native file panel against a disposable project; no real user files."""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
source += '\n' + '\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root / folder).rglob('*.swift') if folder == 'Core' else (root / folder).glob('*/*.swift')))
with tempfile.TemporaryDirectory(prefix='f-file-tests-') as temporary:
    work = Path(temporary).resolve()
    bundle = work / 'FileTests.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Resources').symlink_to(root / 'Resources', target_is_directory=True)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.f.file-tests', 'CFBundleExecutable': 'FileTests',
        'CFBundlePackageType': 'APPL',
    }))
    swift = work / 'main.swift'
    swift.write_text(source + '\n' + (root / 'tests/file-browser-regression.swift').read_text())
    binary = bundle / 'MacOS/FileTests'
    flags = ['-Onone', '-g'] if os.environ.get('F_FILE_TEST_DEBUG') else ['-O']
    subprocess.run(['swiftc', *flags, str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=90,
                   env=dict(os.environ, F_FILE_TEST_ROOT=str(work)))
