import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// A dedicated worker enables Node's proxy handling without changing the model
// process's global HTTP dispatcher. Only this worker is canceled with the tool.
export function runGmailWorker(input, signal) {
  signal?.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--use-env-proxy', fileURLToPath(new URL('./cli.mjs', import.meta.url))], { stdio: ['pipe','pipe','ignore'] });
    let output = '', oversized = false;
    const abort = () => child.kill('SIGTERM');
    signal?.addEventListener('abort', abort, { once: true });
    child.on('error', () => reject(new Error('无法启动 Gmail 请求进程')));
    child.stdin.on('error', () => {});
    child.stdout.on('data', data => {
      if (oversized) return;
      output += data;
      if (Buffer.byteLength(output) > 20_000_000) { oversized = true; abort(); }
    });
    child.once('close', () => {
      signal?.removeEventListener('abort', abort);
      if (oversized) { reject(new Error('邮件内容过大，请在 Gmail 网页阅读')); return; }
      if (signal?.aborted) { reject(new Error('Gmail 请求已取消；发送中断时请先检查已发送邮件')); return; }
      try {
        const response = JSON.parse(output);
        if (!response.ok) throw new Error(response.error);
        resolve(response.value);
      } catch (e) { reject(new Error(e instanceof SyntaxError ? 'Gmail 请求未完成；发送中断时请先检查已发送邮件' : e.message)); }
    });
    child.stdin.end(JSON.stringify(input));
  });
}
