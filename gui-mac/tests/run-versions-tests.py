#!/usr/bin/env python3
"""Focused real AppKit/Git regression. No full F build, installation or restart.

All binaries, isolated repositories, screenshots and logs stay under /tmp.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', type=Path)
    options = parser.parse_args()
    source = (options.source_root or Path(__file__).resolve().parents[2]).resolve()
    versions = source / 'gui-mac/Plugins/Versions'
    if not versions.is_dir():
        parser.error('Run from F source root or pass --source-root')
    work = Path(tempfile.mkdtemp(prefix='f-versions-regression-', dir='/tmp'))
    print('Versions regression artifacts: ' + str(work), flush=True)
    repo = work / 'repo'; repo.mkdir()
    home = work / 'home'; home.mkdir()
    env = dict(os.environ, HOME=str(home), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')

    def git(*args):
        return subprocess.check_output(['/usr/bin/git', '-C', str(repo), *args], stderr=subprocess.STDOUT, env=env).decode().strip()

    git('init', '--initial-branch=main')
    git('config', 'user.name', '测试作者'); git('config', 'user.email', 'test@localhost')
    (repo / 'read me.txt').write_text('first fixed snapshot\n')
    (repo / 'delete.txt').write_text('deleted later\n')
    (repo / '二进制.bin').write_bytes(b'\x00\x01\x02')
    (repo / 'empty').write_bytes(b'')
    (repo / 'tab\tline\n中文.txt').write_text('unicode path\n')
    (repo / 'symlink').symlink_to('/etc/passwd')
    (repo / 'large.txt').write_bytes(b'x' * (2 * 1024 * 1024 + 1))
    git('add', '.'); git('commit', '-m', '初始版本：提交固定文件快照，用于验证只读预览不会读取工作区。')
    first = git('rev-parse', 'HEAD')
    git('switch', '-c', 'child')
    (repo / 'read me.txt').write_text('child immutable content\n'); (repo / 'delete.txt').unlink()
    git('add', '.'); git('commit', '-m', '改进预览并删除旧文档\n\n文件改动来源为真实 Git 对象，不生成推测结论。')
    child = git('rev-parse', 'HEAD')
    git('switch', 'main'); (repo / 'main.txt').write_text('main branch\n')
    git('add', '.'); git('commit', '-m', 'Main independent change')
    git('merge', '--no-ff', 'child', '-m', 'Merge tested child'); merged = git('rev-parse', 'HEAD')
    (repo / 'read me.txt').write_text('UNCOMMITTED: must never be previewed\n'); (repo / 'subdir').mkdir()
    (work / 'hashes.txt').write_text('\n'.join([first, child, merged]))
    # A separate truly uninitialized folder proves native opt-in, not just a mocked UI.
    (work / 'opt-in').mkdir(); (work / 'other').mkdir()
    (work / 'opt-in/user.txt').write_text('preserve this untracked file\n')
    swift = (source / 'gui-mac/tests/versions-regression.swift').read_text()
    (work / 'main.swift').write_text(swift.replace('__TEST_DIR__', str(work)))
    (work / 'Stubs.swift').write_text('import Foundation\n' +
        'enum BoardStore { static let appSupport = URL(fileURLWithPath: ' + json.dumps(str(work / 'data')) + ') }\n' +
        'enum RemoteProjects { static func load(_ url: URL) -> String? { nil } }\n' +
        'enum PiPaths { static var cliPath: String? { ' + json.dumps(str(source / 'pi/bin/pi')) + ' } }\n')
    command = ['swiftc', '-module-cache-path', str(work / 'module-cache'),
        str(source / 'gui-mac/Core/Kernel.swift'), str(source / 'gui-mac/Core/Plugins.swift'),
        str(work / 'Stubs.swift'), *map(str, sorted(versions.glob('*.swift'))),
        str(work / 'main.swift'), '-o', str(work / 'versions-tests')]
    with (work / 'compile.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        print((work / 'compile.log').read_text()); return result.returncode
    with (work / 'results.log').open('w') as log:
        result = subprocess.run([str(work / 'versions-tests')], stdout=log, stderr=subprocess.STDOUT, env=env)
    print((work / 'results.log').read_text(), end='')
    print('Versions regression exit: ' + str(result.returncode), flush=True)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
