#!/usr/bin/env python3
"""Cooperative F maintenance leases. flock protects every registry transaction.

Not a security boundary against another program running as the same macOS user.
No time-based lease stealing: a paused/old session must never lose its edits.
"""
from contextlib import contextmanager
from pathlib import Path
import fcntl
import hashlib
import json
import os
import tempfile
import uuid


def inside(path, scope):
    return path == scope or scope in path.parents


def overlaps(a, b):
    return inside(a, b) or inside(b, a)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix='registry-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


class Store:
    def __init__(self, root, base=None):
        self.root = Path(root).resolve()
        self.base = Path(base) if base else Path.home()/'Library/Application Support/F/maintenance/coordination'
        self.directory = self.base/hashlib.sha256(os.fsencode(self.root)).hexdigest()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)

    @contextmanager
    def transaction(self):
        # Never unlink a flock file: waiters must continue to lock the same inode.
        with (self.directory/'registry.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            file = self.directory/'registry.json'
            state = json.loads(file.read_text()) if file.exists() else {'version': 1, 'leases': {}, 'pins': {}}
            state['pins'] = {k: p for k, p in state['pins'].items() if alive(p['pid'])}
            if state.get('freeze') and not alive(state['freeze']['pid']):
                del state['freeze']
            yield state
            atomic_json(file, state)

    def scope(self, raw):
        path = Path(raw)
        path = Path(os.path.abspath(path if path.is_absolute() else self.root/path))
        if not inside(path, self.root):
            raise ValueError('编辑范围必须在 F 源码目录内')
        # Symlink aliases and hard links must not create a second writable name.
        for part in [path, *path.parents]:
            if part == self.root:
                break
            if part.is_symlink():
                raise ValueError('维护编辑范围不支持符号链接: ' + str(part))
        if path.is_file() and path.stat().st_nlink > 1:
            raise ValueError('维护编辑不支持硬链接: ' + str(path))
        return path

    def domain(self, path):
        # Plugin ownership is directory-wide even when the requested permission is
        # one file. Common source only conflicts on actual ancestor intersections.
        relative = path.relative_to(self.root).parts
        if len(relative) >= 3 and relative[:2] == ('gui-mac', 'Plugins'):
            return self.root.joinpath(*relative[:3])
        return path

    def conflicts(self, a, b):
        return overlaps(self.domain(a), self.domain(b))

    def paths(self, raw):
        if not isinstance(raw, list) or not raw or any(not isinstance(p, str) or not p for p in raw):
            raise ValueError('必须提供非空 paths 数组（文件或目录，不支持 glob）')
        return sorted(set(map(self.scope, raw)))

    @staticmethod
    def mutable(state):
        if state.get('freeze'):
            raise ValueError('主线发布已冻结源码；不能编辑或更改范围租约')

    def authorized(self, state, owner, path):
        lease = state['leases'].get(owner)
        if not lease or not any(inside(path, Path(p)) for p in lease['paths']):
            raise ValueError('无编辑范围授权，请先 maintenance_scope claim: ' + str(path))
        # A parent retains its broad reservation, but not the delegated subtree.
        for other, entry in state['leases'].items():
            if other != owner and self.descendant(state, other, owner) and any(self.conflicts(path, Path(p)) for p in entry['paths']):
                raise ValueError('该范围已转授子代理，父会话不能覆盖: ' + str(path))

    @staticmethod
    def descendant(state, child, parent):
        seen = set()
        while child in state['leases'] and child not in seen:
            seen.add(child)
            child = state['leases'][child].get('parent')
            if child == parent:
                return True
        return False

    def operate(self, owner, action, args=None):
        if not owner:
            raise ValueError('缺少会话身份，拒绝无授权修改')
        args = args or {}
        with self.transaction() as state:
            leases = state['leases']
            if action == 'status':
                return state
            if action == 'unpin':
                pin = state['pins'].get(args['token'])
                if pin and pin['owner'] == owner:
                    del state['pins'][args['token']]
                return {'released': True}
            self.mutable(state)
            if action == 'release':
                if any(self.descendant(state, other, owner) for other in leases):
                    raise ValueError('请先让子代理释放已转授范围')
                if any(p['owner'] == owner for p in state['pins'].values()):
                    raise ValueError('编辑工具仍在执行，不能释放租约')
                leases.pop(owner, None)
                return {'released': True}
            if action == 'claim':
                paths = self.paths(args.get('paths'))
                for other, entry in leases.items():
                    if other != owner and any(self.conflicts(a, Path(b)) for a in paths for b in entry['paths']):
                        raise ValueError('编辑范围与另一会话相交: ' + other)
                prior = leases.get(owner, {})
                if prior.get('parent'):
                    raise ValueError('已转授租约不能自行扩张；请让父会话重新转授')
                leases[owner] = {'paths': sorted(set(prior.get('paths', []) + list(map(str, paths))))}
                return leases[owner]
            if action == 'delegate':
                child = args['childId']
                if child == owner or child in leases:
                    raise ValueError('子代理已有租约；请先释放后重新转授')
                paths = self.paths(args.get('paths'))
                for p in paths:
                    self.authorized(state, owner, p)
                if any(p['owner'] == owner and any(self.conflicts(Path(p['path']), q) for q in paths) for p in state['pins'].values()):
                    raise ValueError('范围内仍有执行中的编辑，不能转授')
                leases[child] = {'paths': list(map(str, paths)), 'parent': owner}
                return leases[child]
            if action == 'pin':
                p = self.scope(args['path'])
                self.authorized(state, owner, p)
                token = str(uuid.uuid4())
                state['pins'][token] = {'owner': owner, 'path': str(p), 'pid': args['pid']}
                return {'token': token}
            raise ValueError('未知维护操作: ' + action)

    @contextmanager
    def freeze(self, owner):
        token = str(uuid.uuid4())
        with self.transaction() as state:
            self.mutable(state)
            if any(other != owner for other in state['leases']) or state['pins']:
                raise ValueError('仍有其他会话范围租约或执行中的编辑；请协调 release 后再发布')
            state['freeze'] = {'owner': owner, 'pid': os.getpid(), 'token': token}
        try:
            yield
        finally:
            with self.transaction() as state:
                if state.get('freeze', {}).get('token') == token:
                    del state['freeze']


@contextmanager
def publication_lock(updates):
    updates = Path(updates)
    updates.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (updates/'.prepare-update.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('另一 prepare-update 进程正在验证/发布，请稍后重试') from None
        if os.path.lexists(updates/'pending.json'):
            raise ValueError('已有待安装更新，不能覆盖 pending.json')
        yield


def publish_pending(candidate, pending):
    """Atomic no-clobber commit; only unlink our own temporary candidate."""
    os.link(candidate, pending)  # EEXIST, including a dangling symlink, is a hard failure.


if __name__ == '__main__':
    import sys
    try:
        root, owner, action, payload = sys.argv[1:]
        print(json.dumps(Store(root).operate(owner, action, json.loads(payload)), ensure_ascii=False))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
