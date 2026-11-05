import { randomUUID } from 'node:crypto';

export function header(message, name) {
  return (message.payload?.headers?.find(h => h.name.toLowerCase() === name.toLowerCase())?.value ?? '').replace(/\r?\n[ \t]+/g, ' ');
}
function decode(data, contentType = '') {
  const charset = /charset\s*=\s*["']?([^\s;"']+)/i.exec(contentType)?.[1] ?? 'utf-8';
  const bytes = Buffer.from(data ?? '', 'base64url');
  try { return new TextDecoder(charset).decode(bytes); } catch { return bytes.toString('utf8'); }
}
export function decodeHeader(value) {
  return value.replace(/\?=\s+(?==\?)/g, '?=').replace(/=\?([^?]+)\?([bq])\?([^?]*)\?=/gi, (_, charset, kind, text) => {
    const bytes = kind.toLowerCase() === 'b' ? Buffer.from(text, 'base64') : Buffer.from(text.replaceAll('_', ' ').replace(/=([0-9a-f]{2})/gi, (_, h) => String.fromCharCode(parseInt(h, 16))), 'latin1');
    try { return new TextDecoder(charset).decode(bytes); } catch { return bytes.toString('utf8'); }
  });
}
export function summarize(message) {
  return { id: message.id, threadId: message.threadId, subject: decodeHeader(header(message, 'Subject')),
    from: decodeHeader(header(message, 'From')), to: decodeHeader(header(message, 'To')),
    replyTo: header(message, 'Reply-To'), date: header(message, 'Date'), snippet: message.snippet ?? '',
    unread: (message.labelIds ?? []).includes('UNREAD'), labelIds: message.labelIds ?? [] };
}
export function readMessage(message) {
  const plain = [], html = [], attachments = [];
  function visit(part) {
    if (!part) return;
    if (part.filename || part.body?.attachmentId) {
      attachments.push({ filename: part.filename ?? '', mimeType: part.mimeType, size: part.body?.size ?? 0, attachmentId: part.body?.attachmentId });
      return;
    }
    if (part.body?.data) {
      const contentType = part.headers?.find(h => h.name.toLowerCase() === 'content-type')?.value;
      if (part.mimeType === 'text/plain') plain.push(decode(part.body.data, contentType));
      if (part.mimeType === 'text/html') html.push(decode(part.body.data, contentType));
    }
    for (const child of part.parts ?? []) visit(child);
  }
  visit(message.payload);
  const fallback = html.join('\n').replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '').replace(/<\/?(?:p|div|br|li|tr|h[1-6])\b[^>]*>/gi, '\n').replace(/<[^>]*>/g, '').replace(/&(?:amp|lt|gt|quot|apos|nbsp);/g, x => ({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&apos;':"'",'&nbsp;':' '})[x]).replace(/&#(x[0-9a-f]+|\d+);/gi, (_, n) => { const code = n[0].toLowerCase() === 'x' ? parseInt(n.slice(1),16) : Number(n); return code <= 0x10ffff ? String.fromCodePoint(code) : ''; });
  return { ...summarize(message), messageId: header(message, 'Message-ID'), references: header(message, 'References'),
    text: plain.length ? plain.join('\n') : fallback, attachments };
}
function line(value, name) {
  if (typeof value !== 'string' || /[\r\n\x00-\x1f\x7f]/.test(value) || value.length > 900) throw new Error(`无效的 ${name}`);
  return value;
}
export function addresses(value, required = false) {
  const values = Array.isArray(value) ? value : (value ?? '').split(',');
  const result = values.map(v => line(v, '邮件地址').trim()).filter(Boolean);
  if (required && !result.length) throw new Error('请输入收件人');
  if (result.length > 50 || result.some(v => !/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(v))) throw new Error('请使用以逗号分隔的邮箱地址');
  return result.join(', ');
}
export function replyAddress(value) {
  return addresses(/<([^<>]+)>/.exec(value)?.[1] ?? value, true);
}
export function compose({ from, to, cc, bcc, subject = '', body, inReplyTo, references }) {
  if (typeof body !== 'string' || !body.trim() || Buffer.byteLength(body) > 5_000_000) throw new Error('邮件正文不能为空，且不能超过 5 MB');
  const title = line(subject, '主题');
  // Fold RFC 2047 encoded words without splitting a Unicode code point.
  const words = []; let chunk = '';
  for (const c of title) { if (Buffer.byteLength(chunk + c) > 42) { words.push(chunk); chunk = ''; } chunk += c; }
  if (chunk) words.push(chunk);
  const encodedTitle = words.map(s => `=?UTF-8?B?${Buffer.from(s).toString('base64')}?=`).join('\r\n ');
  const headers = [`From: ${addresses(from, true)}`, `To: ${addresses(to, true)}`];
  if (cc) headers.push(`Cc: ${addresses(cc)}`);
  if (bcc) headers.push(`Bcc: ${addresses(bcc)}`);
  headers.push(`Subject: ${encodedTitle}`, `Date: ${new Date().toUTCString()}`, `Message-ID: <${randomUUID()}@f.local>`);
  if (inReplyTo) headers.push(`In-Reply-To: ${line(inReplyTo, '回复标识')}`);
  if (references) headers.push(`References: ${line(references, '引用标识')}`);
  headers.push('MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8', 'Content-Transfer-Encoding: base64');
  const encoded = Buffer.from(body.replace(/\r?\n/g, '\r\n')).toString('base64').match(/.{1,76}/g).join('\r\n');
  return Buffer.from(headers.join('\r\n') + '\r\n\r\n' + encoded + '\r\n').toString('base64url');
}
