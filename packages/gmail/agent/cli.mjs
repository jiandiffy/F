import { runGmail } from './client.mjs';

let data = '';
try {
  for await (const chunk of process.stdin) {
    data += chunk;
    if (Buffer.byteLength(data) > 8_000_000) throw new Error('Gmail 请求过大');
  }
  const input = JSON.parse(data);
  const controller = new AbortController();
  process.once('SIGTERM', () => controller.abort());
  const value = await runGmail(input, controller.signal);
  process.stdout.write(JSON.stringify({ ok: true, value }) + '\n');
} catch (e) {
  process.stdout.write(JSON.stringify({ ok: false, error: e.message }) + '\n');
  process.exitCode = 1;
}
