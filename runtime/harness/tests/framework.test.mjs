import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, realpath, rename, symlink, lstat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { WorkspaceStore } from '../../../packages/data-base/agent/workspaces.mjs';
import { TaskScheduler } from '../../../packages/task-scheduler/agent/index.mjs';
import { Checkpoints } from '../../checkpoints/index.mjs';
import { workflowPlan, workflowNames } from '../../../workflows/catalog.mjs';
import { providerProfiles } from '../../../auth/providers.mjs';
import { loadProfile } from '../src/profile.mjs';
import { createKernel } from '../src/core/kernel.mjs';
import { mountComputerUse } from '../../../packages/computer-use/agent/index.mjs';
import mcp from '../../agent/adapters/fy-mcp.ts';
import { McpClient, StdioTransport } from '../../agent/node_modules/@earendil-works/pi-mcp/dist/index.js';
import { DatabaseSync } from 'node:sqlite';
import { privatePath } from '../../../packages/versions/agent/secrets.mjs';

async function fixture(t) { const directory = await realpath(await mkdtemp(path.join(os.tmpdir(), 'f-framework-'))); t.after(() => rm(directory, { recursive: true, force: true })); return directory; }

test('workspace identity survives renames of display names and isolates sessions without copying legacy data', async t => {
  const dir = await fixture(t), a = path.join(dir, 'a'), b = path.join(dir, 'b'); await mkdir(a); await mkdir(b);
  const store = new WorkspaceStore(path.join(dir, 'F_data'));
  const first = await store.register(a, { id: 'workspace-F', name: 'F' });
  const again = await store.register(a, { name: 'renamed' }); assert.equal(again.id, first.id);
  const second = await store.register(b); assert.notEqual(first.id, second.id);
  const history = path.join(dir, 'original.jsonl'), board = path.join(dir, 'legacy-board'); await writeFile(history, 'original'); await mkdir(board);
  await writeFile(path.join(board, 'scene.json'), '{"elements":[]}');
  const session = await store.session(first, { id: 'session-001', history, board });
  await writeFile(path.join(session, 'conversation.jsonl'), 'same history'); assert.equal(await readFile(history, 'utf8'), 'same history');
  assert.equal(await realpath(path.join(session, 'session_apps/excalidraw')), board);
  await assert.rejects(store.register(b, { id: 'workspace-F' }), /identity/);
  await assert.rejects(store.session(first, { id: '../escape' }), /Invalid/);
  const foreign = path.join(dir, 'foreign.jsonl'); await writeFile(foreign, 'keep');
  await assert.rejects(store.session(first, { id: 'session-001', history: foreign }), /conflicts/);
  assert.equal(await readFile(foreign, 'utf8'), 'keep');
  const moved = path.join(dir, 'a-renamed'); await rename(a, moved);
  assert.equal((await store.register(moved)).id, first.id);
  const checkpoints = new Checkpoints(path.join(first.directory, 'state.db'));
  checkpoints.save('draft', { text: '中文\nline', queue: ['one', 'two'] });
  assert.deepEqual(new Checkpoints(checkpoints.file).load('draft'), { text: '中文\nline', queue: ['one', 'two'] });
  assert.equal(checkpoints.load('missing'), null);
  await writeFile(path.join(store.directory, 'index.json'), '[]');
  await assert.rejects(store.register(moved), /Invalid workspace index/);
  assert.equal(await readFile(path.join(store.directory, 'index.json'), 'utf8'), '[]');
});

test('workspace history survives runtime relocation and removal of the legacy alias without copying', async t => {
  const dir = await fixture(t), old = path.join(dir, 'legacy-agent'), state = path.join(dir, 'F-state');
  await mkdir(old);
  const history = path.join(old, 'session.jsonl'); await writeFile(history, 'retained history');
  const store = new WorkspaceStore(path.join(dir, 'F_data')), workspace = await store.register(dir);
  const session = await store.session(workspace, { id: 'history', history });
  const pending = await store.session(workspace, { id: 'pending', history: path.join(old, 'pending.jsonl') });
  await rename(old, state); await symlink(state, old);
  await store.session(workspace, { id: 'history', history });
  await store.session(workspace, { id: 'pending', history: path.join(old, 'pending.jsonl') });
  await rm(old);
  assert.equal(await readFile(path.join(session, 'conversation.jsonl'), 'utf8'), 'retained history');
  await writeFile(path.join(pending, 'conversation.jsonl'), 'first pending turn');
  assert.equal(await readFile(path.join(state, 'pending.jsonl'), 'utf8'), 'first pending turn');
  const db = new DatabaseSync(path.join(workspace.directory, 'state.db'));
  try { assert.equal(db.prepare('SELECT history FROM sessions WHERE id=?').get('history').history, path.join(state, 'session.jsonl')); }
  finally { db.close(); }
});

test('two scheduler processes claim a real command once, retain failure evidence, and cancel an active child', async t => {
  const dir = await fixture(t), output = path.join(dir, 'count');
  const a = new TaskScheduler(dir), b = new TaskScheduler(dir);
  const job = await a.add({ title: 'once', at: new Date(0).toISOString(), argv: [process.execPath, '-e', `require('fs').appendFileSync(${JSON.stringify(output)},'x')`], cwd: dir });
  await Promise.all([a.tick(), b.tick()]); assert.equal(await readFile(output, 'utf8'), 'x');
  assert.equal((await a.list()).find(t => t.id === job.id).status, 'completed');
  const failed = await a.add({ title: 'failure', at: new Date(0).toISOString(), argv: [process.execPath, '-e', 'process.exit(7)'], cwd: dir });
  await a.tick(); assert.equal((await a.list()).find(t => t.id === failed.id).status, 'failed');
  const long = await a.add({ title: 'cancel', at: new Date(0).toISOString(), argv: [process.execPath, '-e', 'setTimeout(()=>{},60000)'], cwd: dir });
  const run = a.tick();
  const deadline = Date.now() + 5000;
  while (!a.active.has(long.id)) { if (Date.now() > deadline) throw Error('scheduler did not start'); await new Promise(resolve => setTimeout(resolve, 10)); }
  await a.cancel(long.id); await run;
  assert.equal((await a.list()).find(t => t.id === long.id).status, 'cancelled'); assert.equal(a.active.size, 0);
  await assert.rejects(a.add({ title: 'bad', at: 'invalid', argv: [], cwd: dir }), /Task needs/);
  await writeFile(a.file, '{}'); await assert.rejects(a.list(), /Invalid task database/);
  assert.equal(await readFile(a.file, 'utf8'), '{}');
});

test('profiles, provider mapping and every workflow template load their actual configuration', async () => {
  const root = path.resolve(import.meta.dirname, '../../..');
  for (const id of ['base', 'gui', 'cli']) assert.equal((await loadProfile(root, id)).id, id);
  await assert.rejects(loadProfile(root, '../../outside'), /Unknown/);
  assert.deepEqual((await providerProfiles()).map(p => p.provider), ['dp', 'gpt', 'cbc', 'cbi']);
  for (const name of workflowNames) { const plan = await workflowPlan(name); assert.equal(plan.id, name); assert.equal(plan.children.length, 3); }
  await assert.rejects(workflowPlan('../other'), /Unknown/);
});

test('publication excludes relocated session state, login data and downloaded runtime while retaining F adapters', () => {
  for (const file of ['runtime/agent/state/settings.json', 'runtime/agent/state/sessions/history.jsonl', 'runtime/agent/codebuddy/cbi/session.json', 'runtime/node/bin/node']) assert.equal(privatePath(file), true, file);
  for (const file of ['runtime/agent/extensions/fy-harness.ts', 'runtime/agent/providers/cbi/src/config.ts']) assert.equal(privatePath(file), false, file);
});

test('desktop tool returns real image bytes, cleans temporary captures and reverses registration', async t => {
  const tools = new Map(); const pi = { registerTool: tool => tools.set(tool.name, tool), getActiveTools: () => [], setActiveTools() {} };
  const ctx = createKernel(pi); let capture;
  await mountComputerUse(ctx, { async request(input) { if (input.action === 'screenshot') { capture = input.path; await writeFile(capture, Buffer.from([137,80,78,71])); return {}; } return { accessibility: false }; } });
  const tool = tools.get('computer_use');
  assert.equal((await tool.execute('', { action: 'state' })).details.accessibility, false);
  assert.equal((await tool.execute('', { action: 'screenshot' })).content[0].data, Buffer.from([137,80,78,71]).toString('base64'));
  await assert.rejects(readFile(capture), /ENOENT/); await ctx.fiber.dispose();
  await assert.rejects(async () => tool.execute('', { action: 'state' }), /unloaded/);
});

test('MCP adapter registers only enabled servers and releases them with its Cordis scope', async t => {
  const dir = await fixture(t), file = path.join(dir, 'servers.json'), saved = process.env.F_MCP_CONFIG;
  process.env.F_MCP_CONFIG = file;
  t.after(() => { if (saved === undefined) delete process.env.F_MCP_CONFIG; else process.env.F_MCP_CONFIG = saved; });
  await writeFile(file, JSON.stringify({ mcpServers: { fixture: { enabled: true, command: process.execPath, args: ['fixture.mjs'] }, disabled: { enabled: false, command: 'never-start' } } }));
  const registered = new Map();
  const ctx = createKernel({ registerMcpServer: (name, value) => registered.set(name, value), unregisterMcpServer: name => registered.delete(name), registerTool() {}, getActiveTools: () => [], setActiveTools() {} });
  await ctx.plugin({ name: 'mcp-acceptance', inject: ['host'], apply(scope) { return mcp(scope.host.adapter(scope)); } });
  assert.deepEqual([...registered.keys()], ['fixture']); assert.equal(registered.get('fixture').command, process.execPath);
  await ctx.fiber.dispose(); assert.equal(registered.size, 0);
});

test('existing MCP client negotiates a real stdio child and calls its discovered tool', async t => {
  const directory = await fixture(t), server = path.join(directory, 'server.mjs');
  await writeFile(server, `import {createInterface} from 'node:readline';
const lines=createInterface({input:process.stdin});
lines.on('line',line=>{const m=JSON.parse(line);if(m.id===undefined)return;let result;
if(m.method==='initialize')result={protocolVersion:'2025-11-25',capabilities:{tools:{}},serverInfo:{name:'F-fixture',version:'1'}};
else if(m.method==='tools/list')result={tools:[{name:'echo',description:'Fixture echo',inputSchema:{type:'object',properties:{text:{type:'string'}},required:['text']}}]};
else if(m.method==='tools/call')result={content:[{type:'text',text:m.params.arguments.text}]};else result={};
process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n');});lines.on('close',()=>process.exit(0));`);
  const client = new McpClient({ name: 'F-acceptance', version: '2' });
  try {
    await client.connect(new StdioTransport({ command: process.execPath, args: [server] }));
    assert.equal((await client.listTools())[0].name, 'echo');
    assert.equal((await client.callTool('echo', { text: '真实 stdio 工具链' })).content[0].text, '真实 stdio 工具链');
  } finally { await client.close(); }
});

test('signed resource freeze preserves one module identity and removes every compatibility symlink', async t => {
  const dir = await fixture(t), resources = path.join(dir, 'Resources');
  const source = path.join(resources, 'runtime/harness/src'), canonical = path.join(resources, 'packages/fixture/agent');
  await mkdir(source, { recursive: true }); await mkdir(canonical, { recursive: true });
  await writeFile(path.join(canonical, 'index.mjs'), 'export const identity = {};');
  await symlink('../../../packages/fixture/agent', path.join(source, 'fixture'));
  const freeze = path.resolve(import.meta.dirname, '../../../ui/desktop/scripts/freeze-agent.py');
  execFileSync('/usr/bin/python3', [freeze, resources]);
  assert.equal((await lstat(path.join(source, 'fixture'))).isSymbolicLink(), false);
  const legacy = await import('file://' + path.join(source, 'fixture/index.mjs'));
  const current = await import('file://' + path.join(canonical, 'index.mjs'));
  assert.equal(legacy.identity, current.identity);
  await symlink(dir, path.join(resources, 'outside'));
  assert.throws(() => execFileSync('/usr/bin/python3', [freeze, resources], { stdio: 'pipe' }), /Command failed/);
});
