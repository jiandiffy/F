#!/usr/bin/env python3
"""Exercise real PTYs and an isolated loopback OpenSSH server, never a configured remote host."""
from pathlib import Path
import getpass
import os
import plistlib
import socket
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='f-plugin-tests-') as directory:
    work = Path(directory)
    for name in ['host', 'client']:
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(work / name)], check=True)
    (work / 'authorized_keys').write_text((work / 'client.pub').read_text())
    (work / 'authorized_keys').chmod(0o600)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    (work / 'known_hosts').write_text(f'[127.0.0.1]:{port} ' + (work / 'host.pub').read_text())
    (work / 'sshd_config').write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {work}/host
PidFile {work}/sshd.pid
AuthorizedKeysFile {work}/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
LogLevel ERROR
''')
    (work / 'config').write_text(f'''Host f-loopback
 HostName 127.0.0.1
 User {getpass.getuser()}
 Port {port}
 IdentityFile {work}/client
 IdentitiesOnly yes
 UserKnownHostsFile {work}/known_hosts
 StrictHostKeyChecking yes
''')
    fixture = work / "remote folder ' 中文"
    fixture.mkdir()
    (fixture / "text ' 中文.txt").write_text('first line\n中文\n')
    (fixture / 'nested').mkdir()
    (fixture / 'completion-target.txt').write_text('COMPLETE_READY\n')
    (work / 'completion-target.txt').write_text('COMPLETE_READY\n')
    (fixture / 'new\nline.txt').write_text('line-name')
    (fixture / 'zero.bin').write_bytes(b'\x00\xff')
    (fixture / 'big.txt').write_bytes(b'a' * 2_000_001)
    (fixture / "text ' 中文.txt").chmod(0o640)
    (fixture / 'link.txt').symlink_to(fixture / "text ' 中文.txt")
    bundle = work / 'PluginTests.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Resources').symlink_to(root / 'Resources', target_is_directory=True)
    agent = work / 'agent'
    (agent / 'sessions').mkdir(parents=True)
    (agent / 'settings.json').write_text('{"defaultModel":"test-default","defaultThinkingLevel":"medium"}')
    # 只回答 get_state 的假 RPC：拖入文件夹的用例不需要真实模型。
    fake = work / 'fake-rpc.py'
    fake.write_text('''#!/usr/bin/python3
import json
import sys

for line in sys.stdin:
    try:
        command = json.loads(line)
    except ValueError:
        continue
    print(json.dumps({'type': 'response', 'id': command.get('id'), 'success': True, 'data': {}}), flush=True)
''')
    fake.chmod(0o755)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.f.plugin-tests.' + uuid.uuid4().hex, 'PiAgentDir': str(agent), 'PiCLIPath': str(fake), 'CFBundleExecutable': 'PluginTests', 'CFBundlePackageType': 'APPL',
    }))
    source = (root / 'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
    source += '\n' + '\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root / folder).rglob('*.swift')))
    source += '\n' + (root / 'tests/plugin-regression.swift').read_text()
    swift = work / 'main.swift'
    swift.write_text(source)
    binary = bundle / 'MacOS/PluginTests'
    subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
    with (work / 'sshd.log').open('w') as log:
        server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(work / 'sshd_config')], stdout=log, stderr=log)
        try:
            time.sleep(.2)
            assert server.poll() is None, (work / 'sshd.log').read_text()
            subprocess.run([str(binary)], check=True, timeout=110, env=dict(os.environ, F_PLUGIN_TEST_ROOT=str(work), F_PLUGIN_TEST_FIXTURE=str(fixture), F_TEST_NODE=str(root.parent / 'pi/runtime/node/bin/node'), F_REMOTE_TEST_SCRIPT=str(root / 'tests/remote-agent-regression.mjs'), F_REMOTE_EXTENSION=str(root.parent / 'pi/agent/modules/fy-remote.ts'), F_WHITEBOARD_EXTENSION=str(root.parent / 'pi/agent/modules/fy-whiteboard.ts')))
        finally:
            if server.poll() is None:
                server.terminate()
                server.wait(timeout=5)
