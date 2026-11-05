import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, open, readFile, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';

const exec = promisify(execFile);
export class KeychainVault {
  constructor(service = 'local.f.gmail', account = 'primary') {
    if (!/^[\w.-]+$/.test(service) || !/^[\w.-]+$/.test(account)) throw new Error('无效的钥匙串身份');
    this.service = service; this.account = account;
  }
  async load() {
    try {
      const { stdout } = await exec('/usr/bin/security', ['find-generic-password', '-s', this.service, '-a', this.account, '-w'], { timeout: 15000 });
      const text = stdout.trim();
      // security prints non-ASCII passwords as hexadecimal bytes.
      return JSON.parse(/^(?:[0-9a-f]{2})+$/i.test(text) ? Buffer.from(text, 'hex').toString('utf8') : text);
    } catch (e) {
      if (e.code === 44) return {};
      throw new Error('无法读取 Gmail 钥匙串，请解锁登录钥匙串后重试');
    }
  }
  async save(value) {
    // Interactive stdin keeps refresh tokens out of argv, process listings and errors.
    const secret = JSON.stringify(value).replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    await new Promise((resolve, reject) => {
      const child = spawn('/usr/bin/security', ['-i'], { stdio: ['pipe', 'ignore', 'pipe'] });
      let failed = false;
      child.stderr.on('data', data => { if (/SecKeychain|Error:|error:/i.test(String(data))) failed = true; });
      child.on('error', () => reject(new Error('无法保存 Gmail 钥匙串')));
      child.stdin.on('error', () => {});
      child.on('close', code => code === 0 && !failed ? resolve() : reject(new Error('无法保存 Gmail 钥匙串')));
      child.stdin.end(`add-generic-password -U -s ${this.service} -a ${this.account} -w "${secret}"\n`);
    });
    // security -i can exit successfully after a command error. Verify the exact record.
    if (JSON.stringify(await this.load()) !== JSON.stringify(value)) throw new Error('Gmail 钥匙串保存校验失败');
  }
}

export const gmailDirectory = () => path.join(os.homedir(), 'Library/Application Support/F/applications/gmail/global');
export async function withAccountLock(fn, { directory = gmailDirectory(), signal } = {}) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const lock = path.join(directory, 'account.lock');
  let handle;
  for (let i = 0; i < 100; i++) {
    signal?.throwIfAborted();
    try { handle = await open(lock, 'wx', 0o600); await handle.writeFile(String(process.pid)); break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // Recover only a dead process's lock, never a live authorization flow.
      const before = await stat(lock).catch(e => { if (e.code !== 'ENOENT') throw e; });
      const pid = Number(await readFile(lock, 'utf8').catch(e => { if (e.code !== 'ENOENT') throw e; return ''; }));
      if (before && pid > 0) {
        try { process.kill(pid, 0); }
        catch (e) { if (e.code === 'ESRCH' && (await stat(lock).catch(() => null))?.ino === before.ino) await rm(lock, { force: true }); }
      }
      await delay(100, undefined, { signal });
    }
  }
  if (!handle) throw new Error('Gmail 正在处理其他请求，请稍后重试');
  try { return await fn(); }
  finally { await handle.close(); await rm(lock, { force: true }); }
}
