const path = require('node:path');
const { spawn } = require('node:child_process');
const { networkEnv } = require('./network.cjs');
const [source, ...args] = process.argv.slice(2);
if (!['cbc', 'cbi'].includes(source)) throw new Error('Expected cbc or cbi');
const root = path.resolve(__dirname, '..');
const child = spawn(process.execPath, [path.join(root, 'node_modules/@tencent-ai/codebuddy-code/bin/codebuddy'), ...args], { env: networkEnv(source), stdio: 'inherit' });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('exit', (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
