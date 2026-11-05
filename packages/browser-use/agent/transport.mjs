import { readFile, writeFile, rename, rm, lstat, realpath } from 'node:fs/promises';
import { randomBytes, randomUUID, createCipheriv } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
export const browserDirectory = () => process.env.F_BROWSER_DIRECTORY ?? path.join(os.homedir(), 'Library/Application Support/F/applications/browser/global');
export async function browserRequest(input, signal, { root = browserDirectory(), timeout = 35000 } = {}) {
  signal?.throwIfAborted(); root = path.resolve(root);
  const info = await lstat(root).catch(() => { throw Error('请先打开 F 并启用浏览器插件'); });
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o077) || (typeof process.getuid === 'function' && info.uid !== process.getuid())) throw Error('F 浏览器连接目录权限无效');
  root = await realpath(root); const endpoint = path.join(root, 'endpoint.json'), stat = await lstat(endpoint);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || (stat.mode & 0o077) || stat.size > 4096) throw Error('F 浏览器连接信息无效');
  const value = JSON.parse(await readFile(endpoint, 'utf8'));
  if (value.version !== 1 || typeof value.nonce !== 'string' || !Number.isInteger(value.pid)) throw Error('F 浏览器连接版本无效');
  try { process.kill(value.pid, 0); } catch { throw Error('F 浏览器尚未运行'); }
  const plain = Buffer.from(JSON.stringify(input)); if (plain.length > 1_000_000) throw Error('浏览器请求过大');
  const key = Buffer.from(value.key, 'base64'), iv = randomBytes(12); if (key.length !== 32) throw Error('F 浏览器连接密钥无效');
  const cipher = createCipheriv('aes-256-gcm', key, iv); cipher.setAAD(Buffer.from(value.nonce));
  const encrypted = Buffer.concat([iv, cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
  const id = randomUUID(), request = path.join(root, 'requests', id + '.json'), temp = request + '.tmp', response = path.join(root, 'responses', id + '.json');
  for (const name of ['requests','responses']) { const d = await lstat(path.join(root,name)); if (!d.isDirectory() || d.isSymbolicLink()) throw Error('浏览器消息目录无效'); }
  try {
    await writeFile(temp, JSON.stringify({ nonce:value.nonce, ciphertext:encrypted.toString('base64') }), { mode:0o600, flag:'wx' }); await rename(temp,request);
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      signal?.throwIfAborted();
      try {
        const file = await lstat(response); if (!file.isFile() || file.isSymbolicLink() || file.size > 1_000_000) throw Error('浏览器结果无效');
        const result = JSON.parse(await readFile(response,'utf8')); if (!result.ok) throw Error(result.error ?? '浏览器操作失败'); return result.value;
      } catch (e) { if (e.code !== 'ENOENT') throw e; }
      await new Promise(resolve => setTimeout(resolve,100));
    }
    throw Error('浏览器操作超时，操作可能已执行；请先读取页面，不要自动重试提交');
  } finally { await Promise.all([request,temp,response].map(p => rm(p,{force:true}).catch(()=>{}))); }
}
