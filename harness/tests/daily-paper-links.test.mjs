import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir, rm, readdir, symlink } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { updateDaily } from '../src/daily-paper/links.mjs';
import { mailCards } from '../src/daily-paper/mail.mjs';
import { mailText } from '../src/daily-paper/source.mjs';

function client() {
  const c = { id: 'latest', calls: [], async call(route) {
    c.calls.push(route);
    if (route === '/labels') return { labels: [{ id: 'P', name: 'daily papers' }] };
    if (route.startsWith('/messages?')) { const q = new URLSearchParams(route.split('?')[1]); assert.equal(q.get('maxResults'), '1'); assert.equal(q.get('labelIds'), 'P'); return { messages: [{ id: c.id }], nextPageToken: 'NEVER' }; }
    if (route === '/profile') return { emailAddress: 'fixture@example.org' };
    if (route === `/messages/${c.id}?format=full`) return { labelIds: ['P'], internalDate: '1700000000000', payload: { mimeType: 'text/html', body: { data: Buffer.from('<a href="https://arxiv.org/abs/2401.12345v1">A Useful Paper &amp; Its Evidence</a><a href="https://alphaxiv.org/abs/2401.12346">Second Research Paper</a>').toString('base64url') } } };
    throw new Error('Unexpected request: ' + route);
  } }; return c;
}
async function fixture(t) { const p = await mkdtemp(path.join(os.tmpdir(), 'f-daily-links-')); t.after(() => rm(p, { recursive: true, force: true })); return p; }
test('mail cards preserve inert titles, deduplicate versions and ignore mail tracking media', () => {
  const cards = mailCards('<a href="https://arxiv.org/abs/2401.12345v1">A Useful <b>Research</b> Paper &amp; Evidence</a><img src="https://tracking.invalid/pixel"> https://arxiv.org/pdf/2401.12345v2');
  assert.deepEqual(cards, [{ id: '2401.12345', version: 'v1', title: 'A Useful Research Paper & Evidence' }]);
  assert.equal(mailCards('<table><tr><td>A Digest Title Without A Title Link</td></tr><tr><td><a href="https://arxiv.org/pdf/2401.12345v1">PDF</a></td></tr></table>')[0].title, 'A Digest Title Without A Title Link');
  const body = { mimeType: 'text/plain', body: { data: Buffer.from('x'.repeat(1_000_000)).toString('base64url') } };
  assert.ok(mailText({ parts: Array(40).fill(body) }).length <= 8_000_000, 'MIME parts share one memory budget');
});
test('production update commits only mail links and never invokes paper, media or model code', async t => {
  const root = await fixture(t), c = client();
  const forbidden = () => { throw Error('must never run'); };
  const value = await updateDaily({ root, client: c, date: new Date('2026-11-02T01:00Z'), read: forbidden, analyze: forbidden, fetchFile: forbidden });
  assert.equal(value.count, 2);
  const state = JSON.parse(await readFile(path.join(root, 'state.json')));
  assert.equal(state.sourceMode, 'alphaxiv-links-v1');
  assert.equal(state.records[0].title, 'A Useful Paper & Its Evidence');
  assert.equal(state.records[0].sourceURLs[0], 'https://www.alphaxiv.org/abs/2401.12345');
  assert.ok(state.records.every(r => !r.analysisFolder && !r.imageFile && !r.abstract));
  assert.deepEqual((await readdir(value.folder)).sort(), ['batch.json', 'cards.json']);
  assert.equal(c.calls.filter(r => r.includes('format=full')).length, 1);
  assert.ok(c.calls.every(r => !r.includes('pageToken')));
  assert.match(await readFile(new URL('../src/daily-paper/cli.mjs', import.meta.url), 'utf8'), /import \{ updateDaily \} from '.\/links.mjs'/);
  assert.doesNotMatch(await readFile(new URL('../src/daily-paper/links.mjs', import.meta.url), 'utf8'), /import.*(?:model|pipeline|render|child_process)/);
});
test('newest mail change or account mismatch preserves the previous card set', async t => {
  const root = await fixture(t), c = client(); await updateDaily({ root, client: c });
  const before = await readFile(path.join(root, 'state.json'), 'utf8');
  c.id = 'new'; const call = c.call; let lists = 0;
  c.call = async route => { if (route.startsWith('/messages?') && ++lists === 2) c.id = 'newer'; return call(route); };
  await assert.rejects(updateDaily({ root, client: c }), /更新的分类邮件/);
  assert.equal(await readFile(path.join(root, 'state.json'), 'utf8'), before);
  c.call = async route => route === '/profile' ? { emailAddress: 'other@example.org' } : call(route);
  await assert.rejects(updateDaily({ root, client: c }), /账户/);
  assert.equal(await readFile(path.join(root, 'state.json'), 'utf8'), before);
});
test('successful link batch replaces only managed expired batches; cancellation and symlink roots are refused', async t => {
  const root = await fixture(t), key = 'a'.repeat(20) + '-20261101';
  const old = path.join(root, 'batches', key); await mkdir(old, { recursive: true });
  await writeFile(path.join(old, 'batch.json'), JSON.stringify({ kind: 'f-daily-paper-batch-v1', key }));
  await mkdir(path.join(root, 'batches', 'user-folder')); await writeFile(path.join(root, 'user.txt'), 'KEEP');
  await updateDaily({ root, client: client() });
  await assert.rejects(readdir(old), { code: 'ENOENT' });
  assert.deepEqual(await readdir(path.join(root, 'batches', 'user-folder')), []);
  assert.equal(await readFile(path.join(root, 'user.txt'), 'utf8'), 'KEEP');
  await assert.rejects(updateDaily({ root, client: client(), signal: AbortSignal.abort() }), /abort/i);
  const link = path.join(root, 'alias'); await symlink(root, link);
  await assert.rejects(updateDaily({ root: link, client: client() }), /符号链接/);
});
