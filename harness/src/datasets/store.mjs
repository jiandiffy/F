import { mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import os from 'node:os';

export const applicationData = () => path.join(os.homedir(), 'Library/Application Support/F');
export const recordID = (dataset, source) => createHash('sha256').update(`${dataset}\0${source}`).digest('hex');

function validEvidence(evidence) {
  const url = typeof evidence?.url === 'string' ? URL.parse(evidence.url) : null;
  return ['institution', 'performance', 'discussion'].includes(evidence?.kind) &&
    typeof evidence.summary === 'string' && evidence.summary.trim().length > 0 &&
    url && ['http:', 'https:'].includes(url.protocol) && url.hostname && !url.username && !url.password &&
    Number.isFinite(evidence.score) && evidence.score >= 0 && evidence.score <= 1;
}

export async function atomicJSON(file, value) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = `${file}.${randomUUID()}.tmp`;
  try { await writeFile(temp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 }); await rename(temp, file); }
  finally { await rm(temp, { force: true }); }
}

export async function withLock(directory, run, { timeoutMs = 5000, signal } = {}) {
  signal?.throwIfAborted();
  await mkdir(path.dirname(directory), { recursive: true, mode: 0o700 });
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    signal?.throwIfAborted();
    try { await mkdir(directory, { mode: 0o700 }); break; }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (performance.now() >= deadline) throw new Error('Dataset/version is busy. Retry after its current operation finishes.');
      await new Promise(resolve => setTimeout(resolve, 50));
    }
  }
  try { signal?.throwIfAborted(); return await run(); } finally { await rm(directory, { recursive: true }); }
}

export class DatasetStore {
  constructor(directory = path.join(applicationData(), 'applications/datasets/global')) { this.directory = directory; }
  file(id) {
    if (!/^[a-f0-9]{64}$/.test(id)) throw new Error('Invalid dataset record ID');
    return path.join(this.directory, 'records', `${id}.json`);
  }
  async get(id) { return JSON.parse(await readFile(this.file(id), 'utf8')); }
  async put(record) {
    if (!record.dataset || !record.source?.url || !record.title) throw new Error('A record needs dataset, title and source.url');
    if (record.evidence && (!Array.isArray(record.evidence) || record.evidence.some(e => !validEvidence(e))))
      throw new Error('Evidence needs kind, source URL, summary and explicit 0–1 score');
    const id = recordID(record.dataset, record.source.url);
    return withLock(this.file(id) + '.lock', async () => {
      let previous;
      try { previous = await this.get(id); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      const value = { ...previous, ...record, id, evidence: record.evidence ?? previous?.evidence ?? [],
        addedAt: previous?.addedAt ?? record.addedAt ?? new Date().toISOString(), updatedAt: new Date().toISOString() };
      await atomicJSON(this.file(id), value); return value;
    });
  }
  async evidence(id, evidence) {
    if (!validEvidence(evidence))
      throw new Error('Evidence needs kind, source URL, summary and explicit 0–1 score');
    return withLock(this.file(id) + '.lock', async () => {
      const value = await this.get(id);
      value.evidence = [...value.evidence.filter(e => !(e.kind === evidence.kind && e.url === evidence.url)),
        { ...evidence, observedAt: new Date().toISOString() }];
      value.updatedAt = new Date().toISOString(); await atomicJSON(this.file(id), value); return value;
    });
  }
  async search(query = '', { dataset, limit = 30, now = Date.now() } = {}) {
    let files;
    try { files = await readdir(path.join(this.directory, 'records')); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const rows = [];
    for (const name of files.filter(name => /^[a-f0-9]{64}\.json$/.test(name))) {
      const record = await this.get(name.slice(0, -5));
      if (dataset && record.dataset !== dataset) continue;
      const text = JSON.stringify([record.title, record.summary, record.tags, record.content]).toLowerCase();
      if (!terms.every(term => text.includes(term))) continue;
      const ranking = rankPaper(record, now); rows.push({ ...record, ranking });
    }
    return rows.sort((a, b) => b.ranking.score - a.ranking.score || b.addedAt.localeCompare(a.addedAt)).slice(0, Math.min(100, Math.max(1, limit)));
  }
}

// Unknown evidence stays unknown. Institution reputation is an explicit, sourced
// user/research judgment, never inferred from an author's name or affiliation alone.
export function rankPaper(record, now = Date.now()) {
  const age = Math.max(0, now - Date.parse(record.source?.dateAdded ?? record.addedAt));
  const recency = Number.isFinite(age) ? Math.exp(-age / (180 * 86400000)) : 0;
  const evidence = {};
  for (const kind of ['institution', 'performance', 'discussion']) {
    const values = (record.evidence ?? []).filter(e => e.kind === kind && validEvidence(e));
    evidence[kind] = values.length ? Math.max(...values.map(e => e.score)) : null;
  }
  return { score: 0.4 * recency + 0.2 * (evidence.institution ?? 0) + 0.2 * (evidence.performance ?? 0) + 0.2 * (evidence.discussion ?? 0),
    recency, ...evidence, policy: 'recency .4; sourced institution/performance/discussion .2 each; missing evidence contributes 0, not a negative finding' };
}

export class DatasetRegistry {
  providers = new Map();
  register(provider) {
    if (!/^[a-z][a-z0-9.-]*$/.test(provider.name) || !provider.description || typeof provider.search !== 'function')
      throw new Error('Dataset provider needs name, description and search');
    if (this.providers.has(provider.name)) throw new Error('Duplicate dataset provider');
    this.providers.set(provider.name, provider);
    return () => this.providers.delete(provider.name);
  }
  catalog() { return [...this.providers.values()].map(({ name, description }) => ({ name, description })); }
  search(name, query, options) {
    const provider = this.providers.get(name);
    if (!provider) throw new Error(`Unknown dataset: ${name}`);
    return provider.search(query, options);
  }
}
