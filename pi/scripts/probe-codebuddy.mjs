import { query } from '@tencent-ai/agent-sdk';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import network from './network.cjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = process.argv[2];
const mode = process.argv[3] || 'catalog';
const env = { ...network.networkEnv(source), CODEBUDDY_CONFIG_DIR: path.join(root, 'codebuddy', source), CODEBUDDY_INTERNET_ENVIRONMENT: source === 'cbc' ? 'internal' : 'public', ACC_PRODUCT_CONFIG_PATH: path.join(root, 'codebuddy', source, 'product.json'), DISABLE_AUTOUPDATER: '1' };
const start = Date.now();
const q = query({ prompt: ' ', options: { executable: process.execPath, pathToCodebuddyCode: path.join(root, 'node_modules/@tencent-ai/codebuddy-code/bin/codebuddy'), env, tools: [], strictMcpConfig: true, settingSources: [], maxTurns: 0, permissionMode: "bypassPermissions", ...(mode === 'explicit' ? { environment: source === 'cbc' ? 'internal' : 'external' } : {}) } });
const deadline = setTimeout(() => q.transport?.close(), 25000);
try {
 const models = await q.supportedModels();
 console.log(JSON.stringify({ source, mode, initialized: true, models: models.length, elapsedMs: Date.now() - start, proxy: source === 'cbc' ? 'direct' : env.HTTPS_PROXY }));
} catch (error) {
 console.log(JSON.stringify({ source, mode, initialized: false, error: error.message, elapsedMs: Date.now() - start }));
 process.exitCode = 1;
} finally {
 clearTimeout(deadline);
 q.transport?.close();
 await Promise.race([q.return().catch(() => {}), new Promise(resolve => setTimeout(resolve, 100))]);
 process.exit(process.exitCode || 0);
}
