#!/usr/bin/env python3
"""Stage, validate and request an update only after all owned work has finished."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import time
import uuid

source = Path(__file__).resolve().parents[3]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_module('f_update_helper', source/'ui/desktop/Resources/update-helper.py')
coordination = load_module('f_maintenance_lock', source/'runtime/harness/src/skills/maintenance_lock.py')


def source_digest():
    digest = hashlib.sha256()
    roots = ['runtime/harness/src', 'runtime/harness/upstream', 'runtime/harness/scripts', 'runtime/harness/tests', 'skills', 'packages', 'workflows', 'mcp', 'profiles', 'auth',
             'ui/desktop/Core', 'ui/desktop/Plugins', 'ui/desktop/scripts', 'ui/desktop/tests',
             'runtime/pi/agent/extensions', 'runtime/pi/agent/modules', 'runtime/pi/scripts', 'runtime/pi/vendor/pi-codebuddy-sdk-cbi/src',
             'runtime/pi/vendor/pi-codebuddy-sdk-cbc/src', 'packages/excalidraw/web/src', 'packages/excalidraw/web/public']
    files = [source/name for name in ['AGENTS.md', 'F_MAINTENANCE.md', 'ui/desktop/main.swift', 'ui/desktop/build.sh',
             'ui/desktop/Info.plist', 'ui/desktop/PLUGIN_SPEC.md', 'ui/desktop/ARCHITECTURE.md', 'runtime/harness/README.md', 'runtime/pi/package.json', 'packages/excalidraw/web/package.json',
             'packages/excalidraw/web/package-lock.json', 'runtime/harness/package.json', 'runtime/harness/package-lock.json', 'runtime/pi/package-lock.json']]
    files += [p for name in roots for p in (source/name).rglob('*') if p.is_file() and
              'node_modules' not in p.parts and '__pycache__' not in p.parts and
              not any(part in p.parts for part in ('dist', '.f')) and p.suffix not in ('.tmp',)]
    # Build-generated packages/excalidraw/web/terminal Resources and runtime/harness/dist are outputs, not inputs.
    # Terminal source is covered by ui/desktop/Plugins/Terminal/Web and dependency lockfiles.
    files += [p for p in (source/'ui/desktop/Resources').rglob('*') if p.is_file() and
              p.relative_to(source/'ui/desktop/Resources').parts[0] not in ('whiteboard', 'terminal') and
              '__pycache__' not in p.parts]
    files += [p for p in (source/'packages/excalidraw/web').glob('*') if p.is_file()]
    files += [p for name in ['runtime/checkpoints', 'runtime/recovery', 'runtime/concurrency', 'runtime/office', 'ui/extensions'] for p in (source/name).rglob('*') if p.is_file() and '.venv' not in p.parts and '__pycache__' not in p.parts]
    for file in sorted(set(files)):
        digest.update(str(file.relative_to(source)).encode() + b'\0' + file.read_bytes())
    return digest.hexdigest()


def require_source_digest(expected):
    if source_digest() != expected:
        raise RuntimeError('验证期间源码变化，未发布更新。请重新构建验证。')


def prepare(args, root):
    """Caller holds the process-wide publication lock and the source lease freeze."""
    target = Path(os.environ.get('F_APP_BUNDLE', source/'ui/desktop/F.app')).resolve()
    update_id = str(uuid.uuid4())
    artifact = root/update_id/'F.app'
    artifact.parent.mkdir(mode=0o700)
    validation = artifact.parent/'validation'
    validation.mkdir(mode=0o700)
    report_path = validation/'validation.json'
    report = {'version': 1, 'id': update_id, 'sourceDigest': source_digest(), 'suites': [], 'passed': False}

    def save_report():
        helper.atomic_json(report_path, report)

    def run(name, command, env=None):
        print('验证：' + name, flush=True)
        started = time.monotonic()
        log = validation/(name + '.log')
        with log.open('w') as output:
            completed = subprocess.run(command, cwd=source, env=env, stdout=output, stderr=subprocess.STDOUT)
        report['suites'].append({'name': name, 'passed': completed.returncode == 0,
                                'seconds': round(time.monotonic()-started, 2), 'log': str(log),
                                'exitCode': completed.returncode})
        save_report()
        if completed.returncode:
            print(log.read_text()[-10000:], flush=True)
            raise RuntimeError('验证失败，未发布更新：' + str(log))
        require_source_digest(report['sourceDigest'])

    save_report()
    command = ['bash', str(source/'ui/desktop/build.sh'), '--app='+str(artifact)]
    if args.no_whiteboard:
        command.append('--no-whiteboard')
    run('isolated-build', command)
    node = str(source/'runtime/pi/runtime/node/bin/node')
    # A maintenance Agent inherits its real board/lease paths. Tests must never use that ledger.
    harness_env = dict(os.environ, F_BOARD_DIR=str(validation/'harness-board'),
                       F_CONVERSATION_DIR=str(validation/'harness-conversation'),
                       F_DATA_DIRECTORY=str(validation/'workspaces'), F_TASK_DIRECTORY=str(validation/'tasks'))
    harness_env.pop('F_AGENT_ID', None)
    run('harness', [node, '--test', *[str(p) for p in sorted((source/'runtime/harness/tests').glob('*.test.mjs'))]], env=harness_env)
    run('layout', [node, str(source/'runtime/harness/scripts/verify-layout.mjs')])
    run('office', [str(source/'runtime/office/.venv/bin/python'), str(source/'runtime/office/tests.py')])
    run('provider-tool-bridge', [node, '--test', str(source/'runtime/pi/scripts/test-codebuddy-tool-replay.mjs')])
    run('computer-use', ['/usr/bin/python3', str(source/'ui/desktop/tests/run-computer-use-tests.py'), '--app', str(artifact)])
    for suite in ['run-whiteboard-tests.py', 'run-queue-tests.py', 'run-plugin-tests.py', 'run-file-browser-tests.py', 'run-history-navigation-tests.py', 'run-viewport-tests.py', 'run-versions-tests.py', 'run-project-mutation-tests.py', 'run-update-tests.py', 'run-project-stress-tests.py', 'run-daily-paper-tests.py', 'run-paper-media-tests.py', 'run-gmail-tests.py', 'run-browser-tests.py']:
        run(suite.removesuffix('.py'), ['/usr/bin/python3', str(source/'ui/desktop/tests'/suite)])
    # Test the exact frozen Harness carried by the signed candidate, with real model calls.
    run('cbi-deepseek-flash', [node, str(source/'runtime/harness/tests/test-cbi.mjs'), '--report', str(validation/'cbi.json'), '--native-report', str(report_path)],
        env=dict(os.environ, F_HARNESS_DIR=str(artifact/'Contents/Resources/runtime/harness')))
    run('self-check', [str(artifact/'Contents/MacOS/F'), '--self-check'])
    run('signature', ['/usr/bin/codesign', '--verify', '--strict', str(artifact)])
    require_source_digest(report['sourceDigest'])
    report['artifactSHA256'] = helper.digest_tree(artifact)
    save_report()
    # Do not delete .build, __pycache__, dist or other sessions' compiler outputs.
    info = plistlib.loads((target/'Contents/Info.plist').read_bytes())
    manifest = {'version': 1, 'id': update_id, 'artifact': str(artifact), 'target': str(target), 'announcement': args.announcement,
                'sha256': report['artifactSHA256'], 'previous_sha256': helper.digest_file(target/'Contents/MacOS'/info['CFBundleExecutable']),
                'originProject': os.environ.get('F_LOCAL_PROJECT', os.environ.get('F_PROJECT')),
                'originSession': os.environ.get('PI_SESSION_FILE')}
    path = root/'pending.json'
    candidate = root/('.pending-' + update_id + '.json')
    try:
        helper.atomic_json(candidate, manifest)
        helper.load_manifest(candidate)
        # Manifest validation may take time. Check again at the final no-clobber commit.
        require_source_digest(report['sourceDigest'])
        report['passed'] = True
        save_report()
        require_source_digest(report['sourceDigest'])
        coordination.publish_pending(candidate, path)
    except BaseException:
        report['passed'] = False
        save_report()
        raise
    finally:
        candidate.unlink(missing_ok=True)
    print('验证通过，已提交延迟更新。报告：' + str(report_path), flush=True)
    print(args.announcement, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--announcement', required=True)
    parser.add_argument('--no-whiteboard', action='store_true')
    args = parser.parse_args()
    if os.environ.get('F_UPDATE_DELEGATED') or int(os.environ.get('F_AGENT_DEPTH', '0')) > 0:
        parser.error('子代理不能发布主对话的应用更新；请把结果回传给父代理。')
    if not args.announcement.strip() or len(args.announcement) > 100:
        parser.error('更新公告必须为 1–100 字')
    owner = os.environ.get('PI_SESSION_ID') or 'external-maintainer'
    root = Path.home()/'Library/Application Support/F/updates'
    try:
        # Lock covers build, every validation, digest checks and pending commit.
        # No source-output write restrictions in this authorized publisher subprocess.
        with coordination.publication_lock(root), coordination.Store(source).freeze(owner):
            prepare(args, root)
    except (ValueError, RuntimeError, FileExistsError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
