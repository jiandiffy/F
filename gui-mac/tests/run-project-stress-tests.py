#!/usr/bin/env python3
"""Bounded stress tests of real project UI + independent fake RPC children, never user data."""
from pathlib import Path
import json
import os
import plistlib
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
source = (root / 'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
source += '\n' + '\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root / folder).rglob('*.swift')))
with tempfile.TemporaryDirectory(prefix='f-project-stress-') as temporary:
    work = Path(temporary)
    agent = work / 'agent'
    (agent / 'sessions').mkdir(parents=True)
    (agent / 'settings.json').write_text(json.dumps({'defaultModel': 'test-model', 'defaultThinkingLevel': 'high'}))
    fake = work / 'fake-rpc.py'
    fake.write_text((root / 'tests/fake-queue-rpc.py').read_text())
    fake.chmod(0o755)
    bundle = work / 'ProjectStress.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Resources').symlink_to(root / 'Resources', target_is_directory=True)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.f.project-stress.' + uuid.uuid4().hex,
        'CFBundleExecutable': 'ProjectStress', 'CFBundlePackageType': 'APPL',
        'PiAgentDir': str(agent), 'PiCLIPath': str(fake),
    }))
    swift = work / 'main.swift'
    swift.write_text(source + '\n' + (root / 'tests/project-stress-regression.swift').read_text())
    binary = bundle / 'MacOS/ProjectStress'
    subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=120,
                   env=dict(os.environ, F_STRESS_ROOT=str(work), F_QUEUE_TEST_LOG=str(work / 'rpc.jsonl')))
