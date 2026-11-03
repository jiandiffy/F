import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir, readdir, symlink, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { latestMail } from '../src/daily-paper/mail.mjs';
import { references, sourceURL, download, mediaFromHTML, videosFromHTML, readPaper, validImage, validVideo, plainHTML } from '../src/daily-paper/source.mjs';
import { validateAnalysis, analyzePaper, modelID } from '../src/daily-paper/model.mjs';
import { renderAnalysis } from '../src/daily-paper/render.mjs';
import { updateDaily, dayInShanghai } from '../src/daily-paper/pipeline.mjs';

const analysis = title => ({ title, summary: '中文总览', sections: ['问题','方法','证据','局限','结论'].map(title => ({ title, paragraphs: ['有来源的分析段落'], media: [] })) });
function client(ids = ['2401.12345', '2401.12346']) {
  const c = { calls: [], id: 'newest', async call(route) {
    c.calls.push(route);
    if (route === '/labels') return { labels: [{ id: 'P', name: 'daily papers' }, { id: 'OTHER', name: 'unrelated' }] };
    if (route.startsWith('/messages?')) { const q = new URLSearchParams(route.split('?')[1]); assert.equal(q.get('maxResults'), '1'); assert.equal(q.get('labelIds'), 'P'); return { messages: [{ id: c.id }], nextPageToken: 'DO_NOT_FETCH' }; }
    if (route === '/profile') return { emailAddress: 'fixture@example.org' };
    if (route === `/messages/${c.id}?format=full`) return { labelIds: ['P'], internalDate: '1700000000000', payload: { mimeType: 'text/html', body: { data: Buffer.from(ids.map(id => `<a href="https://arxiv.org/abs/${id}">paper</a>`).join('')).toString('base64url') } } };
    throw new Error('Unexpected request: ' + route);
  } };return c;
}
const paper = async ref => ({ ref, text: '论文全文'.repeat(1000), overview: 'alphaXiv 参考', origin: 'https://www.alphaxiv.org/abs/' + ref.id + '.md', media: [], paperURL: 'https://arxiv.org/pdf/' + ref.id, alphaURL: 'https://www.alphaxiv.org/overview/' + ref.id });
const fetchFile = async () => { throw new Error('Fixture: PDF unavailable'); };
async function fixture(t) { const root = await mkdtemp(path.join(os.tmpdir(), 'f-daily-latest-')); t.after(() => rm(root, { recursive: true, force: true })); return root; }

test('classification reads exactly the latest mail and retains inert HTML links', async () => {
  const c = client(); const m = await latestMail(c);
  assert.equal(m.id, 'newest'); assert.equal(m.papers.length, 2);
  assert.equal(c.calls.filter(r => r.includes('format=full')).length, 1);
  assert.ok(c.calls.every(r => !r.includes('pageToken')));
  assert.deepEqual(references('https://alphaxiv.org/overview/2401.12345 doi:10.48550/arxiv.2401.12345v2'), [{ id: '2401.12345', version: '' }]);
});
test('unavailable classification never falls back to a sender or whole mailbox', async () => {
  await assert.rejects(latestMail({ call: async () => ({ labels: [{ id: 'X', name: 'Inbox' }] }) }), /daily papers/);
});
test('only readable papers are committed; all analysis completes before expired batches are deleted', async t => {
  const root = await fixture(t), c = client(); let calls = 0;
  const first = await updateDaily({ root, client: c, date: new Date('2026-11-01T01:00Z'), read: paper, fetchFile, analyze: async p => { calls++; return analysis(p.ref.id); } });
  assert.equal(first.count, 2); const old = JSON.parse(await readFile(path.join(root, 'state.json')));
  const oldFolder = path.join(root, 'batches', old.currentBatch);
  c.id = 'newer';
  const second = await updateDaily({ root, client: c, date: new Date('2026-11-02T01:00Z'), read: async ref => { if (ref.id.endsWith('6')) throw Error('Unreadable'); return paper(ref); }, fetchFile, analyze: async p => { assert.ok((await readdir(oldFolder)).length); return analysis(p.ref.id); } });
  assert.equal(second.count, 1); assert.equal(second.skipped, 1);
  await assert.rejects(readdir(oldFolder), { code: 'ENOENT' });
  const state = JSON.parse(await readFile(path.join(root, 'state.json'))); assert.equal(state.records.length, 1); assert.equal(state.pendingMessageIDs.length, 0);
  const file = path.join(root, state.records[0].analysisFolder, 'index.html'); assert.match(await readFile(file, 'utf8'), /中文总览/);
  assert.equal(calls, 2);
});
test('analysis failure preserves old state and resumes completed papers on the next attempt', async t => {
  const root = await fixture(t), c = client();
  const old = { schema: 1, settings: {}, account: '', records: [{ id: 'old' }] };
  await writeFile(path.join(root, 'state.json'), JSON.stringify(old)); let fail = true, completed = 0;
  const options = { root, client: c, date: new Date('2026-11-02T01:00Z'), concurrency: 1, read: paper, fetchFile, analyze: async p => { if (p.ref.id.endsWith('6') && fail) throw Error('Model failed'); completed++; return analysis(p.ref.id); } };
  await assert.rejects(updateDaily(options), /Model failed/);
  assert.deepEqual(JSON.parse(await readFile(path.join(root, 'state.json'))), old);
  fail = false; const result = await updateDaily(options); assert.equal(result.count, 2); assert.equal(completed, 2);
});
test('new mail appearing during analysis cannot replace current state', async t => {
  const root = await fixture(t), c = client(['2401.12345']);
  await assert.rejects(updateDaily({ root, client: c, read: paper, fetchFile, analyze: async p => { c.id = 'arrived'; return analysis(p.ref.id); } }), /更新的分类邮件/);
  await assert.rejects(readFile(path.join(root, 'state.json')), { code: 'ENOENT' });
});
test('no readable papers, invalid analyses, cancellation and symlink roots preserve user files', async t => {
  const root = await fixture(t); await writeFile(path.join(root, 'user.txt'), 'KEEP');
  await assert.rejects(updateDaily({ root, client: client(), read: async () => { throw Error('No full text'); }, fetchFile }), /没有能实际读取/);
  await assert.rejects(updateDaily({ root, client: client(), read: paper, fetchFile, analyze: async () => ({ title: 'incomplete' }) }), /完整/);
  const signal = AbortSignal.abort(); await assert.rejects(updateDaily({ root, client: client(), signal }), /abort/i);
  const linked = path.join(root, 'link'); await symlink(root, linked); await assert.rejects(updateDaily({ root: linked, client: client() }), /符号链接/);
  assert.equal(await readFile(path.join(root, 'user.txt'), 'utf8'), 'KEEP');
});
test('source transport enforces HTTPS, host, redirect and streaming size limits', async () => {
  assert.equal(sourceURL('http://arxiv.org/a'), null); assert.equal(sourceURL('https://arxiv.org.evil/a'), null); assert.equal(sourceURL('https://127.0.0.1/a', { project: true }), null);
  assert.ok(sourceURL('https://real-paper.github.io/demo.mp4', { project: true }));
  await assert.rejects(download('https://arxiv.org/a', { limit: 2, request: async () => new Response('oversized') }), /大小/);
  await assert.rejects(download('https://arxiv.org/a', { request: async () => new Response(null, { status: 302, headers: { location: 'https://evil.invalid/a' } }) }), /跨主机/);
  const figures = mediaFromHTML('<figure><img src="x.png"><figcaption>Figure 1 evidence</figcaption></figure><figure><img src="https://evil.invalid/track.png"></figure>', 'https://arxiv.org/html/2401.12345');
  assert.equal(figures.length, 1); assert.equal(figures[0].caption, 'Figure 1 evidence');
  assert.equal(mediaFromHTML('<figure><img src="2401.12345/figures/teaser.png"></figure>', 'https://arxiv.org/html/2401.12345')[0].url, 'https://arxiv.org/html/2401.12345/figures/teaser.png');
  assert.equal(videosFromHTML('<source src="demo.mp4"><iframe src="x"></iframe>', 'https://paper.github.io/').length, 1);
});
test('full text is required and image pixel limits reject decompression bombs', async () => {
  await assert.rejects(readPaper({ id: '2401.12345', version: '' }, { request: async () => new Response('<html>login</html>', { headers: { 'content-type': 'text/html' } }) }), /正文/);
  const png = Buffer.alloc(24); Buffer.from([137,80,78,71,13,10,26,10]).copy(png);png.writeUInt32BE(500, 16);png.writeUInt32BE(500, 20);
  assert.equal(validImage(png, 'image/png'), true);png.writeUInt32BE(100000, 16);assert.equal(validImage(png, 'image/png'), false);
  assert.equal(validVideo(Buffer.from('<html>proxy error</html>'), 'video/mp4'), false);
  assert.equal(plainHTML('<math><mi>x</mi><annotation encoding="application/x-tex">\\duplicate</annotation></math>'), 'x');
});
test('versioned full text cannot silently substitute a newer paper revision', async () => {
  const ref = { id: '2401.12345', version: 'v1' }, requests = [];
  const p = await readPaper(ref, { request: async url => {
    requests.push(url);
    if (url.includes('/abs/')) return new Response('arXiv:2401.12345v2 Abstract Introduction ' + 'newer version '.repeat(200), { headers: { 'content-type': 'text/markdown' } });
    if (url.includes('/html/')) return new Response('<article>Abstract Introduction ' + 'correct v1 body '.repeat(200) + '</article>', { headers: { 'content-type': 'text/html' } });
    return new Response('', { status: 404 });
  } });
  assert.equal(p.origin, 'https://arxiv.org/html/2401.12345v1'); assert.ok(!p.text.includes('newer version')); assert.ok(requests.some(u => u.endsWith('2401.12345v1.md')));
});
test('analysis HTML escapes model/source data and never executes scripts, iframes or autoplay', async () => {
  const p = await paper({ id: '2401.12345' });p.media = [{ id: 'm1', kind: 'video', file: 'media-1.mp4', caption: '<script>BAD</script>', url: 'https://paper.github.io/demo.mp4' }];
  const a = analysis('<script>BAD</script>');a.sections[0].media = ['m1'];
  const html = renderAnalysis(validateAnalysis(a, p.media), p, '2026-11-02');
  assert.ok(!/<script|<iframe|autoplay/i.test(html));assert.match(html, /&lt;script&gt;/);assert.match(html, /preload="none"/);assert.match(html, /Content-Security-Policy/);
  a.sections[0].media = ['invented'];assert.throws(() => validateAnalysis(a, p.media), /不存在/);
  assert.equal(dayInShanghai(new Date('2026-11-01T17:30Z')), '2026-11-02');
});
test('text-only model repairs invalid structure once and refuses an incorrect provider', async () => {
  const p = await paper({ id: '2401.12345' }); let calls = 0, disposed = false;
  const rpcFactory = (_pi, args) => {
    assert.ok(args.includes('--no-tools') && args.includes('--no-mcp') && args.includes('--no-context-files'));
    return { request: async () => ({ model: { provider: 'cbi', id: modelID } }), prompt: async () => ({ stopReason: 'completed', output: [{ type: 'text', text: calls++ === 0 ? '{"title":"incomplete"}' : JSON.stringify(analysis('Repaired')) }] }), dispose: async () => { disposed = true; } };
  };
  assert.equal((await analyzePaper(p, { pi: '/fixture/pi/bin/pi', cwd: '/tmp', rpcFactory })).title, 'Repaired');
  assert.equal(calls, 2); assert.equal(disposed, true);
  await assert.rejects(analyzePaper(p, { pi: '/fixture/pi/bin/pi', rpcFactory: () => ({ request: async () => ({ model: { provider: 'other', id: modelID } }), dispose: async () => {} }) }), /指定/);
});
