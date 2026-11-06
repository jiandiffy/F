import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, mkdirSync, realpathSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createAgentSession, ModelRuntime, DefaultResourceLoader, SettingsManager, SessionManager } from '../../agent/node_modules/@earendil-works/pi-coding-agent/dist/index.js';
import { getModel } from '../../agent/node_modules/@earendil-works/pi-ai/dist/compat.js';
import { createAssistantMessageEventStream } from '../../agent/node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js';
import { createKernel } from '../src/core/kernel.mjs';
import { mountMaintenance } from '../src/skills/maintenance.mjs';

// Real installed Pi SDK + built-in write/bash tools. Only the model stream is a
// deterministic local stub: no network, credentials, app build or publication.
test('real SDK exposes dynamically registered scope tool, mutates executed bash args and forwards execution_end to unpin', async () => {
  const dir = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'f-maintenance-sdk-')));
  const root = path.join(dir, 'source'), agentDir = path.join(dir, 'agent'), base = path.join(dir, 'coordination');
  mkdirSync(root); mkdirSync(agentDir);
  const saved = Object.fromEntries(['F_AGENT_ID', 'F_AGENT_DEPTH', 'F_REMOTE_PROJECT', 'F_UPDATE_DELEGATED'].map(k => [k, process.env[k]]));
  for (const k of Object.keys(saved)) delete process.env[k];
  const lock = fileURLToPath(new URL('../src/skills/maintenance_lock.py', import.meta.url));
  const coordinator = (source, owner, action, args = {}) => {
    try {
      return JSON.parse(execFileSync('/usr/bin/python3', ['-B', '-c',
        'import runpy,json,sys; m=runpy.run_path(sys.argv[1]); print(json.dumps(m["Store"](sys.argv[2],sys.argv[3]).operate(sys.argv[4],sys.argv[5],json.loads(sys.argv[6]))))',
        lock, source, base, owner, action, JSON.stringify(args)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
    } catch (e) { throw new Error(String(e.stderr || e.message)); }
  };
  let session, kernel, calls = 0;
  const ends = [];
  try {
    const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false }, cacheWarming: 'off' });
    const resources = new DefaultResourceLoader({ cwd: root, agentDir, settingsManager: settings,
      noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true,
      extensionFactories: [async pi => {
        kernel = createKernel(pi);
        await mountMaintenance(kernel, { root, coordinator });
        pi.on('tool_execution_end', event => { ends.push(event.toolCallId); });
      }],
    });
    await resources.reload();
    const modelRuntime = await ModelRuntime.create({ authPath: path.join(agentDir, 'auth.json'), modelsPath: path.join(agentDir, 'models.json') });
    await modelRuntime.setRuntimeApiKey('anthropic', 'local-unit-test-not-a-real-key');
    const model = getModel('anthropic', 'claude-sonnet-4-5');
    ({ session } = await createAgentSession({ cwd: root, agentDir, model, modelRuntime, resourceLoader: resources,
      sessionManager: SessionManager.inMemory(root), settingsManager: settings }));
    await session.bindExtensions({});
    assert.ok(!session.getActiveToolNames().includes('maintenance_scope'));
    const plan = [
      ['maintenance_scope', { action: 'claim', paths: ['owned'] }],
      ['write', { path: 'owned/file.txt', content: 'authorized' }],
      ['edit', { path: 'owned/file.txt', edits: [{ oldText: 'authorized', newText: 'edited' }] }],
      ['edit', { path: 'owned/file.txt', edits: [{ oldText: 'missing-old-text', newText: 'no-change' }] }],
      ['write', { path: 'other/file.txt', content: 'unauthorized' }],
      ['bash', { command: `printf bypass > '${root}/owned/file.txt'` }],
      ['maintenance_scope', { action: 'release' }],
    ];
    const localStream = (_model, context) => {
      // This is the very first request, not a later round after tool registration.
      assert.ok(session.getActiveToolNames().includes('maintenance_scope'));
      assert.ok(context.messages.some(message => message.toolsAdded?.some(tool => tool.name === 'maintenance_scope')));
      const current = plan[calls++];
      const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
        content: current ? [{ type: 'toolCall', id: 'call-' + calls, name: current[0], arguments: current[1] }] : [{ type: 'text', text: 'done' }],
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: current ? 'toolUse' : 'stop', timestamp: Date.now() };
      const stream = createAssistantMessageEventStream();
      stream.push({ type: 'done', reason: message.stopReason, message });
      stream.end();
      return stream;
    };
    session.agent.streamFunction = localStream;
    modelRuntime.streamSimple = localStream; // Also guard the SDK default route: no network fallback.
    await session.prompt('Local maintenance gate integration test.');
    assert.equal(calls, 8, JSON.stringify(session.messages));
    assert.equal(readFileSync(path.join(root, 'owned/file.txt'), 'utf8'), 'edited');
    assert.equal(existsSync(path.join(root, 'other/file.txt')), false);
    const results = session.messages.filter(m => m.role === 'toolResult');
    assert.equal(results.length, 7);
    assert.equal(results[1].isError, false);
    assert.equal(results[2].isError, false); // In-scope native edit really ran.
    assert.equal(results[3].isError, true); // Native edit failure must also unpin.
    assert.equal(results[4].isError, true); // Scope gate refused out-of-range native write.
    assert.equal(results[5].isError, true); // Mutated native bash really ran the OS sandbox (or fail-closed fallback).
    assert.equal(results[6].isError, false); // Release succeeded after successful and failed native mutations.
    for (const id of ['call-2', 'call-3', 'call-4']) assert.ok(ends.includes(id));
    const owner = session.sessionManager.getSessionId();
    const state = coordinator(root, owner, 'status');
    assert.deepEqual(state.pins, {});
    assert.deepEqual(state.leases, {});
  } finally {
    session?.dispose();
    await kernel?.fiber.dispose();
    for (const [k, value] of Object.entries(saved)) { if (value === undefined) delete process.env[k]; else process.env[k] = value; }
    rmSync(dir, { recursive: true, force: true });
  }
});
