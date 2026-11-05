import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DatasetStore, DatasetRegistry, rankPaper } from '../../../packages/data-base/agent/store.mjs';
import { parseArxiv, zoteroProvider } from '../../../packages/data-base/agent/providers.mjs';

test('records deduplicate, preserve evidence and added dates under concurrent updates', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'f-dataset-'));
  try {
    const store = new DatasetStore(dir), record = { dataset: 'paper', title: 'Robot policy', source: { url: 'https://arxiv.org/abs/1234.5678' } };
    const first = await store.put(record);
    const evidence = { kind: 'performance', summary: 'Table 2: success rate improves 12 points on benchmark X.', url: 'https://arxiv.org/abs/1234.5678', score: 0.8 };
    await Promise.all(Array.from({ length: 8 }, () => store.put(record)).concat(store.evidence(first.id, evidence)));
    const final = await store.get(first.id);
    assert.equal(final.addedAt, first.addedAt); assert.equal(final.evidence.length, 1);
    assert.equal((await store.search('robot', { dataset: 'paper' })).length, 1);
    assert.equal((await store.search('missing')).length, 0);
    await assert.rejects(store.evidence(first.id, { ...evidence, score: 2 }), /0–1/);
    await assert.rejects(store.get('../secrets'), /Invalid/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('paper priority is transparent, recent additions win without invented metrics', () => {
  const now = Date.parse('2026-11-01T00:00:00Z');
  const recent = rankPaper({ addedAt: '2026-10-31T00:00:00Z' }, now);
  const old = rankPaper({ addedAt: '2025-01-01T00:00:00Z' }, now);
  assert(recent.score > old.score); assert.equal(recent.institution, null); assert.equal(recent.discussion, null);
  assert.equal(rankPaper({ addedAt: 'invalid' }, now).score, 0);
});

test('dataset providers have reversible namespaced registration', async () => {
  const registry = new DatasetRegistry();
  const remove = registry.register({ name: 'custom', description: 'Custom records', search: async q => [q] });
  assert.deepEqual(await registry.search('custom', 'goal'), ['goal']);
  assert.throws(() => registry.register({ name: 'custom', description: 'dup', search() {} }), /Duplicate/);
  remove(); assert.equal(registry.catalog().length, 0); assert.throws(() => registry.search('custom', ''), /Unknown/);
});

test('Zotero uses local metadata route and skips attachment contents', async () => {
  let observed;
  const provider = zoteroProvider({ request: async (url, options) => {
    observed = { url: String(url), options };
    return [{ key: 'ABCDEFGH', version: 4, data: { itemType: 'journalArticle', title: 'Policy', dateAdded: '2026-10-30', creators: [], tags: [{ tag: 'robot' }] } },
      { key: 'PDF12345', data: { itemType: 'attachment' } }];
  }});
  const rows = await provider.search('robot');
  assert.equal(rows.length, 1); assert.equal(rows[0].source.key, 'ABCDEFGH');
  assert(observed.url.startsWith('http://127.0.0.1:23119/api/users/0/items/top?'));
  assert.equal(observed.options.headers['Zotero-API-Key'], undefined);
  assert.equal(rows[0].source.dateAdded, '2026-10-30');
});

test('arxiv Atom parser retains primary provenance, Unicode and affiliations', () => {
  const rows = parseArxiv(`<feed><entry><id>http://arxiv.org/abs/2601.00001v2</id><title>Control &amp; Policy</title><summary>Robot &lt;test&gt; &#x3b1;</summary><published>2026-01-01</published><updated>2026-02-01</updated><author><name>Ada</name><arxiv:affiliation>Lab</arxiv:affiliation></author><category term="cs.RO" /></entry></feed>`);
  assert.equal(rows[0].source.url, 'https://arxiv.org/abs/2601.00001v2');
  assert.equal(rows[0].summary, 'Robot <test> α'); assert.equal(rows[0].creators[0].affiliation, 'Lab');
  assert.deepEqual(rows[0].tags, ['cs.RO']);
});
