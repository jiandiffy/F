import { mkdir, readFile, writeFile, rename, lstat, realpath, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { withAccountLock } from '../gmail/vault.mjs';
import { latestMail } from './mail.mjs';

export const dayInShanghai = date => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);
async function json(file, fallback) { try { return JSON.parse(await readFile(file, 'utf8')); } catch (e) { if (e.code === 'ENOENT') return fallback; throw e; } }
async function atomic(file, value) {
  const temp = file + `.${process.pid}.tmp`;
  await writeFile(temp, JSON.stringify(value), { mode: 0o600 }); await rename(temp, file);
}
async function directory(folder) {
  await mkdir(folder, { recursive: true, mode: 0o700 });
  if ((await lstat(folder)).isSymbolicLink() || await realpath(folder) !== path.resolve(folder)) throw new Error('Daily Paper 目录包含符号链接，未执行写入或清理');
}
// The production importer reads mail and writes links only. No paper downloads,
// model process, generated analysis, remote image or video enters this path.
export async function updateDaily({ root, client, signal, date = new Date(), progress = () => {} } = {}) {
  root = path.resolve(root); await mkdir(root, { recursive: true, mode: 0o700 });
  if ((await lstat(root)).isSymbolicLink()) throw new Error('Daily Paper 目录包含符号链接，未执行写入或清理');
  root = await realpath(root); await directory(root); await directory(path.join(root, 'update-lock'));
  return withAccountLock(async () => {
    const previous = await json(path.join(root, 'state.json'), { schema: 1, records: [], account: '' });
    if (previous.schema !== 1) throw new Error('Daily Paper 数据版本不受支持，原数据保留');
    if ((await json(path.join(root, 'control.json'), {})).disabled) throw new Error('Daily Paper 已停用或断开');
    signal?.throwIfAborted(); progress('正在读取 daily papers 分类的最新一封邮件…');
    const mail = await latestMail(client, signal);
    if (previous.account && previous.account !== mail.account) throw new Error('Gmail 账户与已保存论文不一致，请确认连接后重试');
    const day = dayInShanghai(date), key = createHash('sha256').update('links-v1:' + mail.id).digest('hex').slice(0, 20) + '-' + day.replaceAll('-', '');
    if (previous.sourceMode === 'alphaxiv-links-v1' && previous.currentBatch === key && previous.records?.length) return { count: previous.records.length, cached: true, day };
    const records = mail.papers.map(ref => ({ id: 'arxiv:' + ref.id, title: ref.title,
      authors: [], abstract: '', versions: ref.version ? [ref.version] : [],
      sourceURLs: ['https://www.alphaxiv.org/abs/' + ref.id, 'https://arxiv.org/abs/' + ref.id + ref.version],
      mailSources: [{ messageID: mail.id, subject: '', sender: '', date: '', account: mail.account, timestamp: mail.timestamp }] }));
    signal?.throwIfAborted();
    if ((await latestMail(client, signal, false)).id !== mail.id) throw new Error('更新期间出现更新的分类邮件，旧卡片保留，请重试');
    if ((await json(path.join(root, 'control.json'), {})).disabled) throw new Error('Daily Paper 已停用，本批未提交');
    await directory(path.join(root, 'batches')); const batch = path.join(root, 'batches', key); await directory(batch);
    const marker = await json(path.join(batch, 'batch.json'), null);
    if (marker && (marker.kind !== 'f-daily-paper-links-v1' || marker.key !== key)) throw new Error('论文批次目录冲突，原数据保留');
    await atomic(path.join(batch, 'cards.json'), records);
    await atomic(path.join(batch, 'batch.json'), { kind: 'f-daily-paper-links-v1', key, day, complete: true, count: records.length });
    await atomic(path.join(root, 'state.json'), { ...previous, schema: 1, sourceMode: 'alphaxiv-links-v1',
      account: mail.account, settings: { labelID: mail.labelID, sender: '' }, historyID: null, pendingMessageIDs: [],
      records, currentBatch: key, lastSync: date.getTime() / 1000 - 978307200 });
    const cleanupWarnings = [];
    for (const name of await readdir(path.join(root, 'batches'))) {
      if (name === key || !/^[a-f0-9]{20}-\d{8}$/.test(name)) continue;
      const old = path.join(root, 'batches', name);
      try {
        if ((await lstat(old)).isSymbolicLink()) continue;
        const m = await json(path.join(old, 'batch.json'), null);
        if (['f-daily-paper-batch-v1', 'f-daily-paper-links-v1'].includes(m?.kind) && m.key === name) await rm(old, { recursive: true });
      } catch (e) { cleanupWarnings.push(e.message); }
    }
    progress(`已更新 ${records.length} 篇论文链接 · 点击卡片浏览 alphaXiv`);
    return { count: records.length, day, folder: batch, cleanupWarnings };
  }, { directory: path.join(root, 'update-lock'), signal });
}
