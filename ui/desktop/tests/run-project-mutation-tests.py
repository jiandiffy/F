#!/usr/bin/env python3
"""Compile an isolated AppKit regression executable; never build/install F.app."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import select
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
def probe_real_pi_eof():
    """Use F.app's configured distribution directly, bypassing its agent-dir-forcing shell wrapper.

    Only get_state is sent. No prompt/model/tool call, credentials, project extensions or user
    sessions are used. Keep a small diagnostic directory; never kill a timed-out real runtime.
    """
    work = Path(tempfile.mkdtemp(prefix='f-real-pi-eof-')).resolve()
    project, agent = work / 'project', work / 'agent'
    project.mkdir()
    (agent / 'sessions').mkdir(parents=True)
    (work / 'home').mkdir()
    app = Path(os.environ.get('F_TEST_APP', root/'F.app'))
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    cli_path = app/'Contents/Resources/runtime/agent/bin/f' if info.get('FDistribution') == 'dmg' else Path(info['PiCLIPath'])
    distribution = cli_path.resolve().parent.parent
    node = distribution.parent / 'node/bin/node'
    cli = distribution / 'node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js'
    package = json.loads((distribution / 'node_modules/@earendil-works/pi-coding-agent/package.json').read_text())
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith(('PI_', 'F_')) or key.endswith(('_API_KEY', '_TOKEN')):
            environment.pop(key)
    environment.update(HOME=str(work / 'home'), CFFIXED_USER_HOME=str(work / 'home'), PI_CODING_AGENT_DIR=str(agent))
    record = {'runtime': str(cli), 'node': str(node), 'version': package['version'],
              'cliSHA256': hashlib.sha256(cli.read_bytes()).hexdigest(),
              'project': str(project), 'agent': str(agent), 'commands': ['get_state'],
              'modelRequests': 0, 'toolRequests': 0, 'launcherBypassedForAgentIsolation': True}
    started = time.monotonic()
    with (work / 'stderr.log').open('wb') as errors:
        process = subprocess.Popen([str(node), str(cli), '--mode', 'rpc', '--session', str(work / 'session.jsonl')],
                                   cwd=project, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=errors)
        record['pid'] = process.pid
        try:
            process.stdin.write(b'{"id":"real-eof-probe","type":"get_state"}\n')
            process.stdin.flush()
            response = None
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                line = process.stdout.readline()
                if not line:
                    break
                try:
                    value = json.loads(line)
                except ValueError:
                    continue
                if value.get('id') == 'real-eof-probe':
                    response = value
                    break
            record['getStateSuccess'] = bool(response and response.get('success'))
            if response:
                model = response.get('data', {}).get('model') or {}
                record['configuredModel'] = {key: model.get(key) for key in ('provider', 'id')}
            process.stdin.close()
            eof = time.monotonic()
            try:
                record['exitCode'] = process.wait(timeout=8)
                record['eofSeconds'] = round(time.monotonic() - eof, 3)
                record['outcome'] = 'natural-exit' if record['exitCode'] == 0 else 'abnormal-exit'
            except subprocess.TimeoutExpired:
                record['outcome'] = 'timeout-preserved'
                record['stillRunning'] = process.poll() is None
                record['eofSeconds'] = 8
            record['totalSeconds'] = round(time.monotonic() - started, 3)
        except Exception as error:
            record['outcome'] = 'probe-error'
            record['error'] = str(error)
            try:
                process.stdin.close()
            except (OSError, ValueError):
                pass
            # Preserve a live process instead of terminating it to make a test pass.
            record['stillRunning'] = process.poll() is None
        finally:
            (work / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
    print('REAL_PI_EOF ' + json.dumps(record, ensure_ascii=False), flush=True)
    print('REAL_PI_EOF_LOG ' + str(work / 'result.json'), flush=True)
    if not record.get('getStateSuccess') or record.get('outcome') != 'natural-exit':
        raise RuntimeError('Real Pi EOF did not confirm safe natural exit; diagnostics/process preserved at ' + str(work))


source = (root / 'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
source += '\n' + '\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root / folder).rglob('*.swift') if folder == 'Core' else (root / folder).glob('*/*.swift')))
with tempfile.TemporaryDirectory(prefix='f-project-mutation-') as temporary:
    work = Path(temporary).resolve()
    agent = work / 'agent'
    (agent / 'sessions').mkdir(parents=True)
    home = work / 'home'
    (home / 'Library/Preferences').mkdir(parents=True)
    fake = work / 'short-lived-rpc.py'
    fake.write_text('''#!/usr/bin/python3
import json, pathlib, signal, sys, time
folder = pathlib.Path.cwd()
marker = folder / '.mutation-rpc.json'
if not marker.exists():
    for line in sys.stdin:
        time.sleep(0.3)
        sys.exit(0)
    sys.exit(0)
config = json.loads(marker.read_text())
logfile = folder / 'rpc-events.jsonl'
def log(value):
    with logfile.open('a') as stream:
        stream.write(json.dumps(value) + '\\n')
def signal_received(number, frame):
    log({'event': 'signal', 'signal': number})
    sys.exit(70)
signal.signal(signal.SIGTERM, signal_received)
signal.signal(signal.SIGHUP, signal_received)
session = config['session']
log({'event': 'started'})
for line in sys.stdin:
    request = json.loads(line)
    log(request)
    kind = request.get('type')
    data = {}
    if kind == 'get_state':
        data = {'sessionFile': session, 'model': {'provider': 'test', 'id': 'model', 'name': 'name'}, 'thinkingLevel': 'high'}
    elif kind == 'switch_session':
        session = request['sessionPath']
    elif kind == 'get_available_models':
        data = {'models': [{'provider': 'test', 'id': 'model', 'name': 'name'}]}
    elif kind == 'get_available_thinking_levels':
        data = {'levels': ['high']}
    print(json.dumps({'type': 'response', 'id': request.get('id'), 'command': kind, 'success': True, 'data': data}), flush=True)
log({'event': 'stdin-end'})
time.sleep(config.get('exitDelay', 0))
log({'event': 'natural-exit'})
''')
    fake.chmod(0o755)
    bundle = work / 'ProjectMutationTests.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Resources').symlink_to(root / 'Resources', target_is_directory=True)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.f.projectmutation.' + uuid.uuid4().hex,
        'CFBundleExecutable': 'ProjectMutationTests', 'CFBundlePackageType': 'APPL',
        'PiAgentDir': str(agent), 'PiCLIPath': str(fake),
    }))
    swift = work / 'main.swift'
    swift.write_text(source + '\n' + (root / 'tests/project-mutation-regression.swift').read_text())
    binary = bundle / 'MacOS/ProjectMutationTests'
    subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
    try:
        subprocess.run([str(binary)], check=True, timeout=120,
                       env=dict(os.environ, F_PROJECT_MUTATION_ROOT=str(work), HOME=str(home), CFFIXED_USER_HOME=str(home)))
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        for journal in work.rglob('journal.json'):
            print(str(journal) + ': ' + journal.read_text(), flush=True)
        raise

probe_real_pi_eof()
