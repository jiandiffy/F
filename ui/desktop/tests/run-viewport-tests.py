#!/usr/bin/env python3
"""Real WebKit per-conversation viewport persistence, using temporary front-end output."""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
source = (root/'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
source += '\n' + '\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root/folder).rglob('*.swift') if folder == 'Core' else (root/folder).glob('*/*.swift')))
with tempfile.TemporaryDirectory(prefix='f-viewport-') as temporary:
    work = Path(temporary).resolve()
    bundle = work/'ViewportTests.app/Contents'
    (bundle/'MacOS').mkdir(parents=True)
    resources = bundle/'Resources'
    resources.mkdir()
    for item in (root/'Resources').iterdir():
        if item.name != 'whiteboard':
            (resources/item.name).symlink_to(item, target_is_directory=item.is_dir())
    node = root.parents[1]/'runtime/node/bin/node'
    subprocess.run([str(node), str(root/'tests/whiteboard-bridge-regression.mjs')], check=True)
    subprocess.run([str(node), str(root.parents[1]/'packages/excalidraw/web/node_modules/vite/bin/vite.js'), 'build',
        '--configLoader', 'runner', '--outDir', str(resources/'whiteboard')], cwd=root.parents[1]/'packages/excalidraw/web', check=True)
    (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.f.viewport.'+uuid.uuid4().hex,
        'CFBundleExecutable': 'ViewportTests', 'CFBundlePackageType': 'APPL'}))
    swift = work/'main.swift'
    swift.write_text(source+'\n'+(root/'tests/viewport-regression.swift').read_text())
    binary = bundle/'MacOS/ViewportTests'
    subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=80, env=dict(os.environ, F_VIEWPORT_ROOT=str(work)))
