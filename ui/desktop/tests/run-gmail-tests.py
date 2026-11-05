#!/usr/bin/env python3
"""Compile and exercise Gmail UI contracts with isolated preferences and no real mail."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='f-gmail-native-') as directory:
    work = Path(directory)
    source = (root/'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
    source += '\n' + '\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root/folder).rglob('*.swift') if folder == 'Core' else (root/folder).glob('*/*.swift')))
    source += '\n' + (root/'tests/gmail-regression.swift').read_text()
    file = work/'main.swift'
    file.write_text(source)
    binary = work/'GmailTests'
    subprocess.run(['swiftc', '-O', str(file), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30, env=dict(os.environ, F_GMAIL_TEST_ROOT=str(work)))
