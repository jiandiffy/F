import { mkdir, readFile, writeFile, rename, rmdir, realpath, lstat } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import os from 'node:os';

// Darwin commonly uses case-insensitive volumes; conservative comparison also protects
// differently-cased references on case-sensitive volumes without changing real paths.
const comparePath = value => process.platform === 'darwin' ? value.toLowerCase() : value;
const inside = (candidate, root) => { candidate = comparePath(candidate); root = comparePath(root); return candidate === root || candidate.startsWith(root + path.sep); };
const overlapPath = (a, b) => inside(a, b) || inside(b, a);
export const overlapRect = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
const containsRect = (outer, inner) => inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height;
export function validateRectangle(rectangle) {
  if (!rectangle || !['x','y','width','height'].every(k => Number.isFinite(rectangle[k])) || rectangle.width <= 0 || rectangle.height <= 0)
    throw new Error('Rectangle requires finite x/y and positive width/height');
  return Object.fromEntries(['x','y','width','height'].map(k => [k, rectangle[k]]));
}
export const resourceOwner = context => process.env.F_AGENT_ID || context.sessionManager.getSessionId();
export function resourceDirectory(context) {
  const board = process.env.F_BOARD_DIR || path.join(os.homedir(), 'Library/Application Support/F/aios/projects', createHash('sha256').update(path.resolve(context.cwd)).digest('hex'));
  return path.join(board, 'harness/leases');
}
export function leasesFor(context) { return new ResourceLeases({ directory: resourceDirectory(context), project: context.cwd }); }

/** Durable reservations shared by every conversation/child using one project board. No timeout steals leases. */
export class ResourceLeases {
  constructor({ directory, project }) { this.directory = directory; this.project = path.resolve(project); }
  async locked(operation) {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const lock = path.join(this.directory, 'transaction.lock');
    let acquired = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      try { await mkdir(lock); acquired = true; break; }
      catch (error) { if (error.code !== 'EEXIST') throw error; await new Promise(resolve => setTimeout(resolve, 20)); }
    }
    if (!acquired) throw new Error('Resource transaction is busy; no lock was removed');
    try {
      const file = path.join(this.directory, 'leases.json');
      const state = await readFile(file, 'utf8').then(JSON.parse, error => { if (error.code !== 'ENOENT') throw error; return { version: 1, leases: [], pins: [] }; });
      const value = await operation(state);
      const temporary = path.join(this.directory, randomUUID() + '.tmp');
      await writeFile(temporary, JSON.stringify(state), { mode: 0o600 });
      await rename(temporary, file);
      return value;
    } finally { await rmdir(lock); }
  }
  async normalized(raw) {
    if (typeof raw !== 'string' || !raw.trim() || /[*?\0]/.test(raw)) throw new Error('File scopes require a literal relative path');
    if (path.isAbsolute(raw)) throw new Error('File scope must be relative to the project');
    const candidate = path.resolve(this.project, raw);
    if (!inside(candidate, this.project)) throw new Error('File scope escapes the project');
    const root = await realpath(this.project);
    let cursor = this.project;
    for (const part of path.relative(this.project, candidate).split(path.sep).filter(Boolean)) {
      cursor = path.join(cursor, part);
      const stat = await lstat(cursor).catch(error => { if (error.code !== 'ENOENT') throw error; });
      if (stat?.isSymbolicLink() || (stat?.isFile() && stat.nlink > 1)) throw new Error('File leases do not permit symbolic or hard links');
    }
    return path.join(root, path.relative(this.project, candidate));
  }
  async claim({ owner, paths = [], rectangle, purpose = '' }) {
    if (!owner) throw new Error('Lease owner is required');
    const files = [...new Set(await Promise.all(paths.map(p => this.normalized(p))))];
    const rect = rectangle && validateRectangle(rectangle);
    if (!files.length && !rect) throw new Error('Claim at least one path or board rectangle');
    return this.locked(state => {
      for (const lease of state.leases) {
        if (files.some(a => lease.paths.some(b => overlapPath(a, b))) || (rect && lease.rectangle && overlapRect(rect, lease.rectangle)))
          throw new Error(`Resource conflict with ${lease.owner} (${lease.id})`);
      }
      const lease = { id: randomUUID(), owner, paths: files, rectangle: rect, purpose, createdAt: new Date().toISOString() };
      state.leases.push(lease); return lease;
    });
  }
  async status() { return this.locked(state => structuredClone(state)); }
  async release({ owner, leaseId }) {
    return this.locked(state => {
      const lease = state.leases.find(l => l.id === leaseId);
      if (!lease || lease.owner !== owner) throw new Error('Lease is not owned by this agent');
      if (state.pins.some(pin => pin.leaseId === leaseId)) throw new Error('Lease has an in-flight operation');
      state.leases = state.leases.filter(l => l.id !== leaseId); return { released: leaseId };
    });
  }
  async transfer({ owner, leaseId, childId }) {
    return this.locked(state => {
      const lease = state.leases.find(l => l.id === leaseId);
      if (!lease || lease.owner !== owner) throw new Error('Lease is not owned by this agent');
      if (state.pins.some(pin => pin.leaseId === leaseId)) throw new Error('Lease has an in-flight operation');
      lease.owner = childId; lease.delegatedBy = owner; return lease;
    });
  }
  checkBoard(state, { owner, leaseId, rectangle, rectangles = rectangle ? [rectangle] : [] }) {
    const lease = state.leases.find(l => l.id === leaseId && l.owner === owner && l.rectangle);
    if (!lease) throw new Error('Claim a board rectangle with resource_scope before drawing');
    for (const rect of rectangles) if (!containsRect(lease.rectangle, validateRectangle(rect))) throw new Error('Board change exceeds the reserved rectangle');
    return lease;
  }
  async assertBoard(args) { return this.locked(state => this.checkBoard(state, args)); }
  /** Execute read/version-check/patch/atomic-save inside this lock to avoid stale whole-scene writes. */
  async withBoardLease(args, operation) { return this.locked(async state => operation(this.checkBoard(state, args))); }
  async pinFile({ owner, file, token = randomUUID(), required = true }) {
    const normalized = await this.normalized(path.relative(this.project, path.resolve(this.project, file)) || '.');
    return this.locked(state => {
      const conflicts = state.leases.filter(l => l.paths.some(p => inside(normalized, p)));
      if (conflicts.some(l => l.owner !== owner)) throw new Error('File belongs to another agent’s reservation');
      const lease = conflicts.find(l => l.owner === owner);
      if (!lease && required) throw new Error('Claim the file scope with resource_scope before editing');
      if (!lease) return undefined;
      state.pins.push({ token, leaseId: lease.id, owner }); return token;
    });
  }
  async pinLeases({ owner, leaseIds }) {
    return this.locked(state => leaseIds.map(leaseId => {
      if (!state.leases.some(l => l.id === leaseId && l.owner === owner)) throw new Error('Lease ownership changed before shell execution');
      const token = randomUUID(); state.pins.push({ token, leaseId, owner }); return token;
    }));
  }
  async unpin(token) { return this.locked(state => { state.pins = state.pins.filter(p => p.token !== token); }); }
  async withFileLease(args, operation) {
    const token = await this.pinFile(args);
    try { return await operation(); } finally { if (token) await this.unpin(token); }
  }
}
