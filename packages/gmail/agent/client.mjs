import { createServer } from 'node:http';
import { randomBytes, createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { KeychainVault, withAccountLock } from './vault.mjs';
import { compose, readMessage, summarize, replyAddress } from './mime.mjs';

const exec = promisify(execFile);
export const scope = 'https://www.googleapis.com/auth/gmail.modify';
const api = 'https://gmail.googleapis.com/gmail/v1/users/me';
const tokenURL = 'https://oauth2.googleapis.com/token';
const id = value => { if (typeof value !== 'string' || !/^[\w-]{1,256}$/.test(value)) throw new Error('无效的 Gmail 标识'); return value; };
export function desktopClient(value) {
  const client = value?.installed;
  if (!client || typeof client.client_id !== 'string' || !/^[\w.-]+\.apps\.googleusercontent\.com$/.test(client.client_id) || typeof client.client_secret !== 'string' || !client.client_secret || client.client_secret.length > 1024 || /[\x00-\x1f]/.test(client.client_secret)) throw new Error('请导入 Google Cloud 下载的「桌面应用」OAuth 客户端 JSON');
  // Ignore endpoints from imported JSON. Tokens only go to Google's fixed endpoint.
  return { client_id: client.client_id, client_secret: client.client_secret };
}
export class GmailClient {
  constructor({ vault = new KeychainVault(), request = fetch, openBrowser = url => exec('/usr/bin/open', [url]), oauthTimeout = 180000 } = {}) {
    this.vault = vault; this.request = request; this.openBrowser = openBrowser; this.oauthTimeout = oauthTimeout;
  }
  async json(url, options = {}, signal) {
    const combined = signal ? AbortSignal.any([signal, AbortSignal.timeout(30000)]) : AbortSignal.timeout(30000);
    let response;
    try { response = await this.request(url, { ...options, redirect: 'error', signal: combined }); }
    catch (e) { if (combined.aborted) throw new Error('Gmail 请求已取消或超时'); throw new Error('无法连接 Google，请检查网络或代理设置'); }
    let value;
    try { value = await response.json(); } catch {
      if (response.ok && url === 'https://oauth2.googleapis.com/revoke') return {};
      throw new Error(`Google 返回了无效响应（${response.status}）`);
    }
    if (!response.ok) {
      if (value.error === 'invalid_grant') throw new Error('Gmail 授权已失效，请重新连接 Google 账号');
      const reason = value.error?.errors?.[0]?.reason ?? (typeof value.error === 'string' ? value.error : value.error?.status);
      const known = { accessNotConfigured: '请先在 Google Cloud 项目中启用 Gmail API', insufficientPermissions: 'Gmail 权限不足，请重新授权', rateLimitExceeded: 'Google 请求过于频繁，请稍后重试', dailyLimitExceeded: 'Gmail 今日配额已用完' };
      throw new Error(known[reason] ?? `Google 请求失败（${response.status}${/^[\w.-]{1,80}$/.test(reason ?? '') ? '，' + reason : ''}）`);
    }
    return value;
  }
  async token(fields, signal) {
    return this.json(tokenURL, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(fields) }, signal);
  }
  async status() {
    const saved = await this.vault.load();
    return { configured: !!saved.client, connected: !!saved.tokens?.refresh_token, email: saved.email ?? null };
  }
  async configure(value) {
    const client = desktopClient(value), saved = await this.vault.load();
    if (saved.client?.client_id !== client.client_id && saved.tokens) throw new Error('请先断开当前 Gmail 账号，再导入其他客户端');
    await this.vault.save({ ...saved, client });
    return this.status();
  }
  async connect(signal) {
    const saved = await this.vault.load();
    if (!saved.client) throw new Error('请先导入 OAuth 客户端 JSON');
    const state = randomBytes(32).toString('base64url'), verifier = randomBytes(48).toString('base64url');
    const challenge = createHash('sha256').update(verifier).digest('base64url');
    let redirect, resolveCode, rejectCode, timer;
    const code = new Promise((resolve, reject) => { resolveCode = resolve; rejectCode = reject; });
    // Attach rejection handling before browser launch can fail.
    code.catch(() => {});
    const server = createServer((req, res) => {
      const url = new URL(req.url, redirect);
      res.setHeader('Content-Type', 'text/plain; charset=utf-8'); res.setHeader('Cache-Control', 'no-store');
      if (req.method !== 'GET' || url.pathname !== '/oauth2callback' || url.searchParams.get('state') !== state) { res.writeHead(400).end('无效的授权回调'); return; }
      if (url.searchParams.get('error')) { res.end('未完成授权，请返回 F。'); rejectCode(new Error('Google 授权已取消')); return; }
      const value = url.searchParams.get('code');
      if (!value) { res.writeHead(400).end('缺少授权码'); return; }
      res.end('授权已收到，请返回 F。'); resolveCode(value);
    });
    const abort = () => rejectCode(new Error('Google 授权已取消'));
    try {
      signal?.throwIfAborted();
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
      redirect = `http://127.0.0.1:${server.address().port}/oauth2callback`;
      timer = setTimeout(() => rejectCode(new Error('Google 授权超时，请重试')), this.oauthTimeout);
      signal?.addEventListener('abort', abort, { once: true });
      signal?.throwIfAborted();
      const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
      url.search = new URLSearchParams({ client_id: saved.client.client_id, redirect_uri: redirect, response_type: 'code', scope,
        state, code_challenge: challenge, code_challenge_method: 'S256', access_type: 'offline', prompt: 'consent select_account' });
      await this.openBrowser(url.href);
      const tokens = await this.token({ ...saved.client, code: await code, code_verifier: verifier, redirect_uri: redirect, grant_type: 'authorization_code' }, signal);
      if (!tokens.refresh_token || !tokens.access_token || (tokens.scope && !tokens.scope.split(' ').includes(scope))) throw new Error('Google 未授予完整 Gmail 权限，请重新授权');
      // Validate the mailbox before replacing any existing account.
      const profile = await this.json(api + '/profile', { headers: { Authorization: `Bearer ${tokens.access_token}` } }, signal);
      await this.vault.save({ client: saved.client, email: profile.emailAddress, tokens: { ...tokens, expires_at: Date.now() + (tokens.expires_in ?? 3600) * 1000 } });
      return { connected: true, email: profile.emailAddress };
    } finally {
      clearTimeout(timer); signal?.removeEventListener('abort', abort); server.closeAllConnections(); server.close();
    }
  }
  async access(signal, force = false) {
    const saved = await this.vault.load();
    if (!saved.client || !saved.tokens?.refresh_token) throw new Error('请在「应用 → Gmail → 设置」连接 Google 账号');
    if (force || !saved.tokens.access_token || !Number.isFinite(saved.tokens.expires_at) || saved.tokens.expires_at < Date.now() + 60000) {
      const refreshed = await this.token({ ...saved.client, refresh_token: saved.tokens.refresh_token, grant_type: 'refresh_token' }, signal);
      if (!refreshed.access_token) throw new Error('Google 未返回访问令牌，请重新连接账号');
      saved.tokens = { ...saved.tokens, ...refreshed, expires_at: Date.now() + (refreshed.expires_in ?? 3600) * 1000 };
      await this.vault.save(saved);
    }
    return saved;
  }
  async call(route, { method = 'GET', body, signal } = {}) {
    const saved = await this.access(signal);
    // Do not automatically replay writes: an ambiguous send timeout could duplicate mail.
    try { return await this.json(api + route, { method, headers: { Authorization: `Bearer ${saved.tokens.access_token}`, 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }, signal); }
    catch (e) {
      if (method !== 'GET' || !/（401/.test(e.message)) throw e;
      const fresh = await this.access(signal, true);
      return this.json(api + route, { headers: { Authorization: `Bearer ${fresh.tokens.access_token}` } }, signal);
    }
  }
  async search({ query = 'in:inbox', pageToken, limit = 25, signal } = {}) {
    if (!Number.isInteger(limit) || limit < 1 || limit > 50 || query.length > 2000) throw new Error('每页邮件数量须为 1–50');
    const params = new URLSearchParams({ q: query, maxResults: String(limit) });
    if (pageToken) params.set('pageToken', pageToken);
    const list = await this.call('/messages?' + params, { signal });
    const messages = [];
    // Bounded parallel reads preserve ordering and limit API concurrency.
    for (let i = 0; i < (list.messages?.length ?? 0); i += 5) {
      messages.push(...await Promise.all(list.messages.slice(i, i + 5).map(async m => summarize(await this.call(`/messages/${id(m.id)}?format=metadata`, { signal })))));
    }
    return { messages, nextPageToken: list.nextPageToken ?? null, resultSizeEstimate: list.resultSizeEstimate ?? messages.length };
  }
  async read(messageId, signal) { return readMessage(await this.call(`/messages/${id(messageId)}?format=full`, { signal })); }
  async send(input, signal, draft = false) {
    const saved = await this.access(signal);
    let fields = { ...input, from: saved.email }, threadId;
    if (input.replyToId) {
      const original = await this.read(input.replyToId, signal);
      if (!original.messageId) throw new Error('原邮件缺少 Message-ID，无法关联回复');
      const references = [...(original.references.match(/<[^<>\s]+>/g) ?? []).slice(-8), original.messageId].join(' ');
      fields = { ...fields, to: replyAddress(original.replyTo || original.from), subject: original.subject,
        inReplyTo: original.messageId, references };
      threadId = original.threadId;
    }
    const message = { raw: compose(fields), ...(threadId ? { threadId } : {}) };
    const response = await this.call(draft ? '/drafts' : '/messages/send', { method: 'POST', body: draft ? { message } : message, signal });
    return { id: response.id, threadId: response.threadId ?? response.message?.threadId, ...(draft ? { draft: true } : { sent: true }) };
  }
  async modify(input, signal) {
    const addLabelIds = input.addLabelIds ?? [], removeLabelIds = input.removeLabelIds ?? [];
    if (![addLabelIds,removeLabelIds].every(a => Array.isArray(a) && a.length <= 50 && a.every(v => typeof v === 'string' && /^[\w-]{1,256}$/.test(v)))) throw new Error('无效的邮件标签');
    return this.call(`/messages/${id(input.id)}/modify`, { method: 'POST', body: { addLabelIds, removeLabelIds }, signal });
  }
  async disconnect(signal, localOnly = false) {
    const saved = await this.vault.load();
    if (!localOnly && saved.tokens?.refresh_token) await this.json('https://oauth2.googleapis.com/revoke', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ token: saved.tokens.refresh_token }) }, signal);
    await this.vault.save(saved.client ? { client: saved.client } : {});
    return { connected: false, revoked: !localOnly };
  }
  async run(input, signal) {
    switch (input.action) {
      case 'status': return this.status();
      case 'configure': return this.configure(input.client);
      case 'connect': return this.connect(signal);
      case 'disconnect': return this.disconnect(signal, input.localOnly === true);
      case 'search': return this.search({ ...input, signal });
      case 'read': return this.read(input.id, signal);
      case 'send': case 'reply': case 'draft':
        if (input.action === 'reply' && !input.replyToId) throw new Error('回复需要 replyToId');
        return this.send(input, signal, input.action === 'draft');
      case 'modify': return this.modify(input, signal);
      case 'labels': return this.call('/labels', { signal });
      default: throw new Error('未知的 Gmail 操作');
    }
  }
}
export function runGmail(input, signal) { return withAccountLock(() => new GmailClient().run(input, signal), { signal }); }
