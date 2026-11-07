import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, stat, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { EventEmitter } from 'node:events';
import { codebuddyCredentialUsable, codebuddyAuthFile, codebuddyStatus, providerStatus, saveDPKey, readTerminalInput } from './provider-auth.mjs';
import runtimePaths from './runtime-paths.cjs';
import profiles from './codebuddy-profile.cjs';

test('CodeBuddy rejects expired sessions and keeps refreshable regional accounts', () => {
  const now = Date.now();
  assert.equal(codebuddyCredentialUsable({}), false);
  assert.equal(codebuddyCredentialUsable({ auth: { accessToken: 'fixture', expiresAt: now - 1 } }, now), false);
  assert.equal(codebuddyCredentialUsable({ auth: { accessToken: 'fixture', expiresAt: now + 60000 } }, now), true);
  assert.equal(codebuddyCredentialUsable({ auth: { accessToken: 'fixture', expiresAt: now - 1,
    refreshToken: 'fixture-refresh', refreshExpiresAt: now + 60000 } }, now), true);
  assert.equal(codebuddyCredentialUsable({ auth: { accessToken: 'fixture', expiresAt: now - 1,
    refreshToken: 'fixture-refresh', refreshExpiresAt: now - 1 } }, now), false);
});

test('CBC and CBI do not read each other’s login or a personal account', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'f-auth-region-'));
  try {
    const file = codebuddyAuthFile('cbc', home); await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, JSON.stringify({ auth: { accessToken: 'fixture', expiresAt: Date.now() + 60000 } }));
    assert.equal(codebuddyStatus('cbc', { home }), true);
    assert.equal(codebuddyStatus('cbi', { home }), false);
    assert.equal((await providerStatus('cbi', { home })).authenticated, false);
    await writeFile(codebuddyAuthFile('cbi', home), '{broken');
    assert.equal(codebuddyStatus('cbi', { home }), false);
  } finally { await rm(home, { recursive: true }); }
});

test('DP saves a validated key privately, preserves GPT, and rejects failed validation without changing the file', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'f-dp-login-'));
  const env = { ...process.env, PI_CODING_AGENT_DIR: path.join(root, 'agent'), F_USER_DATA_DIRECTORY: root };
  const file = path.join(env.PI_CODING_AGENT_DIR, 'auth.json');
  try {
    await mkdir(path.dirname(file));
    await writeFile(file, JSON.stringify({ gpt: { type: 'oauth', access: 'fixture-access', refresh: 'fixture-refresh', expires: Date.now() + 86400000 } }));
    let requested;
    const fetcher = async (url, options) => { requested = { url, options }; return { ok: true, body: { cancel: async () => {} } }; };
    assert.equal(await saveDPKey('sk-test-fixture', { env, fetcher }), file);
    assert.equal(requested.url, 'https://api.deepseek.com/models');
    assert.equal(requested.options.headers.Authorization, 'Bearer sk-test-fixture');
    const value = JSON.parse(await readFile(file, 'utf8'));
    assert.equal(value.dp.key, 'sk-test-fixture'); assert.equal(value.gpt.access, 'fixture-access');
    assert.equal((await stat(file)).mode & 0o777, 0o600);
    assert.equal((await providerStatus('dp', { env, fetcher })).authenticated, true);
    assert.equal((await providerStatus('dp', { env, fetcher: async () => ({ status: 401 }) })).authenticated, false);
    const before = await readFile(file, 'utf8');
    await assert.rejects(saveDPKey('sk-rejected-fixture', { env, fetcher: async () => ({ ok: false, status: 401 }) }), /无效/);
    assert.equal(await readFile(file, 'utf8'), before);
    await assert.rejects(saveDPKey('sk-offline-fixture', { env, fetcher: async () => { throw Error('offline'); } }), /网络/);
    assert.equal(await readFile(file, 'utf8'), before);
  } finally { await rm(root, { recursive: true }); }
});

test('terminal API-key entry never echoes a secret and restores terminal mode after submit or cancellation', async () => {
  class TTY extends EventEmitter { isTTY = true; isRaw = false; setRawMode(value) { this.isRaw = value; } resume() {} pause() {} }
  const input = new TTY(); let output = '';
  const stream = { write(value) { output += value; } };
  const entered = readTerminalInput('API key', { secret: true, input, output: stream });
  input.emit('data', Buffer.from('sk-secret-fixture\r')); assert.equal(await entered, 'sk-secret-fixture');
  assert.equal(output.includes('sk-secret-fixture'), false); assert.equal(input.isRaw, false);
  const cancelled = readTerminalInput('API key', { secret: true, input, output: stream });
  input.emit('data', Buffer.from('sk-cancel-fixture\u0003'));
  await assert.rejects(cancelled, /取消/); assert.equal(input.isRaw, false); assert.equal(output.includes('sk-cancel-fixture'), false);
});

test('bundle caches stay outside signed resources and profile creation never copies account data', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'f-bundle-path-'));
  try {
    const paths = runtimePaths.paths({ F_DISTRIBUTION: 'dmg', F_USER_DATA_DIRECTORY: path.join(home, 'data') }, home);
    assert.equal(paths.cache, path.join(home, 'Library/Caches/F'));
    assert.equal(paths.auth, path.join(home, 'data/agent/auth.json'));
    const directory = profiles.ensureProfile('cbi', { paths });
    const product = JSON.parse(await readFile(path.join(directory, 'product.json'), 'utf8'));
    assert.equal(product.authentication.id, 'fy-pi-cbi'); assert.equal(product.auth, undefined);
    assert.equal((await stat(path.join(directory, 'product.json'))).mode & 0o777, 0o600);
    await writeFile(path.join(directory, 'product.json'), '{"custom":true}');
    profiles.ensureProfile('cbi', { paths });
    assert.deepEqual(JSON.parse(await readFile(path.join(directory, 'product.json'), 'utf8')), { custom: true });
  } finally { await rm(home, { recursive: true }); }
});
