import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createKernel } from '../src/core/kernel.mjs';
import { mountAIOS } from '../src/aios/index.mjs';
import { GoalState } from '../src/aios/state.mjs';
import { leasesFor } from '../src/aios/leases.mjs';
import { DatasetStore } from '../src/datasets/store.mjs';
import { command, parseArxiv } from '../src/datasets/providers.mjs';
import whiteboard from '../../pi/agent/modules/fy-whiteboard.ts';

async function temporary(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'f-aios-adversarial-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}
function host() {
  const tools = new Map(), listeners = new Map(); let active = [];
  return { tools, registerTool(tool) {
      tools.set(tool.name, tool);
      if (tool.exposure === 'hidden') active = active.filter(name => name !== tool.name);
      else if (tool.defaultActive !== false && !['codemode', 'deferred'].includes(tool.exposure)) active = [...new Set([...active, tool.name])];
    },
    getAllTools: () => [...tools.values()], getActiveTools: () => active,
    setActiveTools(names) { active = [...new Set(names)].filter(name => tools.has(name) && tools.get(name).exposure !== 'hidden'); }, appendEntry() {},
    on(event, fn) { const list = listeners.get(event) ?? new Set(); list.add(fn); listeners.set(event, list); return () => list.delete(fn); },
    async emit(event, payload, context) { const values = []; for (const listener of listeners.get(event) ?? []) values.push(await listener(payload, context)); return values; },
  };
}

// Exercise the installed SDK's loadout/transcript and execution adapters. Only
// the model stream is local; no provider, network request or app update is used.
async function sdkFixture(t, { tools } = {}) {
  const { createAgentSession, ModelRuntime, DefaultResourceLoader, SettingsManager, SessionManager } = await import('../../pi/node_modules/@earendil-works/pi-coding-agent/dist/index.js');
  const { getModel } = await import('../../pi/node_modules/@earendil-works/pi-ai/dist/compat.js');
  const { createAssistantMessageEventStream } = await import('../../pi/node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js');
  const { getCurrentTools } = await import('../../pi/node_modules/@earendil-works/pi-ai/dist/utils/transcript.js');
  const cwd = await temporary(t), agentDir = path.join(cwd, 'agent'); await mkdir(agentDir);
  const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false }, cacheWarming: 'off' });
  let kernel, session, plugin, nextCall, executed = 0, calls = 0;
  const declarations = [];
  t.after(async () => { session?.dispose(); await kernel?.fiber.dispose(); });
  const resources = new DefaultResourceLoader({ cwd, agentDir, settingsManager: settings,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true,
    extensionFactories: [async pi => {
      kernel = createKernel(pi);
      plugin = await kernel.plugin({ name: 'sdk-probe', inject: ['tools'], apply(ctx) {
        ctx.tools.register({ name: 'sdk_optional', label: 'SDK probe', description: 'Optional SDK probe',
          parameters: { type: 'object', properties: { private_schema_marker: { type: 'string' } }, additionalProperties: false },
          async execute() { executed++; return { content: [{ type: 'text', text: 'executed' }], details: { executed } }; } });
      } });
      await mountAIOS(kernel, { dataRoot: path.join(cwd, 'bus'), enabled: false });
    }],
  });
  await resources.reload();
  const modelRuntime = await ModelRuntime.create({ authPath: path.join(agentDir, 'auth.json'), modelsPath: path.join(agentDir, 'models.json') });
  await modelRuntime.setRuntimeApiKey('anthropic', 'local-test-not-a-real-key');
  const model = getModel('anthropic', 'claude-sonnet-4-5');
  ({ session } = await createAgentSession({ cwd, agentDir, model, modelRuntime, resourceLoader: resources, tools,
    sessionManager: SessionManager.inMemory(cwd), settingsManager: settings }));
  await session.bindExtensions({});
  const stream = (_model, context) => {
    declarations.push(structuredClone(getCurrentTools(context.messages)));
    const call = nextCall; nextCall = undefined; calls++;
    const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
      content: call ? [{ type: 'toolCall', id: `sdk-bus-${calls}`, name: call.name, arguments: call.args }] : [{ type: 'text', text: 'done' }],
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: call ? 'toolUse' : 'stop', timestamp: Date.now() };
    const output = createAssistantMessageEventStream(); output.push({ type: 'done', reason: message.stopReason, message }); output.end(); return output;
  };
  session.agent.streamFunction = stream; modelRuntime.streamSimple = stream;
  return { session, kernel, plugin, declarations, count: () => executed,
    async prompt(name, args = {}) { nextCall = name ? { name, args } : undefined; await session.prompt('Exercise the local capability fixture.'); },
    lastResult: name => session.messages.filter(message => message.role === 'toolResult' && message.toolName === name).at(-1),
  };
}

test('real SDK sends optional schemas only after bus activation and rejects calls after deactivation', async t => {
  const { session, declarations, prompt, lastResult, count } = await sdkFixture(t);
  await prompt();
  assert.equal(session.getActiveToolNames().includes('sdk_optional'), false);
  assert.equal(session.getCallableToolNames().includes('sdk_optional'), false);
  assert.equal(JSON.stringify(declarations.at(-1)).includes('private_schema_marker'), false);
  await prompt('sdk_optional');
  assert.equal(lastResult('sdk_optional').isError, true);
  assert.equal(count(), 0);
  await prompt('bus', { action: 'activate', names: ['sdk_optional'] });
  assert.equal(lastResult('bus').isError, false);
  assert.ok(declarations.at(-1).some(tool => tool.name === 'sdk_optional' && tool.parameters.properties.private_schema_marker));
  await prompt('sdk_optional');
  assert.equal(lastResult('sdk_optional').isError, false);
  assert.equal(count(), 1);
  await prompt('bus', { action: 'deactivate', names: ['sdk_optional'] });
  assert.equal(lastResult('bus').isError, false);
  assert.equal(session.getCallableToolNames().includes('sdk_optional'), false);
  assert.equal(declarations.at(-1).some(tool => tool.name === 'sdk_optional'), false);
  await prompt('sdk_optional');
  assert.equal(lastResult('sdk_optional').isError, true);
  assert.equal(count(), 1);
});

test('real SDK dynamic registration and unload do not re-expose optional schemas', async t => {
  const { session, kernel, plugin, declarations, prompt, count } = await sdkFixture(t);
  await prompt();
  await t.test('late registration stays inactive', async () => {
    await kernel.plugin({ name: 'sdk-late', inject: ['tools'], apply(ctx) {
      ctx.tools.register({ name: 'sdk_late', label: 'Late probe', description: 'Late optional probe',
        parameters: { type: 'object', properties: {}, additionalProperties: false },
        async execute() { return { content: [{ type: 'text', text: 'late' }] }; } });
    } });
    assert.equal(session.getActiveToolNames().includes('sdk_late'), false, 'The SDK must not automatically activate a newly mounted optional tool');
    assert.equal(session.getCallableToolNames().includes('sdk_late'), false);
  });
  await t.test('unloaded tool stays absent from the next model request', async () => {
    await prompt('bus', { action: 'activate', names: ['sdk_optional'] });
    await plugin.dispose();
    await prompt();
    assert.equal(declarations.at(-1).some(tool => tool.name === 'sdk_optional'), false);
    assert.equal(session.getCallableToolNames().includes('sdk_optional'), false);
    await prompt('sdk_optional');
    assert.equal(count(), 0);
  });
});

test('real SDK explicit allowlist cannot reactivate a disabled capability during tool registration', async t => {
  const originalArgv = [...process.argv]; process.argv.push('--tools=bus,sdk_optional,sdk_late');
  t.after(() => process.argv.splice(0, process.argv.length, ...originalArgv));
  const { session, kernel, prompt } = await sdkFixture(t, { tools: ['bus', 'sdk_optional', 'sdk_late'] });
  await prompt('bus', { action: 'activate', names: ['sdk_optional'] });
  assert.ok(session.getActiveToolNames().includes('sdk_optional'));
  await prompt('bus', { action: 'deactivate', names: ['sdk_optional'] });
  assert.equal(session.getActiveToolNames().includes('sdk_optional'), false);
  await kernel.plugin({ name: 'sdk-allowlist-late', inject: ['tools'], apply(ctx) {
    ctx.tools.register({ name: 'sdk_late', label: 'Late probe', description: 'Late optional probe',
      parameters: { type: 'object', properties: {}, additionalProperties: false },
      async execute() { return { content: [{ type: 'text', text: 'late' }] }; } });
  } });
  assert.equal(session.getActiveToolNames().includes('sdk_optional'), false, 'Refreshing the host registry must not reactivate a disabled capability');
  assert.equal(session.getCallableToolNames().includes('sdk_optional'), false);
  assert.equal(session.getActiveToolNames().includes('sdk_late'), false);
});

test('deactivation really revokes execution for an explicitly allowed optional tool', async t => {
  const directory = await temporary(t), pi = host(), kernel = createKernel(pi);
  const originalArgv = [...process.argv]; process.argv.push('--tools=bus,whiteboard_read');
  t.after(async () => { process.argv.splice(0, process.argv.length, ...originalArgv); await kernel.fiber.dispose(); });
  await kernel.plugin({ name: 'optional-fixture', inject: ['tools'], apply(ctx) { ctx.tools.register({ name: 'whiteboard_read', description: 'Optional board', execute: async () => ({}) }); } });
  await mountAIOS(kernel, { dataRoot: directory });
  const context = { cwd: directory, sessionManager: { getSessionId: () => 'explicit-tools' } };
  await pi.emit('before_agent_start', {}, context);
  await pi.tools.get('bus').execute('', { action: 'activate', names: ['whiteboard'] }, null, null, context);
  assert.ok(pi.getActiveTools().includes('whiteboard_read'));
  await pi.tools.get('whiteboard_read').execute('', {}, null, null, context);
  await pi.tools.get('bus').execute('', { action: 'deactivate', names: ['whiteboard'] }, null, null, context);
  assert.equal(pi.getActiveTools().includes('whiteboard_read'), false);
  await assert.rejects(async () => pi.tools.get('whiteboard_read').execute('', {}, null, null, context), /Activate/);
});

test('newly mounted optional tools stay gated before capability activation', async t => {
  const directory = await temporary(t), pi = host(), kernel = createKernel(pi);
  t.after(() => kernel.fiber.dispose());
  await mountAIOS(kernel, { dataRoot: directory });
  const context = { cwd: directory, sessionManager: { getSessionId: () => 'dynamic-tools' } };
  await pi.emit('before_agent_start', {}, context);
  await kernel.plugin({ name: 'late-fixture', inject: ['tools'], apply(ctx) { ctx.tools.register({ name: 'late_optional', description: 'Late optional tool', execute: async () => ({}) }); } });
  assert.equal(pi.getActiveTools().includes('late_optional'), false, 'A new optional tool must not expose its schema before activation');
  await assert.rejects(async () => pi.tools.get('late_optional').execute('', {}, null, null, context), /Activate/);
});

test('unloaded tools disappear from the capability catalog and remain uncallable', async t => {
  const directory = await temporary(t), pi = host(), kernel = createKernel(pi);
  t.after(() => kernel.fiber.dispose());
  const plugin = await kernel.plugin({ name: 'late-fixture', inject: ['tools'], apply(ctx) { ctx.tools.register({ name: 'late_optional', description: 'Late optional tool', execute: async () => ({}) }); } });
  await mountAIOS(kernel, { dataRoot: directory });
  const context = { cwd: directory, sessionManager: { getSessionId: () => 'unloaded-tools' } };
  await pi.emit('before_agent_start', {}, context);
  await kernel.bus.choose(context, ['late_optional'], true);
  await pi.tools.get('late_optional').execute('', {}, null, null, context);
  await plugin.dispose();
  const catalog = await kernel.bus.sync(context);
  assert.equal(catalog.some(group => group.tools.includes('late_optional')), false);
  assert.equal(pi.getActiveTools().includes('late_optional'), false);
  await assert.rejects(async () => pi.tools.get('late_optional').execute('', {}, null, null, context), /unloaded/);
});

test('same-revision concurrent board edits have one winner for 40 rounds and preserve the other lease', async t => {
  const directory = await temporary(t), saved = process.env.F_BOARD_DIR;
  process.env.F_BOARD_DIR = directory;
  t.after(() => { if (saved === undefined) delete process.env.F_BOARD_DIR; else process.env.F_BOARD_DIR = saved; });
  const registered = new Map(); whiteboard({ registerTool: tool => registered.set(tool.name, tool) });
  const context = id => ({ cwd: directory, sessionManager: { getSessionId: () => id } });
  const call = (name, params, ctx) => registered.get(name).execute('', params, undefined, undefined, ctx);
  const left = context('left'), right = context('right');
  const a = await leasesFor(left).claim({ owner: 'left', rectangle: { x: 0, y: 0, width: 900, height: 900 } });
  const b = await leasesFor(right).claim({ owner: 'right', rectangle: { x: 1000, y: 0, width: 900, height: 900 } });
  await call('whiteboard_create', { lease_id: a.id, nodes: [{ id: 'left', label: 'L' }] }, left);
  await call('whiteboard_create', { lease_id: b.id, nodes: [{ id: 'right', label: 'R' }] }, right);
  const file = path.join(directory, 'scene.json');
  for (let round = 0; round < 40; round++) {
    const before = JSON.parse(await readFile(file, 'utf8'));
    const results = await Promise.allSettled([
      call('whiteboard_edit', { lease_id: a.id, expected_revision: before.revision, operations: [{ op: 'update_node', id: 'left', label: `L${round}` }] }, left),
      call('whiteboard_edit', { lease_id: b.id, expected_revision: before.revision, operations: [{ op: 'update_node', id: 'right', label: `R${round}` }] }, right),
    ]);
    assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
    assert.match(results.find(result => result.status === 'rejected').reason.message, /revision changed/);
    const after = JSON.parse(await readFile(file, 'utf8'));
    assert.equal(after.revision, before.revision + 1);
    const loser = results[0].status === 'rejected' ? 'left' : 'right';
    assert.deepEqual(after.elements.filter(e => e.customData?.fwb?.id === loser), before.elements.filter(e => e.customData?.fwb?.id === loser));
  }
});

test('eight independent Node processes preserve all 120 board writes under disjoint leases', async t => {
  const directory = await temporary(t), saved = process.env.F_BOARD_DIR;
  process.env.F_BOARD_DIR = directory;
  t.after(() => { if (saved === undefined) delete process.env.F_BOARD_DIR; else process.env.F_BOARD_DIR = saved; });
  const moduleURL = new URL('../../pi/agent/modules/fy-whiteboard.ts', import.meta.url).href;
  const entries = [];
  for (let index = 0; index < 8; index++) {
    const owner = `process-${index}`, context = { cwd: directory, sessionManager: { getSessionId: () => owner } };
    const lease = await leasesFor(context).claim({ owner, rectangle: { x: index * 1000, y: 0, width: 900, height: 900 } });
    entries.push({ owner, lease });
  }
  await Promise.all(entries.map(({ owner, lease }) => {
    const source = `import extension from ${JSON.stringify(moduleURL)};
      const tools=new Map();extension({registerTool:t=>tools.set(t.name,t)});
      const ctx={cwd:${JSON.stringify(directory)},sessionManager:{getSessionId:()=>${JSON.stringify(owner)}}};
      await tools.get('whiteboard_create').execute('',{lease_id:${JSON.stringify(lease.id)},nodes:[{id:${JSON.stringify(owner)},label:'initial'}]},undefined,undefined,ctx);
      for(let i=1;i<15;i++)await tools.get('whiteboard_edit').execute('',{lease_id:${JSON.stringify(lease.id)},operations:[{op:'update_node',id:${JSON.stringify(owner)},label:'round-'+i}]},undefined,undefined,ctx);`;
    return command(process.execPath, ['--input-type=module', '-e', source], { env: { ...process.env, F_AGENT_ID: owner } });
  }));
  const scene = JSON.parse(await readFile(path.join(directory, 'scene.json'), 'utf8'));
  assert.equal(scene.revision, 120);
  const nodes = scene.elements.filter(element => element.customData?.fwb?.kind === 'node');
  assert.equal(nodes.length, 8);
  for (const { owner } of entries) assert.equal(nodes.find(element => element.customData.fwb.id === owner)?.customData.fwb.label, 'round-14');
});

test('256 seeded random node moves reject out-of-lease mutations without changing the scene', async t => {
  const directory = await temporary(t), saved = process.env.F_BOARD_DIR;
  process.env.F_BOARD_DIR = directory;
  t.after(() => { if (saved === undefined) delete process.env.F_BOARD_DIR; else process.env.F_BOARD_DIR = saved; });
  const tools = new Map(); whiteboard({ registerTool: tool => tools.set(tool.name, tool) });
  const context = { cwd: directory, sessionManager: { getSessionId: () => 'random-owner' } };
  const lease = await leasesFor(context).claim({ owner: 'random-owner', rectangle: { x: 0, y: 0, width: 900, height: 900 } });
  await tools.get('whiteboard_create').execute('', { lease_id: lease.id, nodes: [{ id: 'probe', label: 'Probe' }] }, undefined, undefined, context);
  const file = path.join(directory, 'scene.json'); let seed = 0x5eed1234;
  const random = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return (seed >>> 0) / 0x100000000; };
  for (let round = 0; round < 256; round++) {
    const before = await readFile(file, 'utf8'), scene = JSON.parse(before);
    const node = scene.elements.find(element => element.customData?.fwb?.kind === 'node');
    const x = Math.floor(random() * 1400) - 200, y = Math.floor(random() * 1400) - 200;
    const within = x >= 0 && y >= 0 && x + node.width <= 900 && y + node.height <= 900;
    const move = tools.get('whiteboard_edit').execute('', { lease_id: lease.id, expected_revision: scene.revision, operations: [{ op: 'move_node', id: 'probe', x, y }] }, undefined, undefined, context);
    if (within) {
      await move;
      const after = JSON.parse(await readFile(file, 'utf8'));
      assert.equal(after.revision, scene.revision + 1);
    } else {
      await assert.rejects(move, /reserved rectangle/);
      assert.equal(await readFile(file, 'utf8'), before, `Seed 0x5eed1234 round ${round} must be atomic`);
    }
  }
});

test('all 27 staged selection combinations enforce unique candidates and reject 100 stale approvals', async t => {
  const directory = await temporary(t), ids = ['a', 'b', 'c'];
  for (let n = 0; n < 27; n++) {
    const store = new GoalState({ directory, sessionId: `vote-${n}` });
    const goal = await store.begin({ goal: 'Boundary test', complexity: 'complex', baseline:{id:'original',publication:{repository:'fixture/private'}} });
    const picks = [n % 3, Math.floor(n / 3) % 3, Math.floor(n / 9) % 3];
    await store.update(goal.id,'planning',g=>{g.phase='selection';g.revision=1;g.stageIndex=0;g.approvedTree={children:[{},{}]};g.stages=[{candidates:ids.map(id=>({phase:'candidate',version:{id},publication:{commit:'fixed'}}))}];});
    const request={id:goal.id,revision:1,decision:'select',selections:picks.map(i=>ids[i])};
    if(new Set(picks).size<3)await assert.rejects(store.review(request),/Select/);
    else assert.equal((await store.review(request)).phase,'proposing');
    if (n === 0) for (let revision = 2; revision < 102; revision++) await assert.rejects(store.review({ id: goal.id, revision, decision: 'approve' }), /stale/);
  }
});

test('paper evidence rejects a bare URL scheme before it can influence ranking', async t => {
  const store = new DatasetStore(await temporary(t));
  const record = await store.put({ dataset: 'paper', title: 'Paper', source: { url: 'https://arxiv.org/abs/2601.00001' } });
  for (const url of ['https://', 'http://', 'https:///']) await assert.rejects(store.evidence(record.id, { kind: 'performance', summary: 'Evidence', url, score: 1 }), /source|URL|evidence/i);
  assert.deepEqual((await store.get(record.id)).evidence, []);
});

test('arXiv CDATA retains scientific inequalities and literal type notation', () => {
  const [paper] = parseArxiv('<feed><entry><id>http://arxiv.org/abs/2601.00001</id><title>Math</title><summary><![CDATA[constraint x < y and A<T>; score > 0]]></summary></entry></feed>');
  assert.equal(paper.summary, 'constraint x < y and A<T>; score > 0');
});
