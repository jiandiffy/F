import { mkdir, readFile, writeFile, rename, lstat, realpath, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { withAccountLock } from '../../gmail/agent/vault.mjs';
import { latestMail } from './mail.mjs';
import { readPaper, download, validImage, validVideo } from './source.mjs';
import { analyzePaper, validateAnalysis, modelID } from './model.mjs';
import { renderAnalysis } from './render.mjs';

const hash = text => createHash('sha256').update(text).digest('hex').slice(0, 20);
const exec = promisify(execFile);
const swiftDate = date => date.getTime() / 1000 - 978307200;
export const dayInShanghai = date => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);
async function readJSON(file, fallback) {
  try { return JSON.parse(await readFile(file, 'utf8')); } catch (e) { if (e.code === 'ENOENT') return fallback; throw e; }
}
async function directory(folder) {
  await mkdir(folder, { recursive: true, mode: 0o700 });
  if ((await lstat(folder)).isSymbolicLink() || await realpath(folder) !== path.resolve(folder)) throw new Error('Daily Paper 目录包含符号链接，未执行写入或清理');
}
async function atomicJSON(file, value) {
  const temp = file + `.${process.pid}.tmp`;
  await writeFile(temp, JSON.stringify(value), { mode: 0o600 }); await rename(temp, file);
}
async function safeFiles(folder, names) {
  for (const name of names) {
    if (!/^[\w.-]+$/.test(name)) return false;
    try { if (!(await lstat(path.join(folder, name))).isFile()) return false; } catch { return false; }
  }
  return true;
}
export async function updateDaily({ root, pi, client, signal, date = new Date(), progress = () => {}, read = readPaper, analyze = analyzePaper, fetchFile = download, concurrency = 2 } = {}) {
  root = path.resolve(root);
  await mkdir(root, { recursive: true, mode: 0o700 });
  if ((await lstat(root)).isSymbolicLink()) throw new Error('Daily Paper 目录包含符号链接，未执行写入或清理');
  root = await realpath(root); await directory(root);
  await directory(path.join(root, 'update-lock'));
  return withAccountLock(async () => {
    const previous = await readJSON(path.join(root, 'state.json'), { schema: 1, settings: { labelID: '', sender: '' }, account: '', records: [] });
    if (previous.schema !== 1) throw new Error('Daily Paper 数据版本不受支持，原数据保留');
    const control = await readJSON(path.join(root, 'control.json'), {});
    if (control.disabled) throw new Error('Daily Paper 已停用或断开，未执行更新');
    signal?.throwIfAborted(); progress('正在读取 daily papers 分类的最新一封邮件…');
    const mail = await latestMail(client, signal);
    if (previous.account && previous.account !== mail.account) throw new Error('Gmail 账户与已保存论文不一致，请确认连接后重试');
    const day = dayInShanghai(date), key = hash(mail.id) + '-' + day.replaceAll('-', '');
    if (previous.currentBatch === key && previous.records?.length) return { count: previous.records.length, cached: true, day };
    await directory(path.join(root, 'batches'));
    const batch = path.join(root, 'batches', key);
    await directory(batch);
    const marker = { kind: 'f-daily-paper-batch-v1', key, mailID: mail.id, day, model: modelID, total: mail.papers.length };
    const priorMarker = await readJSON(path.join(batch, 'batch.json'), null);
    if (priorMarker && (priorMarker.kind !== marker.kind || priorMarker.mailID !== mail.id || priorMarker.key !== key)) throw new Error('论文批次目录冲突，原文件保留');
    await atomicJSON(path.join(batch, 'batch.json'), marker);
    let index = 0, completed = 0;
    const results = new Array(mail.papers.length), skipped = [];
    let failure;
    async function run() {
      while (!failure) {
        const i = index++; if (i >= mail.papers.length) return;
        signal?.throwIfAborted();
        const ref = mail.papers[i], paperKey = hash(ref.id + ref.version), folder = path.join(batch, paperKey);
        await directory(folder);
        const saved = await readJSON(path.join(folder, 'complete.json'), null);
        if (saved?.model === modelID && saved.ref?.id === ref.id && await safeFiles(folder, saved.files ?? [])) {
          validateAnalysis(saved.analysis, saved.media ?? []); results[i] = saved.record;
          progress(`已恢复 ${++completed}/${mail.papers.length} 篇论文`); continue;
        }
        progress(`正在读取 ${i + 1}/${mail.papers.length}：${ref.id}`);
        let paper;
        try { paper = await read(ref, { signal }); }
        catch (error) { signal?.throwIfAborted(); skipped.push({ id: ref.id, reason: String(error.message).slice(0, 300) }); continue; }
        await writeFile(path.join(folder, 'paper.md'), paper.text, { mode: 0o600 });
        if (paper.overview) await writeFile(path.join(folder, 'alphaxiv-reference.md'), paper.overview, { mode: 0o600 });
        const media = [];
        for (const item of paper.media) {
          signal?.throwIfAborted();
          try {
            const resource = await fetchFile(item.url, { limit: item.kind === 'video' ? 30_000_000 : 3_000_000, project: true, signal });
            const expected = item.kind === 'video' ? /^video\/(mp4|webm)/i : /^image\/(png|jpeg|webp)/i;
            if (!expected.test(resource.type)) continue;
            if (item.kind === 'image' && !validImage(resource.data, resource.type)) continue;
            if (item.kind === 'video' && !validVideo(resource.data, resource.type)) continue;
            const extension = /png/i.test(resource.type) ? 'png' : /jpeg/i.test(resource.type) ? 'jpg' : /webp/i.test(resource.type) ? 'webp' : /webm/i.test(resource.type) ? 'webm' : 'mp4';
            const file = `media-${media.length + 1}.${extension}`;
            await writeFile(path.join(folder, file), resource.data, { mode: 0o600 });
            if (item.kind === 'image') {
              try { await exec('/usr/bin/sips', ['--resampleHeightWidthMax', '1600', path.join(folder, file), '--out', path.join(folder, file)], { timeout: 30000, signal, maxBuffer: 16000 }); }
              catch (error) { await rm(path.join(folder, file), { force: true }); throw error; }
            }
            media.push({ ...item, file, id: 'm' + (media.length + 1) });
          } catch { signal?.throwIfAborted(); }
        }
        paper.media = media;
        try {
          const pdf = await fetchFile(paper.paperURL, { limit: 25_000_000, signal });
          if (pdf.data.subarray(0, 5).toString() === '%PDF-') { await writeFile(path.join(folder, 'paper.pdf'), pdf.data, { mode: 0o600 }); paper.pdfSaved = true; }
        } catch { signal?.throwIfAborted(); }
        progress(`正在用 cbi DeepSeek V4.1 分析 ${i + 1}/${mail.papers.length}：${ref.id}`);
        const analysis = validateAnalysis(await analyze(paper, { pi, cwd: folder, signal }), media);
        signal?.throwIfAborted();
        const record = { id: 'arxiv:' + ref.id, title: analysis.title, authors: [], abstract: analysis.summary, sourceURLs: [paper.paperURL, paper.alphaURL], versions: ref.version ? [ref.version] : [], mailSources: [{ messageID: mail.id, subject: '', sender: '', date: '', account: mail.account, timestamp: mail.timestamp }], analysisFolder: `batches/${key}/${paperKey}`, imageFile: media.find(m => m.kind === 'image')?.file, imageURL: media.find(m => m.kind === 'image')?.url };
        await writeFile(path.join(folder, 'index.html'), renderAnalysis(analysis, paper, day), { mode: 0o600 });
        await atomicJSON(path.join(folder, 'analysis.json'), { provider: 'cbi', model: modelID, generatedAt: date.toISOString(), analysis, sources: { paper: paper.origin, alphaxiv: paper.alphaURL }, media });
        const files = ['index.html', 'paper.md', 'analysis.json', ...media.map(m => m.file), ...(paper.pdfSaved ? ['paper.pdf'] : [])];
        await atomicJSON(path.join(folder, 'complete.json'), { model: modelID, ref, analysis, media, record, files });
        results[i] = record; progress(`已完成 ${++completed}/${mail.papers.length} 篇论文`);
      }
    }
    // At most two owned model children; any failed analysis prevents the batch
    // commit. Completed per-paper folders let the next invocation resume safely.
    const workers = Array.from({ length: Math.min(2, Math.max(1, concurrency)) }, () => run().catch(error => { failure ??= error; }));
    await Promise.all(workers);
    if (failure) throw failure;
    signal?.throwIfAborted();
    const records = results.filter(Boolean);
    if (!records.length) throw new Error('最新邮件没有能实际读取并分析的论文，旧一批保留');
    if ((await latestMail(client, signal, false)).id !== mail.id) throw new Error('更新期间出现了更新的分类邮件，本批未替换旧内容；请重试');
    if ((await readJSON(path.join(root, 'control.json'), {})).disabled) throw new Error('Daily Paper 已停用，本批未提交');
    await atomicJSON(path.join(batch, 'batch.json'), { ...marker, complete: true, count: records.length, skipped });
    const next = { ...previous, settings: { labelID: mail.labelID, sender: '' }, account: mail.account, historyID: null, pendingMessageIDs: [], records, currentBatch: key, lastSync: swiftDate(date) };
    // Only this atomic state commit makes a new batch visible. Nothing expired
    // is removed until every readable paper in the new batch is fully analyzed.
    await atomicJSON(path.join(root, 'state.json'), next);
    const cleanupWarnings = [];
    for (const name of await readdir(path.join(root, 'batches'))) {
      if (name === key || !/^[a-f0-9]{20}-\d{8}$/.test(name)) continue;
      const old = path.join(root, 'batches', name);
      try {
        if ((await lstat(old)).isSymbolicLink()) continue;
        const m = await readJSON(path.join(old, 'batch.json'), null);
        if (m?.kind === marker.kind && m.key === name) await rm(old, { recursive: true });
      } catch (error) { cleanupWarnings.push(String(error.message).slice(0, 200)); }
    }
    for (const name of new Set((previous.records ?? []).filter(r => !r.analysisFolder).map(r => r.imageFile).filter(n => /^[a-f0-9]{64}\.image$/.test(n ?? '')))) {
      try { await rm(path.join(root, 'images', name), { force: true }); } catch (e) { cleanupWarnings.push(e.message); }
    }
    return { count: records.length, skipped: skipped.length, day, folder: batch, cleanupWarnings };
  }, { directory: path.join(root, 'update-lock'), signal });
}
