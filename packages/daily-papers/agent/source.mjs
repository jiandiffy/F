import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';

const hosts = new Set(['arxiv.org', 'export.arxiv.org', 'alphaxiv.org', 'www.alphaxiv.org']);
export function sourceURL(value, { project = false } = {}) {
  try {
    const u = new URL(value);
    if (u.protocol !== 'https:' || u.username || u.password || (u.port && u.port !== '443')) return null;
    if (!hosts.has(u.hostname) && !(project && /^[a-z0-9-]+\.github\.io$/.test(u.hostname))) return null;
    return u;
  } catch { return null; }
}
export async function download(value, { limit = 3_000_000, signal, project = false, request = fetch } = {}) {
  let url = sourceURL(value, { project });
  if (!url) throw new Error('拒绝非论文来源地址');
  for (let i = 0; i < 4; i++) {
    // Host allowlist is intentionally narrow; a source cannot introduce local/private hosts.
    if (request === fetch) {
      const addresses = await lookup(url.hostname, { all: true });
      if (addresses.some(({ address }) => /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|0\.|::1$|f[cd]|fe80)/i.test(address) || !isIP(address))) throw new Error('拒绝非公开来源地址');
    }
    const response = await request(url.href, { redirect: 'manual', signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(60000)]) : AbortSignal.timeout(60000) });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      await response.body?.cancel();
      const next = sourceURL(new URL(response.headers.get('location') ?? '', url).href, { project });
      if (!next || ![url.hostname, 'www.' + url.hostname, url.hostname.replace(/^www\./, '')].includes(next.hostname)) throw new Error('拒绝跨主机重定向');
      url = next; continue;
    }
    if (!response.ok) { await response.body?.cancel(); throw new Error(`来源 HTTP ${response.status}`); }
    if (Number(response.headers.get('content-length')) > limit) { await response.body?.cancel(); throw new Error('来源文件超过大小限制'); }
    const chunks = []; let bytes = 0;
    try {
      for await (const chunk of response.body) {
        bytes += chunk.length;
        if (bytes > limit) throw new Error('来源文件超过大小限制');
        chunks.push(chunk);
      }
    } catch (error) { await response.body?.cancel().catch(() => {}); throw error; }
    return { data: Buffer.concat(chunks), type: response.headers.get('content-type') ?? '', url: url.href };
  }
  throw new Error('来源重定向过多');
}
export function references(text) {
  const seen = new Set(), result = [];
  for (const m of text.matchAll(/(?:arxiv\.org\/(?:abs|pdf|html)\/|alphaxiv\.org\/(?:abs|overview)\/|arxiv:\s*|doi(?:\.org\/|:\s*)10\.48550\/arxiv\.)(\d{4}\.\d{4,5}|[a-z-]+(?:\.[a-z-]+)?\/\d{7})(v\d+)?/gi)) {
    const id = m[1].toLowerCase();
    if (!seen.has(id)) { seen.add(id); result.push({ id, version: m[2] ?? '' }); }
  }
  return result;
}
export function mailText(payload) {
  const chunks = []; let remaining = 8_000_000, visited = 0;
  function visit(part, depth) {
    if (depth > 20 || remaining <= 0 || ++visited > 2000) return;
    if (['text/plain', 'text/html'].includes(part?.mimeType) && typeof part.body?.data === 'string') {
      const own = Buffer.from(part.body.data.slice(0, Math.ceil(remaining / 3) * 4), 'base64url').toString('utf8').slice(0, remaining);
      chunks.push(own); remaining -= own.length + 1;
    }
    if (Array.isArray(part?.parts)) for (const child of part.parts) { if (remaining <= 0) break; visit(child, depth + 1); }
  }
  visit(payload, 0); return chunks.join('\n');
}
export function plainHTML(html) {
  return html.replace(/<(script|style|nav|header|footer|annotation(?:-xml)?)\b[^>]*>[\s\S]*?<\/\1>/gi, '').replace(/<[^>]+>/g, ' ').replace(/&(?:amp|lt|gt|quot|nbsp);/g, x => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&nbsp;': ' ' })[x]).replace(/\s+/g, ' ').trim();
}
export function validVideo(data, type) {
  return /^video\/mp4/i.test(type) ? data.length >= 12 && data.toString('ascii', 4, 8) === 'ftyp' : /^video\/webm/i.test(type) && data.length >= 4 && data.subarray(0, 4).toString('hex') === '1a45dfa3';
}
export function validImage(data, type) {
  let width = 0, height = 0;
  if (/image\/png/i.test(type) && data.length >= 24 && data.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) {
    width = data.readUInt32BE(16); height = data.readUInt32BE(20);
  } else if (/image\/jpeg/i.test(type) && data[0] === 255 && data[1] === 216) {
    let offset = 2;
    while (offset + 9 < data.length) {
      if (data[offset++] !== 255) break;
      while (data[offset] === 255) offset++;
      const marker = data[offset++];
      if ([216,217,1].includes(marker)) continue;
      if (offset + 2 > data.length) break;
      const size = data.readUInt16BE(offset);
      if (size < 2 || offset + size > data.length) break;
      if ([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)) { height = data.readUInt16BE(offset + 3); width = data.readUInt16BE(offset + 5); break; }
      offset += size;
    }
  } else if (/image\/webp/i.test(type) && data.length >= 30 && data.toString('ascii', 0, 4) === 'RIFF' && data.toString('ascii', 8, 12) === 'WEBP') {
    const chunk = data.toString('ascii', 12, 16);
    if (chunk === 'VP8X') { width = 1 + data.readUIntLE(24, 3); height = 1 + data.readUIntLE(27, 3); }
    else if (chunk === 'VP8 ' && data[23] === 157 && data[24] === 1 && data[25] === 42) { width = data.readUInt16LE(26) & 16383; height = data.readUInt16LE(28) & 16383; }
    else if (chunk === 'VP8L' && data[20] === 47) { const bits = data.readUInt32LE(21); width = 1 + (bits & 16383); height = 1 + ((bits >>> 14) & 16383); }
  }
  return width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 24_000_000;
}
export function mediaFromHTML(html, base) {
  const result = [], seen = new Set();
  for (const match of html.matchAll(/<figure\b[^>]*>([\s\S]*?)<\/figure>/gi)) {
    const image = /<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']/i.exec(match[1]);
    if (!image) continue;
    const u = [base, base.endsWith('/') ? base : base + '/'].map(b => sourceURL(new URL(image[1], b).href)).find(u => u && u.pathname.startsWith(new URL(base).pathname + '/'));
    if (!u || u.hostname !== 'arxiv.org' || !u.pathname.startsWith(new URL(base).pathname + '/') || !/\.(png|jpe?g|webp)$/i.test(u.pathname)) continue;
    const caption = plainHTML(/<figcaption\b[^>]*>([\s\S]*?)<\/figcaption>/i.exec(match[1])?.[1] ?? '').slice(0, 1400);
    if (!seen.has(u.href)) { seen.add(u.href); result.push({ kind: 'image', url: u.href, caption }); }
    if (result.length === 6) break;
  }
  return result;
}
export function videosFromHTML(html, base) {
  const result = [], seen = new Set();
  for (const m of html.matchAll(/(?:src|href)\s*=\s*["']([^"']+)["']/gi)) {
    let u; try { u = new URL(m[1], base); } catch { continue; }
    if (u.protocol !== 'https:' || u.hostname !== new URL(base).hostname || !/\.(mp4|webm)$/i.test(u.pathname) || !sourceURL(u.href, { project: true })) continue;
    if (!seen.has(u.href)) { seen.add(u.href); result.push({ kind: 'video', url: u.href, caption: '论文项目演示视频' }); }
    if (result.length === 2) break;
  }
  return result;
}
export async function readPaper(ref, { signal, request = fetch } = {}) {
  const identifier = ref.id + ref.version, base = 'https://arxiv.org/html/' + identifier;
  const get = (u, limit, project = false) => download(u, { limit, signal, request, project });
  let text = '', overview = '', html = '', origin = '';
  try {
    const full = await get('https://www.alphaxiv.org/abs/' + identifier + '.md', 2_000_000);
    if (!/text\/(markdown|plain)/i.test(full.type)) throw new Error('非论文文本');
    text = full.data.toString('utf8'); origin = full.url;
    const escaped = ref.id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const actualVersion = new RegExp('arxiv\\s*:\\s*' + escaped + '\\s*(v\\d+)', 'i').exec(text)?.[1];
    if (ref.version && actualVersion && actualVersion !== ref.version) { text = ''; origin = ''; }
  } catch (e) { signal?.throwIfAborted(); }
  try { html = (await get(base, 6_000_000)).data.toString('utf8'); } catch { signal?.throwIfAborted(); }
  if (!text && /<article\b/i.test(html)) { text = plainHTML(html); origin = base; }
  if (text.length < 1800 || (text.match(/\b(?:abstract|introduction|references|conclusion)\b/gi) ?? []).length < 2 || /^(<!doctype|<html)/i.test(text.trim()) || /^(access denied|just a moment)/i.test(text.trim())) throw new Error('无法实际读取论文正文');
  try { overview = (await get('https://www.alphaxiv.org/overview/' + identifier + '.md', 1_000_000)).data.toString('utf8'); if (/^\s*</.test(overview)) overview = ''; } catch { signal?.throwIfAborted(); }
  const media = mediaFromHTML(html, base);
  const projects = [...text.matchAll(/https:\/\/[a-z0-9-]+\.github\.io(?:\/[^\s<>"'\])}]*)?/gi)].map(m => m[0]).slice(0, 2);
  for (const project of new Set(projects)) {
    try { const page = await get(project, 2_000_000, true); media.push(...videosFromHTML(page.data.toString('utf8'), page.url)); } catch { signal?.throwIfAborted(); }
  }
  return { ref, text, overview, origin, media, paperURL: 'https://arxiv.org/pdf/' + identifier, alphaURL: 'https://www.alphaxiv.org/' + (overview ? 'overview/' : 'abs/') + identifier };
}
