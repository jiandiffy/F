import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';

const execute = promisify(execFile);
export async function command(file, args, { trim = true, ...options } = {}) {
  const result = await execute(file, args, { maxBuffer: 8 * 1024 * 1024, timeout: 120000,
    env: { ...process.env, PATH: `${path.join(os.homedir(), '.local/bin')}:/opt/homebrew/bin:/usr/local/bin:${process.env.PATH}` }, ...options });
  return trim ? result.stdout.trim() : result.stdout;
}
export const gh = async (args, options) => JSON.parse(await command('gh', args, options));

async function fetchJSON(url, options = {}) {
  const response = await fetch(url, { signal: AbortSignal.timeout(15000), ...options });
  if (!response.ok) throw new Error(`Data source HTTP ${response.status}: ${new URL(url).origin}`);
  return response.json();
}

export function githubProvider() {
  return { name: 'github', description: 'Search code in your authenticated GitHub account; capture reusable code blocks with repository, commit and file provenance.',
    async search(query, { limit = 20, repository, signal } = {}) {
      const user = await gh(['api', 'user', '--jq', '{login: .login}'], { signal });
      if (repository && !/^[\w.-]+\/[\w.-]+$/.test(repository)) throw new Error('Repository must be owner/name');
      const scope = repository ? `repo:${repository}` : `user:${user.login}`;
      const data = await gh(['api', '--method', 'GET', 'search/code', '-f', `q=${query} ${scope} fork:true`, '-f', `per_page=${Math.min(100, Math.max(1, limit))}`], { signal });
      return { incomplete: data.incomplete_results, total: data.total_count, items: data.items.map(item => ({
        title: item.name, path: item.path, repository: item.repository.full_name, url: item.html_url, blobSHA: item.sha })) };
    },
  };
}

export async function captureGithub({ repository, file, ref = 'HEAD', startLine = 1, endLine, title, summary = '', tags = [], signal }) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository) || !file || file.split('/').includes('..') || file.startsWith('/')) throw new Error('Invalid repository/file');
  const commit = await gh(['api', `repos/${repository}/commits/${encodeURIComponent(ref)}`, '--jq', '{sha: .sha}'], { signal });
  const data = await gh(['api', '--method', 'GET', `repos/${repository}/contents/${file.split('/').map(encodeURIComponent).join('/')}`, '-f', `ref=${commit.sha}`], { signal });
  if (data.type !== 'file' || data.encoding !== 'base64' || data.size > 1024 * 1024) throw new Error('Capture supports source files up to 1 MB');
  const content = Buffer.from(data.content, 'base64').toString('utf8');
  if (content.includes('\0')) throw new Error('Code block must be a text file');
  const lines = content.split('\n'), end = endLine ?? lines.length;
  if (!Number.isInteger(startLine) || !Number.isInteger(end) || startLine < 1 || end < startLine || end > lines.length) throw new Error('Invalid line range');
  const selected = lines.slice(startLine - 1, end).join('\n');
  return { dataset: 'code', title: title || path.basename(file), summary, tags, content: selected,
    source: { provider: 'github', repository, commit: commit.sha, file, startLine, endLine: end,
      url: `https://github.com/${repository}/blob/${commit.sha}/${file}#L${startLine}-L${end}`,
      sha256: createHash('sha256').update(selected).digest('hex') } };
}

export function zoteroProvider({ root, baseURL = 'http://127.0.0.1:23119/api/', request = fetchJSON } = {}) {
  return { name: 'zotero', description: 'Search your Zotero papers, newest added first; metadata only, with persistent Zotero keys and source dates.',
    async search(query = '', { limit = 50, start = 0, cloud = false } = {}) {
      const headers = { 'Zotero-API-Version': '3' };
      let base = baseURL, user = '0';
      if (cloud) {
        if (!root) throw new Error('Zotero cloud key location is not configured');
        const key = (await readFile(path.join(root, 'zotero/api-key.md'), 'utf8')).trim();
        if (!/^[a-zA-Z0-9]{16,64}$/.test(key)) throw new Error('Zotero credential file format is invalid');
        headers['Zotero-API-Key'] = key;
        const identity = await request('https://api.zotero.org/keys/current', { headers });
        user = String(identity.userID); base = 'https://api.zotero.org/';
      }
      const url = new URL(`users/${user}/items/top`, base);
      url.search = new URLSearchParams({ q: query, limit: String(Math.min(100, Math.max(1, limit))), start: String(Math.max(0, start)), sort: 'dateAdded', direction: 'desc', format: 'json' });
      const data = await request(url, { headers });
      return data.filter(item => !['attachment', 'note', 'annotation'].includes(item.data.itemType)).map(item => ({
        dataset: 'paper', title: item.data.title || '(Untitled)', summary: item.data.abstractNote || '',
        creators: item.data.creators ?? [], date: item.data.date, doi: item.data.DOI || undefined,
        tags: (item.data.tags ?? []).map(tag => tag.tag),
        source: { provider: 'zotero', key: item.key, version: item.version, dateAdded: item.data.dateAdded,
          url: item.links?.alternate?.href || `zotero://select/library/items/${item.key}`, publicationURL: item.data.url || undefined },
      }));
    },
  };
}

const xmlText = value => (value ?? '').replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').replace(/<[^>]+>/g, '').replace(/&#(x[\da-f]+|\d+);/gi, (_, n) => String.fromCodePoint(n[0].toLowerCase() === 'x' ? parseInt(n.slice(1), 16) : Number(n))).replace(/&(amp|lt|gt|quot|apos);/g, (_, x) => ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" })[x]).replace(/\s+/g, ' ').trim();
export function parseArxiv(xml) {
  const tag = (body, name) => xmlText(body.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${name}>`))?.[1]);
  return [...xml.matchAll(/<entry(?:\s[^>]*)?>([\s\S]*?)<\/entry>/g)].map(([, body]) => ({
    dataset: 'paper', title: tag(body, 'title'), summary: tag(body, 'summary'), date: tag(body, 'published'),
    creators: [...body.matchAll(/<author>([\s\S]*?)<\/author>/g)].map(([, author]) => ({ name: tag(author, 'name'), affiliation: tag(author, 'arxiv:affiliation') || undefined })),
    source: { provider: 'arxiv', url: tag(body, 'id').replace(/^http:/, 'https:'), updated: tag(body, 'updated') },
    tags: [...body.matchAll(/<category\s[^>]*term="([^"]+)"/g)].map(([, term]) => xmlText(term)),
  }));
}
export function arxivProvider() {
  let lastRequest = 0;
  return { name: 'arxiv', description: 'Search arXiv primary paper metadata and abstracts for research; adds cited metadata to the paper dataset on request.',
    async search(query, { limit = 10, signal } = {}) {
      const delay = Math.max(0, 3100 - (Date.now() - lastRequest));
      if (delay) await new Promise(resolve => setTimeout(resolve, delay));
      lastRequest = Date.now();
      const url = new URL('https://export.arxiv.org/api/query');
      url.search = new URLSearchParams({ search_query: query, start: '0', max_results: String(Math.min(50, Math.max(1, limit))), sortBy: 'relevance' });
      const response = await fetch(url, { signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(20000)]) : AbortSignal.timeout(20000), headers: { 'User-Agent': 'F-AIOS/1.0 (research metadata client)' } });
      if (!response.ok) throw new Error(`arXiv HTTP ${response.status}`);
      return parseArxiv(await response.text());
    },
  };
}
