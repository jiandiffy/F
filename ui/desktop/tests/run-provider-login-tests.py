#!/usr/bin/env python3
"""Run the real native login terminal against an isolated credential fixture."""
from pathlib import Path
import json
import os
import plistlib
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
source = (root/'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
source += '\n'+'\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root/folder).rglob('*.swift') if folder == 'Core' else (root/folder).glob('*/*.swift')))
with tempfile.TemporaryDirectory(prefix='f-provider-login-') as temporary:
    work = Path(temporary).resolve()
    agent = work/'runtime/agent'
    (agent/'bin').mkdir(parents=True)
    (agent/'scripts').mkdir()
    (work/'runtime/node/bin').mkdir(parents=True)
    (work/'runtime/node/bin/node').symlink_to(root.parents[1]/'runtime/node/bin/node')
    (agent/'bin/f').write_text('#!/bin/sh\nexit 0\n')
    (agent/'bin/f').chmod(0o755)
    (work/'data').mkdir()
    (agent/'scripts/provider-auth.mjs').write_text('''import fs from 'node:fs';
import path from 'node:path';
const [action, source] = process.argv.slice(2), file=path.join(process.env.F_USER_DATA_DIRECTORY,source+'.fixture');
if(action==='status'){console.log(JSON.stringify({authenticated:fs.existsSync(file)}));process.exit(0);}
process.stdin.setRawMode(true);process.stdin.resume();console.log('FIXTURE_READY');
process.stdin.on('data',()=>{fs.writeFileSync(file,'fixture');const receipt=process.env.F_LOGIN_RESULT_FILE;fs.mkdirSync(path.dirname(receipt),{recursive:true});fs.writeFileSync(receipt,JSON.stringify({authenticated:true}));process.exit(0);});
''')
    bundle = work/'LoginTests.app/Contents'
    (bundle/'MacOS').mkdir(parents=True)
    (bundle/'Resources').symlink_to(root/'Resources', target_is_directory=True)
    (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.f.login.'+uuid.uuid4().hex,
        'CFBundleExecutable': 'LoginTests', 'CFBundlePackageType': 'APPL', 'PiCLIPath': str(agent/'bin/f')}))
    swift = work/'main.swift'
    swift.write_text(source+'\n'+(root/'tests/provider-login-regression.swift').read_text())
    binary = bundle/'MacOS/LoginTests'
    subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=60, env=dict(os.environ,
        F_USER_DATA_DIRECTORY=str(work/'data'), PI_CODING_AGENT_DIR=str(work/'data/agent')))
