import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import runtimePaths from './runtime-paths.cjs';
import profiles from './codebuddy-profile.cjs';
import network from './network.cjs';

export const sources = ['dp', 'gpt', 'cbc', 'cbi'];
const timestamp = value => {
  if (typeof value === 'number') return value < 1e12 ? value * 1000 : value;
  if (typeof value === 'string' && /^\d+(\.\d+)?$/.test(value)) return timestamp(Number(value));
  return Date.parse(value);
};
export function codebuddyCredentialUsable(value, now = Date.now()) {
  const auth = value?.auth;
  if (!auth || typeof auth.accessToken !== 'string' || !auth.accessToken.trim()) return false;
  const expires = timestamp(auth.expiresAt);
  if (!Number.isFinite(expires) || expires > now + 30000) return true;
  const refreshExpires = timestamp(auth.refreshExpiresAt);
  return typeof auth.refreshToken === 'string' && !!auth.refreshToken.trim() &&
    (!Number.isFinite(refreshExpires) || refreshExpires > now + 30000);
}
export function codebuddyAuthFile(source, home = os.homedir()) {
  if (!['cbc', 'cbi'].includes(source)) throw Error('Unknown model source');
  // This is the pinned CodeBuddy CLI's own shared authentication store.
  return path.join(home, 'Library/Application Support/CodeBuddyExtension/Data/Public/auth', `fy-pi-${source}.info`);
}
export function codebuddyStatus(source, { home = os.homedir() } = {}) {
  try { return codebuddyCredentialUsable(JSON.parse(fs.readFileSync(codebuddyAuthFile(source, home), 'utf8'))); }
  catch (error) { if (error.code === 'ENOENT' || error instanceof SyntaxError) return false; throw error; }
}
async function authRuntime(source, env = process.env) {
  const [{ createModels, createProvider }, { AuthStorage }, { deepseekProvider }, { openaiCodexProvider }] = await Promise.all([
    import('@earendil-works/pi-ai'),
    import('../node_modules/@earendil-works/pi-coding-agent/dist/core/auth-storage.js'),
    import('@earendil-works/pi-ai/providers/deepseek'),
    import('@earendil-works/pi-ai/providers/openai-codex'),
  ]);
  const resolved = runtimePaths.paths(env);
  const credentials = AuthStorage.create(resolved.auth);
  const models = createModels({ credentials });
  const original = source === 'dp' ? deepseekProvider() : openaiCodexProvider();
  models.setProvider(createProvider({ id: source, name: source, baseUrl: original.baseUrl,
    auth: original.auth, models: original.getModels().map(model => ({ ...model, provider: source })),
    api: { stream: (...args) => original.stream(...args), streamSimple: (...args) => original.streamSimple(...args) } }));
  return { models, credentials, resolved };
}
export async function providerStatus(source, options = {}) {
  if (!sources.includes(source)) throw Error('Unknown model source');
  if (source === 'cbc' || source === 'cbi') return { provider: source, authenticated: codebuddyStatus(source, options) };
  try {
    const { models } = await authRuntime(source, options.env);
    const auth = await models.getAuth(source, { signal: AbortSignal.timeout(12000) });
    if (source === 'dp' && auth?.auth?.apiKey) {
      try {
        const response = await (options.fetcher || fetch)('https://api.deepseek.com/models', {
          headers: { Authorization: `Bearer ${auth.auth.apiKey}` }, signal: AbortSignal.timeout(6000),
        });
        await response.body?.cancel();
        if (response.status === 401 || response.status === 403) return { provider: source, authenticated: false };
      } catch { return { provider: source, authenticated: true, networkUnavailable: true }; }
    }
    return { provider: source, authenticated: !!auth };
  } catch {
    // Keep the credential untouched. A failed refresh can be retried by logging in.
    return { provider: source, authenticated: false };
  }
}
export function readTerminalInput(message, { secret = false, input = process.stdin, output = process.stdout } = {}) {
  if (!input.isTTY) throw Error('请在登录终端中输入。');
  output.write(message + ': ');
  return new Promise((resolve, reject) => {
    let value = '';
    const wasRaw = input.isRaw;
    input.setRawMode(true); input.resume();
    const finish = (error) => {
      input.removeListener('data', onData); input.setRawMode(!!wasRaw); input.pause(); output.write('\r\n');
      error ? reject(error) : resolve(value.trim());
    };
    function onData(buffer) {
      for (const character of buffer.toString('utf8')) {
        if (character === '\u0003' || character === '\u0004') { finish(Error('登录已取消。')); return; }
        if (character === '\r' || character === '\n') { finish(); return; }
        if (character === '\u007f' || character === '\b') {
          if (value) { value = [...value].slice(0, -1).join(''); if (!secret) output.write('\b \b'); }
        } else if (character >= ' ') { value += character; if (!secret) output.write(character); }
      }
    }
    input.on('data', onData);
  });
}
export async function saveDPKey(key, { env = process.env, validate = true, fetcher = fetch } = {}) {
  key = key.trim();
  if (!key || /[\s\x00-\x1f]/.test(key)) throw Error('API key 不能为空或包含空格。');
  if (validate) {
    let response;
    try { response = await fetcher('https://api.deepseek.com/models', { headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(15000) }); }
    catch { throw Error('无法连接 DeepSeek，原凭据未修改，请检查网络后重试。'); }
    await response.body?.cancel();
    if (!response.ok) throw Error(response.status === 401 || response.status === 403 ? 'API key 无效，原凭据未修改。' : 'DeepSeek 暂时无法验证，原凭据未修改，请重试。');
  }
  const { credentials, resolved } = await authRuntime('dp', env);
  await credentials.modify('dp', async () => ({ type: 'api_key', key }));
  fs.chmodSync(resolved.auth, 0o600);
  return resolved.auth;
}
export async function loginProvider(source) {
  if (source === 'dp') {
    const key = await readTerminalInput('输入 DeepSeek API key（输入不显示）', { secret: true });
    await saveDPKey(key); return;
  }
  if (source === 'gpt') {
    const { models, resolved } = await authRuntime(source);
    const controller = new AbortController();
    const cancel = () => controller.abort(Error('登录已取消。'));
    process.once('SIGINT', cancel);
    try {
      await models.login('gpt', 'oauth', {
        signal: controller.signal,
        prompt: value => readTerminalInput(value.message, { secret: value.type === 'secret' }),
        notify: event => {
          if (event.type === 'auth_url') {
            process.stdout.write(`请在浏览器完成登录：\r\n${event.url}\r\n`);
            const child = spawn('/usr/bin/open', [event.url], { stdio: 'ignore' }); child.on('error', () => {});
          } else if (event.type === 'progress') process.stdout.write(event.message + '\r\n');
          else if (event.type === 'device_code') process.stdout.write(`${event.verificationUri}\r\n${event.userCode}\r\n`);
        },
      }, { agentName: 'F' });
      fs.chmodSync(resolved.auth, 0o600);
    } finally { process.removeListener('SIGINT', cancel); }
    return;
  }
  const resolved = runtimePaths.paths(), directory = profiles.ensureProfile(source);
  const env = { ...network.networkEnv(source), CODEBUDDY_CONFIG_DIR: directory,
    CODEBUDDY_INTERNET_ENVIRONMENT: source === 'cbc' ? 'internal' : 'public',
    ACC_PRODUCT_CONFIG_PATH: path.join(directory, 'product.json'), DISABLE_AUTOUPDATER: '1' };
  delete env.CODEBUDDY_API_KEY; delete env.CODEBUDDY_BASE_URL;
  const work = path.join(resolved.data, 'auth/login', source); fs.mkdirSync(work, { recursive: true, mode: 0o700 });
  const authFile = codebuddyAuthFile(source);
  const snapshot = () => { try { return fs.readFileSync(authFile, 'utf8'); } catch { return ''; } };
  const before = snapshot();
  await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(resolved.runtimeRoot, 'node_modules/@tencent-ai/codebuddy-code/bin/codebuddy'), '/login'], { cwd: work, env, stdio: 'inherit' });
    let loggedIn = false;
    const timer = setInterval(() => { if (snapshot() !== before && codebuddyStatus(source)) { loggedIn = true; child.kill('SIGTERM'); } }, 1000);
    const cancel = () => child.kill('SIGINT'); process.once('SIGINT', cancel);
    child.once('error', error => { clearInterval(timer); process.removeListener('SIGINT', cancel); reject(error); });
    child.once('exit', () => { clearInterval(timer); process.removeListener('SIGINT', cancel);
      loggedIn || (snapshot() !== before && codebuddyStatus(source)) ? resolve() : reject(Error('未完成登录，请重试。')); });
  });
}
async function main() {
  const [command, source] = process.argv.slice(2);
  if (!sources.includes(source) || !['status', 'login'].includes(command)) throw Error('使用 status/login dp|gpt|cbc|cbi');
  if (command === 'status') { process.stdout.write(JSON.stringify(await providerStatus(source)) + '\n'); return; }
  await loginProvider(source); loginReceipt(true); process.stdout.write('\r\n登录成功，可以关闭此终端。\r\n');
}
function loginReceipt(authenticated) {
  const file = process.env.F_LOGIN_RESULT_FILE;
  if (!file) return;
  const parent = path.resolve(runtimePaths.paths().data, 'auth/login');
  if (!path.resolve(file).startsWith(parent + path.sep)) throw Error('Invalid login receipt path');
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, JSON.stringify({ authenticated }), { flag: 'wx', mode: 0o600 });
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { try { loginReceipt(false); } catch { }
    process.stderr.write((['dp', 'gpt'].includes(process.argv[3]) ? error.message : '未完成登录，请重试。') + '\r\n'); process.exitCode = 1; });
}
