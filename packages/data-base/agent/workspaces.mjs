import { DatabaseSync } from 'node:sqlite';
import { mkdir, readFile, realpath, symlink, lstat, readlink, stat, rename, unlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { applicationData, atomicJSON, withLock } from './store.mjs';

const identity = value => createHash('sha256').update(value).digest('hex').slice(0, 24);
const safeID = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value);

async function canonicalTarget(target, future) {
  try { target = await realpath(target); }
  catch (error) {
    if (!future || error.code !== 'ENOENT') throw error;
    target = path.join(await realpath(path.dirname(target)), path.basename(target));
  }
  return target;
}

// A link is an index into existing data, never a second writable copy.
async function linkExisting(target, destination, future = false) {
  if (!target) return;
  target = await canonicalTarget(target, future);
  try {
    const info = await lstat(destination);
    if (!info.isSymbolicLink()) throw Error('Workspace entry conflicts with existing data: ' + destination);
    const linked = path.resolve(path.dirname(destination), await readlink(destination));
    if (linked !== target) {
      const resolved = await canonicalTarget(linked, future).catch(error => { if (error.code === 'ENOENT') return linked; throw error; });
      if (resolved !== target) throw Error('Workspace entry conflicts with existing data: ' + destination);
      const temp = destination + '.' + randomUUID();
      try { await symlink(target, temp); await rename(temp, destination); }
      finally { await unlink(temp).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await symlink(target, destination);
  }
  return target;
}

export class WorkspaceStore {
  constructor(directory = process.env.F_DATA_DIRECTORY ?? path.join(applicationData(), 'F_data')) { this.directory = path.resolve(directory); }
  async register(project, { id, name = path.basename(project), remote = null } = {}) {
    project = await realpath(project);
    const info = await stat(project), projectIdentity = `${info.dev}:${info.ino}`;
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    return withLock(path.join(this.directory, '.registry-lock'), async () => {
      let index;
      try { index = JSON.parse(await readFile(path.join(this.directory, 'index.json'), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; index = {}; }
      if (!index || typeof index !== 'object' || Array.isArray(index) || Object.values(index).some(id => !safeID(id))) throw Error('Invalid workspace index; existing data was preserved');
      const key = remote ? JSON.stringify([remote.endpoint, remote.cwd]) : project;
      if (!index[key] && !remote && !id) {
        for (const existing of new Set(Object.values(index))) {
          const manifest = JSON.parse(await readFile(path.join(this.directory, existing, 'workspace.json'), 'utf8'));
          if (manifest.projectIdentity === projectIdentity && !manifest.remote) { index[key] = existing; break; }
        }
      }
      if (id && index[key] && id !== index[key]) throw Error('Workspace identity already registered');
      id = index[key] ?? id ?? 'workspace-' + identity(key);
      if (!safeID(id)) throw Error('Invalid workspace id');
      const directory = path.join(this.directory, id), file = path.join(directory, 'workspace.json');
      await mkdir(directory, { recursive: true, mode: 0o700 });
      let previous;
      try { previous = JSON.parse(await readFile(file, 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (previous && ((previous.project !== project && previous.projectIdentity !== projectIdentity) || JSON.stringify(previous.remote) !== JSON.stringify(remote))) throw Error('Workspace identity already belongs to another project');
      const value = { ...previous, schema: 1, id, name, project, projectIdentity, remote, createdAt: previous?.createdAt ?? new Date().toISOString() };
      for (const child of ['sessions', 'workspace_apps']) await mkdir(path.join(directory, child), { recursive: true, mode: 0o700 });
      const db = new DatabaseSync(path.join(directory, 'state.db'));
      try {
        db.exec('PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, history TEXT, board TEXT, updated_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS checkpoints (id TEXT PRIMARY KEY, value TEXT NOT NULL);');
      } finally { db.close(); }
      await atomicJSON(file, value);
      for (const oldKey of Object.keys(index)) if (index[oldKey] === id && oldKey !== key) delete index[oldKey];
      index[key] = id; await atomicJSON(path.join(this.directory, 'index.json'), index);
      return { ...value, directory };
    });
  }
  async session(workspace, { id, history, board }) {
    if (!safeID(id)) throw Error('Invalid session id');
    const directory = path.join(workspace.directory, 'sessions', id);
    return withLock(directory + '.lock', async () => {
      for (const child of ['session_apps', 'artifacts']) await mkdir(path.join(directory, child), { recursive: true, mode: 0o700 });
      history = await linkExisting(history, path.join(directory, 'conversation.jsonl'), true);
      board = await linkExisting(board, path.join(directory, 'session_apps/excalidraw'));
      const db = new DatabaseSync(path.join(workspace.directory, 'state.db'));
      try {
        db.exec('PRAGMA busy_timeout=5000');
        db.prepare('INSERT INTO sessions VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET history=COALESCE(excluded.history,history), board=COALESCE(excluded.board,board), updated_at=excluded.updated_at').run(id, history ?? null, board ?? null, new Date().toISOString());
      } finally { db.close(); }
      return directory;
    });
  }
}

export async function mountWorkspaces(ctx, { directory } = {}) {
  await ctx.plugin({ name: 'f-workspaces', inject: ['host'], apply(scope) {
    const store = new WorkspaceStore(directory);
    scope.provide('workspaces', store);
    scope.host.on(scope, 'session_start', async (_event, context) => {
      const remote = process.env.F_REMOTE_PROJECT ? JSON.parse(process.env.F_REMOTE_PROJECT) : null;
      const workspace = await store.register(process.env.F_LOCAL_PROJECT ?? context.cwd, { remote });
      const board = process.env.F_CONVERSATION_DIR ?? process.env.F_BOARD_DIR;
      if (board) await mkdir(board, { recursive: true, mode: 0o700 });
      await store.session(workspace, { id: context.sessionManager.getSessionId(), history: context.sessionManager.getSessionFile?.(), board });
    });
  } });
}
