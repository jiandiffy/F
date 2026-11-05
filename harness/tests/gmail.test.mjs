import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { GmailClient, desktopClient, scope } from '../src/gmail/client.mjs';
import { compose, readMessage, decodeHeader } from '../src/gmail/mime.mjs';
import { KeychainVault, withAccountLock } from '../src/gmail/vault.mjs';
import { mountGmail } from '../src/gmail/index.mjs';
import { createKernel } from '../src/core/kernel.mjs';

const client = { client_id: 'fixture.apps.googleusercontent.com', client_secret: 'fixture-client-secret' };
function fixture() {
  let value = { client, email: 'owner@example.com', tokens: { access_token: 'fixture-access', refresh_token: 'fixture-refresh', expires_at: Date.now() + 3600000 } };
  return { load: async () => structuredClone(value), save: async next => { value = structuredClone(next); } };
}
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
const message = { id: 'abc123', threadId: 'thread123', labelIds: ['INBOX','UNREAD'], payload: { mimeType: 'multipart/mixed', headers: [
  { name: 'From', value: 'Alice <alice@example.com>' }, { name: 'Reply-To', value: 'Reply <reply@example.com>' },
  { name: 'Subject', value: '=?UTF-8?B?5Lit5paH6YKu5Lu2?=' }, { name: 'Message-ID', value: '<original@example.com>' },
], parts: [ { mimeType: 'multipart/alternative', parts: [
  { mimeType: 'text/plain', body: { data: Buffer.from('你好\n正文').toString('base64url') } },
  { mimeType: 'text/html', body: { data: Buffer.from('<p>你好</p><img src="https://tracker.invalid">').toString('base64url') } },
] }, { filename: '附件.pdf', mimeType: 'application/pdf', body: { attachmentId: 'attachment123', size: 123 } }] } };

test('Gmail MIME handles nested Unicode bodies, encoded headers and attachments without loading HTML', () => {
  const parsed = readMessage(message);
  assert.equal(parsed.subject, '中文邮件'); assert.equal(parsed.text, '你好\n正文'); assert.equal(parsed.unread, true);
  assert.equal(parsed.attachments[0].filename, '附件.pdf');
  const html = readMessage({ payload: { mimeType: 'text/html', body: { data: Buffer.from('<script>send()</script><p>Hi &amp; &#x4e2d;</p><img src="https://tracker.invalid">').toString('base64url') } } });
  assert.match(html.text, /Hi & 中/); assert.doesNotMatch(html.text, /send|tracker/);
});

test('Gmail outgoing MIME folds Chinese subject, preserves newlines, rejects header injection and requires recipients', () => {
  const raw = Buffer.from(compose({ from: 'owner@example.com', to: 'alice@example.com, bob@example.com', cc: 'cc@example.com', bcc: 'hidden@example.com', subject: '中文主题'.repeat(20), body: '第一行\n第二行' }), 'base64url').toString();
  const [headers, body] = raw.split('\r\n\r\n');
  assert.match(headers, /Bcc: hidden@example.com/); assert.equal(Buffer.from(body, 'base64').toString(), '第一行\r\n第二行');
  const subject = /Subject: ([\s\S]*?)\r\nDate:/.exec(headers)[1];
  assert.equal(decodeHeader(subject), '中文主题'.repeat(20)); assert(headers.split('\r\n').every(line => line.length <= 998));
  for (const values of [{ to: 'a@example.com\r\nBcc: bad@example.com' }, { subject: 'x\nBcc: bad@example.com' }, { to: '' }, { body: '' }]) {
    assert.throws(() => compose({ from: 'owner@example.com', to: 'alice@example.com', body: 'hi', ...values }));
  }
});

test('Gmail search pagination, full read, labels, archives, draft and threaded reply reach correct REST endpoints', async () => {
  const calls = [], vault = fixture();
  const gmail = new GmailClient({ vault, request: async (url, options) => {
    calls.push({ url, options }); assert.equal(options.headers.Authorization, 'Bearer fixture-access');
    if (url.includes('/messages?')) return json({ messages: [{ id: 'abc123' }], nextPageToken: 'next-token' });
    if (url.endsWith('/messages/abc123?format=metadata') || url.endsWith('/messages/abc123?format=full')) return json(message);
    if (url.endsWith('/labels')) return json({ labels: [{ id: 'INBOX', name: 'INBOX' }] });
    if (url.endsWith('/drafts')) return json({ id: 'draft123', message: { threadId: 'thread123' } });
    return json({ id: 'sent123', threadId: 'thread123' });
  }});
  const results = await gmail.run({ action: 'search', query: 'is:unread 中文', limit: 5, pageToken: 'page+token' });
  assert.equal(results.messages[0].subject, '中文邮件'); assert.equal(results.nextPageToken, 'next-token');
  assert.equal(new URL(calls[0].url).searchParams.get('pageToken'), 'page+token');
  assert.equal((await gmail.run({ action: 'read', id: 'abc123' })).text, '你好\n正文');
  assert.equal((await gmail.run({ action: 'reply', replyToId: 'abc123', body: '回复内容' })).sent, true);
  const sent = JSON.parse(calls.at(-1).options.body), raw = Buffer.from(sent.raw, 'base64url').toString();
  assert.equal(sent.threadId, 'thread123'); assert.match(raw, /To: reply@example.com/); assert.match(raw, /In-Reply-To: <original@example.com>/);
  assert.match(raw, /References: <original@example.com>/); assert.equal(decodeHeader(/Subject: (.*)\r/.exec(raw)[1]), '中文邮件');
  await gmail.run({ action: 'draft', to: 'alice@example.com', body: 'later' }); assert.equal(calls.at(-1).url.endsWith('/drafts'), true);
  await gmail.run({ action: 'modify', id: 'abc123', removeLabelIds: ['INBOX','UNREAD'] });
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), { addLabelIds: [], removeLabelIds: ['INBOX','UNREAD'] });
  await gmail.run({ action: 'labels' }); assert(calls.at(-1).url.endsWith('/labels'));
  await assert.rejects(gmail.read('../profile'), /标识/);
});

test('Gmail refresh preserves refresh tokens, only retries unauthorized reads, never replays sends, sanitizes upstream secrets', async () => {
  const vault = fixture(); let saved = await vault.load(); saved.tokens.expires_at = 0; await vault.save(saved);
  let refreshes = 0, sends = 0;
  const gmail = new GmailClient({ vault, request: async (url, options) => {
    if (url.endsWith('/token')) { refreshes++; assert.equal(options.body.get('grant_type'), 'refresh_token'); return json({ access_token: 'refreshed', expires_in: 3600 }); }
    if (url.endsWith('/messages/send')) { sends++; return json({ error: { message: 'fixture-secret-should-never-appear' } }, 503); }
    return json({});
  }});
  await gmail.access(); assert.equal(refreshes, 1); assert.equal((await vault.load()).tokens.refresh_token, 'fixture-refresh');
  await assert.rejects(gmail.send({ to: 'alice@example.com', body: 'hello' }), e => !e.message.includes('fixture-secret') && e.message.includes('503')); assert.equal(sends, 1);
  let reads = 0;
  gmail.request = async url => url.endsWith('/token') ? json({ access_token: 'new' }) : (++reads === 1 ? json({ error: {} }, 401) : json(message));
  await gmail.read('abc123'); assert.equal(reads, 2);
  gmail.request = async () => json({ error: 'invalid_grant' }, 400);
  await assert.rejects(gmail.access(undefined, true), /授权已失效/);
});

test('Gmail desktop OAuth checks state and PKCE, validates scope and mailbox, and cleans callback listener', async () => {
  const vault = fixture(); await vault.save({ client });
  let verifierChallenge, redirect, state;
  const gmail = new GmailClient({ vault, request: async (url, options) => {
    if (url.endsWith('/token')) {
      assert.equal(createHash('sha256').update(options.body.get('code_verifier')).digest('base64url'), verifierChallenge);
      assert.equal(options.body.get('redirect_uri'), redirect); assert.equal(options.body.get('code'), 'test-code');
      return json({ access_token: 'access', refresh_token: 'refresh', scope, expires_in: 3600 });
    }
    return json({ emailAddress: 'owner@example.com' });
  }, openBrowser: async value => {
    const url = new URL(value); assert.equal(url.origin, 'https://accounts.google.com');
    assert.equal(url.searchParams.get('code_challenge_method'), 'S256'); assert.equal(url.searchParams.get('scope'), scope);
    verifierChallenge = url.searchParams.get('code_challenge'); redirect = url.searchParams.get('redirect_uri'); state = url.searchParams.get('state');
    const bad = await fetch(redirect + '?state=wrong&code=evil'); assert.equal(bad.status, 400);
    const response = await fetch(redirect + '?' + new URLSearchParams({ state, code: 'test-code' })); assert.equal(response.status, 200);
  }});
  assert.deepEqual(await gmail.connect(), { connected: true, email: 'owner@example.com' });
  await assert.rejects(fetch(redirect));
  assert.equal((await gmail.status()).connected, true); assert(!JSON.stringify(await gmail.status()).includes('refresh'));
  assert.throws(() => desktopClient({ web: client }), /桌面应用/);
  assert.deepEqual(desktopClient({ installed: { ...client, token_uri: 'https://evil.invalid' } }), client);
});

test('Gmail canceled and timed out OAuth preserve existing account; revoke empty success clears tokens', async () => {
  for (const cancel of [true, false]) {
    const vault = fixture(), before = await vault.load();
    const gmail = new GmailClient({ vault, oauthTimeout: 50, openBrowser: async value => {
      if (cancel) { const url = new URL(value); await fetch(url.searchParams.get('redirect_uri') + '?' + new URLSearchParams({ state: url.searchParams.get('state'), error: 'access_denied' })); }
    }});
    await assert.rejects(gmail.connect(), cancel ? /取消/ : /超时/); assert.deepEqual(await vault.load(), before);
  }
  const vault = fixture(), gmail = new GmailClient({ vault, request: async () => new Response('', { status: 200 }) });
  await gmail.disconnect(); assert.deepEqual(await vault.load(), { client });
  await vault.save({ client, tokens: { refresh_token: 'fixture' } });
  gmail.request = async () => { throw new Error('must not contact Google for local disconnect'); };
  assert.deepEqual(await gmail.run({ action: 'disconnect', localOnly: true }), { connected: false, revoked: false });
  assert.deepEqual(await vault.load(), { client });
});

test('Gmail account lock serializes concurrent conversations, respects abort and recovers dead owners', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'f-gmail-lock-')), order = [];
  try {
    let entered; const ready = new Promise(resolve => { entered = resolve; });
    const first = withAccountLock(async () => { order.push('start'); entered(); await new Promise(r => setTimeout(r, 120)); order.push('finish'); }, { directory });
    await ready;
    await Promise.all([first, withAccountLock(async () => { order.push('second'); }, { directory })]);
    assert.deepEqual(order, ['start','finish','second']);
    await writeFile(path.join(directory, 'account.lock'), '2147483647');
    await withAccountLock(async () => order.push('recovered'), { directory });
    await assert.rejects(readFile(path.join(directory, 'account.lock')), { code: 'ENOENT' });
    const controller = new AbortController(); controller.abort();
    await assert.rejects(withAccountLock(async () => {}, { directory, signal: controller.signal }));
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('Gmail Cordis registration unloads tools and prompt with scope; account configuration is never an Agent action', async () => {
  const tools = new Map(), active = new Set();
  const pi = { registerTool: tool => { tools.set(tool.name, tool); active.add(tool.name); }, getActiveTools: () => [...active], setActiveTools: names => { active.clear(); names.forEach(n => active.add(n)); } };
  const ctx = createKernel(pi); await mountGmail(ctx, { run: async input => ({ action: input.action }) });
  assert.equal(tools.get('gmail').capability.name, 'gmail');
  assert.equal((await tools.get('gmail').execute('', { action: 'status' })).details.action, 'status');
  await assert.rejects(tools.get('gmail').execute('', { action: 'connect' }), /应用菜单/);
  await ctx.fiber.dispose(); assert(!active.has('gmail'));
  assert.throws(() => tools.get('gmail').execute('', { action: 'status' }), /unloaded/);
});

test('Gmail actual macOS Keychain round-trip uses an isolated fixture item and does not expose tokens in argv', { skip: process.platform !== 'darwin' }, async () => {
  const service = 'local.f.gmail.fixture.' + randomUUID(), vault = new KeychainVault(service);
  const value = { client, tokens: { refresh_token: 'fixture\\with"quotes\n中文' } };
  try {
    assert.deepEqual(await vault.load(), {}); await vault.save(value); assert.deepEqual(await vault.load(), value);
    await vault.save({ client }); assert.deepEqual(await vault.load(), { client });
  } finally { await promisify(execFile)('/usr/bin/security', ['delete-generic-password', '-s', service, '-a', 'primary']).catch(e => { if (e.code !== 44) throw e; }); }
});
