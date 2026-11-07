#!/usr/bin/env python3
"""Package a validated app with its runtime; never copy local credentials or data."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[3]
private = ('runtime/agent/state', 'runtime/agent/codebuddy', 'auth/deepseek/deepseek-api.md')


def public_files():
    raw = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=source)
    for name in sorted(set(raw.decode().split('\0')) - {''}):
        if name.startswith(('.git', 'F_data/workspace-', *private)):
            continue
        path = source/name
        if not path.is_file():
            continue
        resolved = path.resolve()
        if source != resolved and source not in resolved.parents:
            raise RuntimeError('Source alias leaves checkout: '+name)
        yield name, resolved


def package(app, destination, version, identity):
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='f-dmg-') as temporary:
        stage = Path(temporary).resolve()/'volume'
        stage.mkdir()
        target = stage/'F.app'
        subprocess.run(['/usr/bin/ditto', str(app), str(target)], check=True)
        resources = target/'Contents/Resources'
        # Keep the already-validated frozen assets. Fill in canonical source files
        # so every import has the same relative path as a source installation.
        for name, original in public_files():
            output = resources/name
            if not output.exists():
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, output)
        runtime = resources/'runtime'
        shutil.copytree(source/'runtime/agent/node_modules', runtime/'agent/node_modules', symlinks=True)
        shutil.copytree(source/'runtime/node', runtime/'node', symlinks=True, dirs_exist_ok=True)
        for path in resources.rglob('*'):
            if path.is_symlink():
                resolved = path.resolve(strict=True)
                if resources not in resolved.parents:
                    # npm may have created absolute executable links in a source
                    # checkout. Rewrite only links into this pinned dependency tree.
                    modules = (source/'runtime/agent/node_modules').resolve()
                    if modules in resolved.parents:
                        bundled = runtime/'agent/node_modules'/resolved.relative_to(modules)
                        if not bundled.is_file():
                            raise RuntimeError('Missing bundled dependency: '+str(bundled))
                        path.unlink()
                        path.symlink_to(os.path.relpath(bundled, path.parent))
                    else:
                        raise RuntimeError('Runtime alias leaves app: '+str(path.relative_to(resources)))
        for name in private:
            if (resources/name).exists():
                raise RuntimeError('Private state in app: '+name)
        (resources/'F-distribution.json').write_text(json.dumps({'type': 'dmg', 'version': version,
            'data': '~/Library/Application Support/F', 'cache': '~/Library/Caches/F'}, indent=2)+'\n')
        info = target/'Contents/Info.plist'
        value = plistlib.loads(info.read_bytes())
        value.update(FDistribution='dmg', PiCLIPath='', PiAgentDir='', LSMinimumSystemVersion='13.5',
                     CFBundleShortVersionString=version, CFBundleVersion=version.replace('.', ''))
        info.write_bytes(plistlib.dumps(value))
        # Sign nested executables before sealing the app; no modification follows.
        macho = [b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe']
        for file in resources.rglob('*'):
            if file.is_file() and not file.is_symlink():
                with file.open('rb') as stream:
                    native = stream.read(4) in macho
                if native:
                    subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, str(file)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, str(target)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep', str(target)], check=True)
        subprocess.run([str(target/'Contents/MacOS/F'), '--self-check'], check=True)
        (stage/'Applications').symlink_to('/Applications', target_is_directory=True)
        architecture = subprocess.check_output(['/usr/bin/uname', '-m'], text=True).strip()
        dmg = destination/f'F-{version}-macOS-{architecture}.dmg'
        subprocess.run(['/usr/bin/hdiutil', 'create', '-volname', 'F', '-srcfolder', str(stage),
                        '-format', 'UDZO', '-ov', str(dmg)], check=True)
        subprocess.run(['/usr/bin/hdiutil', 'verify', str(dmg)], check=True)
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        (destination/'SHA256SUMS.txt').write_text(f'{digest}  {dmg.name}\n')
        print(json.dumps({'dmg': str(dmg), 'sha256': digest, 'minimumMacOS': '13.5',
                          'architecture': architecture, 'notarized': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--identity', default='F Local Signing')
    args = parser.parse_args()
    package(args.app.resolve(strict=True), args.output, args.version, args.identity)
