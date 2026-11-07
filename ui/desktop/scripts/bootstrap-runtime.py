#!/usr/bin/env python3
"""Install pinned public runtime dependencies for a source checkout."""
from pathlib import Path
import hashlib
import os
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

root = Path(__file__).resolve().parents[3]
version = '24.22.2'


def bootstrap():
    node = root/'runtime/node/bin/node'
    if not node.is_file():
        if platform.system() != 'Darwin':
            raise RuntimeError('F desktop builds require macOS.')
        arch = {'arm64': 'arm64', 'x86_64': 'x64'}.get(platform.machine())
        if not arch:
            raise RuntimeError('Unsupported macOS architecture.')
        name = f'node-v{version}-darwin-{arch}.tar.gz'
        base = f'https://nodejs.org/dist/v{version}/'
        sums = urllib.request.urlopen(base+'SHASUMS256.txt', timeout=60).read().decode()
        expected = next(line.split()[0] for line in sums.splitlines() if line.split()[-1] == name)
        with tempfile.TemporaryDirectory(prefix='f-node-') as temporary:
            archive = Path(temporary)/name
            with urllib.request.urlopen(base+name, timeout=120) as response, archive.open('wb') as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
                raise RuntimeError('Node checksum did not match; nothing was installed.')
            extracted = Path(temporary)/'unpack'
            extracted.mkdir()
            with tarfile.open(archive) as bundle:
                for member in bundle.getmembers():
                    target = (extracted/member.name).resolve()
                    if extracted not in target.parents:
                        raise RuntimeError('Invalid runtime archive path.')
                    if member.issym() or member.islnk():
                        linked = (target.parent/member.linkname).resolve()
                        if extracted not in linked.parents:
                            raise RuntimeError('Invalid runtime archive link.')
                bundle.extractall(extracted)
            destination = root/'runtime/node'
            if destination.exists():
                raise RuntimeError('Incomplete runtime/node exists; preserve it before retrying.')
            shutil.move(str(extracted/name.removesuffix('.tar.gz')), destination)
    environment = dict(os.environ, PATH=str(node.parent)+os.pathsep+os.environ.get('PATH', ''))
    for directory, marker in [('runtime/agent', 'node_modules/@earendil-works/pi-coding-agent'),
                              ('packages/excalidraw/web', 'node_modules/.bin/vite')]:
        folder = root/directory
        if not (folder/marker).exists():
            subprocess.run([str(node.parent/'npm'), 'ci'], cwd=folder, env=environment, check=True)


if __name__ == '__main__':
    bootstrap()
