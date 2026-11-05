import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { writeFile, rename } from 'node:fs/promises';
import { setGlobalProxyFromEnv } from 'node:http';
import { dailyClient } from './mail.mjs';
import { updateDaily } from './links.mjs';

const abort = new AbortController();
process.once('SIGTERM', () => abort.abort()); process.once('SIGINT', () => abort.abort());
if (!process.env.HTTPS_PROXY && !process.env.https_proxy) {
  const proxy = execFileSync('/usr/sbin/scutil', ['--proxy'], { encoding: 'utf8' });
  const host = /HTTPSProxy\s*:\s*(\S+)/.exec(proxy)?.[1], port = /HTTPSPort\s*:\s*(\d+)/.exec(proxy)?.[1];
  if (/HTTPSEnable\s*:\s*1/.test(proxy) && host && port) process.env.HTTPS_PROXY = `http://${host}:${port}`;
}
process.env.NO_PROXY ??= 'localhost,127.0.0.1,::1,api.deepseek.com,.deepseek.com,www.codebuddy.cn,.codebuddy.cn,copilot.tencent.com,.copilot.tencent.com,copilot.qq.com,.copilot.qq.com';
setGlobalProxyFromEnv();
let input = '';
let statusPath, statusQueue = Promise.resolve(), statusStarted = false;
function status(phase, message) {
  if (!statusPath) return;
  const value = { phase, message, updatedAt: new Date().toISOString(), pid: process.pid };
  statusQueue = statusQueue.then(async () => {
    const temp = statusPath + `.${process.pid}.tmp`;
    await writeFile(temp, JSON.stringify(value), { mode: 0o600 }); await rename(temp, statusPath);
  }).catch(() => {});
}
try {
  if (!process.stdin.isTTY && !process.argv.includes('--scheduled')) for await (const chunk of process.stdin) { input += chunk; if (input.length > 16000) throw new Error('请求过大'); }
  const options = input.trim() ? JSON.parse(input) : {};
  if (process.argv.includes('--scheduled') || options.scheduled) {
    try { if (execFileSync('/usr/bin/defaults', ['read', 'local.f.app', 'FDisabledPlugins'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).includes('daily-paper')) throw new Error('Daily Paper 插件已停用'); }
    catch (e) { if (e.message === 'Daily Paper 插件已停用') throw e; }
    let automatic = false;
    try { automatic = execFileSync('/usr/bin/defaults', ['read', 'local.f.app', 'FDailyPaperAutoUpdate'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() === '1'; } catch {}
    if (!automatic) { process.stdout.write(JSON.stringify({ ok: true, value: { paused: true } }) + '\n'); process.exit(0); }
  }
  const root = options.root ?? path.join(os.homedir(), 'Library/Application Support/F/applications/daily-paper/global');
  statusPath = path.join(root, 'update-status.json');
  const value = await updateDaily({ root, client: dailyClient(), signal: abort.signal, progress: message => { statusStarted = true; process.stdout.write(JSON.stringify({ status: message }) + '\n'); status('running', message); } });
  status('completed', `${value.count} 篇论文链接 · ${value.day}`); await statusQueue;
  process.stdout.write(JSON.stringify({ ok: true, value }) + '\n');
} catch (e) {
  const message = e.name === 'AbortError' ? '操作已取消，旧一批与已完成进度保留' : e.message;
  if (statusStarted) { status('failed', message); await statusQueue; }
  process.stdout.write(JSON.stringify({ ok: false, error: message }) + '\n'); process.exitCode = 1;
}
