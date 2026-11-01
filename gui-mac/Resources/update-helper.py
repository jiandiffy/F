#!/usr/bin/env python3
"""Validated, deferred installation for F. Never replaces a running application's resources."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import time


def digest_file(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def digest_tree(path):
    root = Path(path)
    h = hashlib.sha256()
    for file in sorted(root.rglob('*')):
        if file.is_symlink():
            raise ValueError('Update artifacts cannot contain symlinks')
        if file.is_file():
            h.update(str(file.relative_to(root)).encode()); h.update(b'\0')
            h.update(digest_file(file).encode()); h.update(b'\0')
    return h.hexdigest()


def load_manifest(path, *, verify_signature=True):
    path = Path(path).resolve()
    data = json.loads(path.read_text())
    root = path.parent
    update_id = data['id']
    if not update_id or any(c not in '0123456789abcdef-' for c in update_id):
        raise ValueError('Invalid update id')
    artifact = Path(data['artifact']).resolve()
    target = Path(data['target']).resolve()
    if artifact != root / update_id / 'F.app' or target == artifact or target.suffix != '.app':
        raise ValueError('Invalid update paths')
    if not data['announcement'] or len(data['announcement']) > 100:
        raise ValueError('Announcement must be 1–100 characters')
    info = plistlib.loads((artifact / 'Contents/Info.plist').read_bytes())
    previous = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != previous.get('CFBundleIdentifier'):
        raise ValueError('Application identity changed')
    if digest_tree(artifact) != data['sha256']:
        raise ValueError('Staged application changed after validation')
    executable = previous['CFBundleExecutable']
    if digest_file(target / 'Contents/MacOS' / executable) != data['previous_sha256']:
        raise ValueError('Installed application changed after staging')
    if verify_signature:
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(artifact)], check=True)
        def identity(app):
            r = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True, check=True)
            return [line for line in r.stderr.splitlines() if line.startswith(('Authority=', 'TeamIdentifier='))]
        if not identity(target) or identity(target) != identity(artifact):
            raise ValueError('Signing identity changed')
    return data


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False)); temp.chmod(0o600)
    os.replace(temp, path)


def install(manifest, old_pid):
    data = load_manifest(manifest)
    root = Path(manifest).resolve().parent
    update = root / data['id']
    target = Path(data['target'])
    deadline = time.monotonic() + 90
    while True:
        try:
            os.kill(old_pid, 0)
        except ProcessLookupError:
            break
        if time.monotonic() > deadline:
            return  # The user cancelled quitting. Keep the old application untouched.
        time.sleep(.1)
    data = load_manifest(manifest)
    backup = update / 'previous.app'
    backup.mkdir(exist_ok=True)
    old_contents = backup / 'Contents'
    incoming = Path(data['artifact']) / 'Contents'
    installed = False
    try:
        # Keep the outer F.app directory/path (and stable signing identity) intact.
        os.replace(target / 'Contents', old_contents)
        try:
            os.replace(incoming, target / 'Contents')
        except BaseException:
            os.replace(old_contents, target / 'Contents')
            raise
        installed = True
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(target)], check=True)
        subprocess.run(['/usr/bin/open', '-n', str(target)], check=True)
        ready = update / 'ready.json'
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if ready.exists():
                (root / 'pending.json').unlink(missing_ok=True)
                atomic_json(update / 'result.json', {'success': True, 'announcement': data['announcement']})
                return
            time.sleep(.2)
        raise RuntimeError('Updated F did not finish starting')
    except BaseException as error:
        boot = update / 'boot.json'
        if installed and boot.exists():
            pid = json.loads(boot.read_text()).get('pid')
            if isinstance(pid, int) and pid != old_pid:
                try: os.kill(pid, 15)
                except ProcessLookupError: pass
                time.sleep(.4)
        if installed and old_contents.exists():
            failed = update / 'failed-Contents'
            os.replace(target / 'Contents', failed)
            os.replace(old_contents, target / 'Contents')
        (root / 'pending.json').unlink(missing_ok=True)
        resume_file = root / 'resume.json'
        if resume_file.exists():
            resume = json.loads(resume_file.read_text())
            resume['announcement'] = '更新启动失败，已恢复上一版本。原项目与画板数据已保留。'
            atomic_json(resume_file, resume)
        atomic_json(update / 'result.json', {'success': False, 'error': str(error)})
        subprocess.run(['/usr/bin/open', '-n', str(target)], check=True)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('manifest')
    parser.add_argument('--wait-pid', type=int)
    args = parser.parse_args()
    if args.wait_pid:
        install(args.manifest, args.wait_pid)
    else:
        load_manifest(args.manifest)
        print('Validated staged F update')
