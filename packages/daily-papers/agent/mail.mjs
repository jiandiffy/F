import { GmailClient } from '../../gmail/agent/client.mjs';
import { KeychainVault } from '../../gmail/agent/vault.mjs';
import { mailText, references, plainHTML } from './source.mjs';

export function mailCards(text) {
  const titles = new Map();
  for (const anchor of text.matchAll(/<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi)) {
    const ref = references(anchor[1])[0], title = plainHTML(anchor[2]).slice(0, 1200);
    if (ref && title.length > 12 && !/^(?:arxiv|https?:|view |read |pdf\b)/i.test(title) && !titles.has(ref.id)) titles.set(ref.id, title);
  }
  // Digest mails often put the title in the first table cell and link only
  // their PDF button. Read that inert text without loading the mail's HTML.
  for (const table of text.matchAll(/<table\b[^>]*>([\s\S]*?)<\/table>/gi)) {
    const refs = references(table[1]), cell = /<td\b[^>]*>([\s\S]*?)<\/td>/i.exec(table[1]);
    const title = cell ? plainHTML(cell[1]) : '';
    if (refs.length === 1 && title.length > 12 && title.length <= 1200 && !titles.has(refs[0].id)) titles.set(refs[0].id, title);
  }
  return references(text).slice(0, 2000).map(ref => ({ ...ref, title: titles.get(ref.id) ?? 'arXiv:' + ref.id }));
}

export function dailyClient(service = 'local.f.app.daily-paper.gmail') {
  const vault = new KeychainVault(service, 'desktop-oauth');
  // Bridge the existing readonly Swift credential format; no new authorization,
  // no account fallback and no credentials in argv/logs/files.
  const adapter = {
    async load() {
      const c = await vault.load();
      if (!c.client || !c.refreshToken) throw new Error('请先在 Daily Paper 设置中连接 Gmail（只读）');
      return { client: { client_id: c.client.clientID, ...(c.client.clientSecret ? { client_secret: c.client.clientSecret } : {}) }, tokens: { access_token: c.accessToken, refresh_token: c.refreshToken, expires_at: (Number(c.expiry) + 978307200) * 1000 } };
    },
    async save(value) {
      const old = await vault.load();
      if (old.refreshToken !== value.tokens.refresh_token || old.client?.clientID !== value.client.client_id) throw new Error('Daily Paper 连接已改变，请重试');
      await vault.save({ ...old, accessToken: value.tokens.access_token, refreshToken: value.tokens.refresh_token, expiry: value.tokens.expires_at / 1000 - 978307200 });
    }
  };
  return new GmailClient({ vault: adapter });
}
export async function latestMail(client, signal, body = true) {
  const labels = await client.call('/labels', { signal });
  const matches = (labels.labels ?? []).filter(l => /^daily\s*papers?$/i.test(l.name?.trim() ?? ''));
  if (matches.length !== 1) throw new Error('找不到唯一的 daily papers 分类，请检查 Gmail 标签');
  const label = matches[0];
  const page = await client.call('/messages?' + new URLSearchParams({ labelIds: label.id, maxResults: '1', includeSpamTrash: 'false' }), { signal });
  const id = page.messages?.[0]?.id;
  if (!id || !/^[\w-]+$/.test(id)) throw new Error('daily papers 分类内没有邮件；已保留当前论文');
  if (!body) return { id };
  const message = await client.call(`/messages/${id}?format=full`, { signal });
  if (!(message.labelIds ?? []).includes(label.id)) throw new Error('最新邮件已移出 daily papers 分类，请重试');
  const papers = mailCards(mailText(message.payload));
  if (!papers.length) throw new Error('最新一封邮件没有可识别的论文链接；已保留当前论文');
  const profile = await client.call('/profile', { signal });
  return { id, papers, account: profile.emailAddress, labelID: label.id, timestamp: Number(message.internalDate) / 1000 };
}
