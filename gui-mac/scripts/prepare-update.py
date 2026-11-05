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

source = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_module('f_update_helper', source/'gui-mac/Resources/update-helper.py')
coordination = load_module('f_maintenance_lock', source/'harness/src/skills/maintenance_lock.py')


def source_digest():
    digest = hashlib.sha256()
    roots = ['harness/src', 'harness/upstream', 'harness/scripts', 'harness/tests', 'skills',
             'gui-mac/Core', 'gui-mac/Plugins', 'gui-mac/scripts', 'gui-mac/tests',
             'pi/agent/extensions', 'pi/agent/modules', 'pi/scripts', 'pi/vendor/pi-codebuddy-sdk-cbi/src',
             'pi/vendor/pi-codebuddy-sdk-cbc/src', 'whiteboard/src', 'whiteboard/public']
    files = [source/name for name in ['AGENTS.md', 'F_MAINTENANCE.md', 'gui-mac/main.swift', 'gui-mac/build.sh',
             'gui-mac/Info.plist', 'gui-mac/PLUGIN_SPEC.md', 'gui-mac/ARCHITECTURE.md', 'harness/README.md', 'pi/package.json', 'whiteboard/package.json',
             'whiteboard/package-lock.json', 'harness/package.json', 'harness/package-lock.json', 'pi/package-lock.json']]
    files += [p for name in roots for p in (source/name).rglob('*') if p.is_file() and
              'node_modules' not in p.parts and '__pycache__' not in p.parts]
    # Build-generated whiteboard/terminal Resources and harness/dist are outputs, not inputs.
    # Terminal source is covered by gui-mac/Plugins/Terminal/Web and dependency lockfiles.
    files += [p for p in (source/'gui-mac/Resources').rglob('*') if p.is_file() and
              p.relative_to(source/'gui-mac/Resources').parts[0] not in ('whiteboard', 'terminal') and
              '__pycache__' not in p.parts]
    files += [p for p in (source/'whiteboard').glob('*') if p.is_file()]
    for file in sorted(set(files)):
        digest.update(str(file.relative_to(source)).encode() + b'\0' + file.read_bytes())
    return digest.hexdigest()


def require_source_digest(expected):
    if source_digest() != expected:
        raise RuntimeError('验证期间源码变化，未发布更新。请重新构建验证。')


def prepare(args, root):
    """Caller holds the process-wide publication lock and the source lease freeze."""
    target = Path(os.environ.get('F_APP_BUNDLE', source/'gui-mac/F.app')).resolve()
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
    command = ['bash', str(source/'gui-mac/build.sh'), '--app='+str(artifact)]
    if args.no_whiteboard:
        command.append('--no-whiteboard')
    run('isolated-build', command)
    node = str(source/'pi/runtime/node/bin/node')
    # A maintenance Agent inherits its real board/lease paths. Tests must never use that ledger.
    harness_env = dict(os.environ, F_BOARD_DIR=str(validation/'harness-board'),
                       F_CONVERSATION_DIR=str(validation/'harness-conversation'))
    harness_env.pop('F_AGENT_ID', None)
    run('harness', [node, '--test', *[str(p) for p in sorted((source/'harness/tests').glob('*.test.mjs'))]], env=harness_env)
    run('provider-tool-bridge', [node, '--test', str(source/'pi/scripts/test-codebuddy-tool-replay.mjs')])
    for suite in ['run-whiteboard-tests.py', 'run-queue-tests.py', 'run-plugin-tests.py', 'run-file-browser-tests.py', 'run-history-navigation-tests.py', 'run-viewport-tests.py', 'run-versions-tests.py', 'run-project-mutation-tests.py', 'run-update-tests.py', 'run-project-stress-tests.py', 'run-daily-paper-tests.py', 'run-paper-media-tests.py', 'run-gmail-tests.py', 'run-browser-tests.py']:
        run(suite.removesuffix('.py'), ['/usr/bin/python3', str(source/'gui-mac/tests'/suite)])
    # Test the exact frozen Harness carried by the signed candidate, with real model calls.
    run('cbi-deepseek-flash', [node, str(source/'harness/tests/test-cbi.mjs'), '--report', str(validation/'cbi.json'), '--native-report', str(report_path)],
        env=dict(os.environ, F_HARNESS_DIR=str(artifact/'Contents/Resources/harness')))
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
