import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, realpathSync, linkSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { createKernel } from '../src/core/kernel.mjs';
import { mountMaintenance, guardedBash, publicationCommand, hasSandbox } from '../src/skills/maintenance.mjs';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const lockScript = path.join(repository, 'harness/src/skills/maintenance_lock.py');
const temporary = () => realpathSync(mkdtempSync(path.join(os.tmpdir(), 'f-maintenance-test-')));

// These tests never call prepare-update main, a build, a model or the real pending path.
test('Python lease, delegation, freeze, publication lock/digest/no-clobber unit tests', () => {
  const run = spawnSync('/usr/bin/python3', ['-B', path.join(repository, 'harness/tests/maintenance_lock_test.py')], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stderr, /Ran 11 tests/);
});

test('publisher shell escape is exactly one literal validated invocation', () => {
  const root = '/project/F';
  const command = "python3 gui-mac/scripts/prepare-update.py --announcement '保留原功能' --no-whiteboard";
  assert.match(guardedBash(command, root, { sandbox: false }), /^\/usr\/bin\/python3 -B /);
  for (const unsafe of [command + '; touch injected', command + '\nrm -rf x',
    'python3 other.py --announcement \'x\'', 'python3 gui-mac/scripts/prepare-update.py --announcement "$(touch injected)"',
    "python3 gui-mac/scripts/prepare-update.py --announcement 'x' --skip-tests"]) {
    assert.equal(publicationCommand(unsafe, root), undefined);
    assert.throws(() => guardedBash(unsafe, root, { sandbox: false }));
  }
  assert.throws(() => guardedBash(command, root, { sandbox: false, allowPublish: false }));
});

test('without sandbox only simple read-only inspection survives, not scripts or shell syntax', () => {
  assert.equal(guardedBash('ls -la harness/src', '/F', { sandbox: false }), '/bin/ls -la harness/src');
  assert.equal(guardedBash('pwd', '/F', { sandbox: false }), '/bin/pwd');
  for (const command of ['python3 script.py', 'ls; rm file', 'ls $(touch file)', 'find . -delete', 'rg --pre script x', 'pwd > file', 'ls\ntouch file'])
    assert.throws(() => guardedBash(command, '/F', { sandbox: false }));
});

test('real macOS sandbox prevents direct/indirect writes, deletes and hard-link bypass', { skip: !hasSandbox() }, () => {
  const dir = temporary(), root = path.join(dir, 'source'), outside = path.join(dir, 'outside');
  mkdirSync(root); mkdirSync(outside);
  writeFileSync(path.join(root, 'owned'), 'keep');
  const run = command => spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', guardedBash(command, root, { home: dir })], { encoding: 'utf8' });
  try {
    assert.equal(run(`ls '${root}'`).status, 0);
    assert.equal(run(`printf ok > '${outside}/test-output'`).status, 0);
    assert.equal(readFileSync(path.join(outside, 'test-output'), 'utf8'), 'ok');
    for (const command of [`printf bad > '${root}/owned'`, `rm '${root}/owned'`,
      `/usr/bin/python3 -c "open('${root}/owned', 'w').write('bad')"`,
      `ln '${root}/owned' '${outside}/alias' && printf bad > '${outside}/alias'`]) {
      assert.notEqual(run(command).status, 0, command);
      assert.equal(readFileSync(path.join(root, 'owned'), 'utf8'), 'keep');
    }
    const metadata = path.join(dir, 'Library/Application Support/F/maintenance/coordination');
    mkdirSync(metadata, { recursive: true }); writeFileSync(path.join(metadata, 'registry'), 'keep');
    assert.notEqual(run(`rm '${metadata}/registry'`).status, 0);
    assert.ok(existsSync(path.join(metadata, 'registry')));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('actual tool_call gate requires leases, pins full mutation, denies overlap and validates child ownership', async () => {
  const dir = temporary(), root = path.join(dir, 'source'), base = path.join(dir, 'coordination');
  mkdirSync(root);
  const saved = Object.fromEntries(['F_AGENT_ID', 'F_AGENT_DEPTH', 'F_REMOTE_PROJECT', 'F_UPDATE_DELEGATED'].map(k => [k, process.env[k]]));
  for (const k of Object.keys(saved)) delete process.env[k];
  // Real Python store, isolated outside user coordination metadata.
  const coordinator = (source, owner, action, args = {}) => {
    try {
      return JSON.parse(execFileSync('/usr/bin/python3', ['-B', '-c',
        'import runpy,json,sys; m=runpy.run_path(sys.argv[1]); print(json.dumps(m["Store"](sys.argv[2],sys.argv[3]).operate(sys.argv[4],sys.argv[5],json.loads(sys.argv[6]))))',
        lockScript, source, base, owner, action, JSON.stringify(args)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
    } catch (e) { throw new Error(String(e.stderr || e.message)); }
  };
  const listeners = new Map(), tools = new Map();
  const pi = { on(name, fn) { const set = listeners.get(name) ?? new Set(); set.add(fn); listeners.set(name, set); return () => set.delete(fn); },
    registerTool(tool) { tools.set(tool.name, tool); }, getActiveTools: () => [...tools.keys()], setActiveTools() {} };
  const ctx = createKernel(pi);
  const context = owner => ({ cwd: root, sessionManager: { getSessionId: () => owner } });
  const emit = async (name, event, context) => { for (const fn of listeners.get(name) ?? []) { const r = await fn(event, context); if (r?.block) return r; } };
  try {
    await mountMaintenance(ctx, { root, coordinator });
    assert.equal(tools.size, 0); // Does not change capability schemas in unrelated projects.
    await emit('before_agent_start', {}, context('one'));
    const scope = tools.get('maintenance_scope');
    const call = (owner, args) => scope.execute('scope', args, undefined, undefined, context(owner));
    const event = { toolName: 'write', toolCallId: 'write-1', input: { path: 'plugin/a', content: 'new' } };
    assert.equal((await emit('tool_call', event, context('one'))).block, true);
    await call('one', { action: 'claim', paths: ['plugin/a'] });
    await call('two', { action: 'claim', paths: ['plugin/b'] });
    await assert.rejects(call('two', { action: 'claim', paths: ['plugin/a'] }), /相交/);
    assert.equal(await emit('tool_call', event, context('one')), undefined);
    await assert.rejects(call('one', { action: 'release' }), /仍在执行/);
    assert.equal((await emit('tool_call', { toolName: 'edit', toolCallId: 'edit-other', input: { path: 'plugin/a' } }, context('two'))).block, true);
    await emit('tool_execution_end', { toolCallId: 'write-1' });
    await assert.rejects(call('one', { action: 'delegate', paths: ['plugin/a'], childId: 'unowned' }), /直接子代理/);
    ctx.provide('subagents', { listChildren: async () => [{ childId: 'child' }] });
    await call('one', { action: 'delegate', paths: ['plugin/a'], childId: 'child' });
    assert.equal((await emit('tool_call', event, context('one'))).block, true);
    assert.equal(await emit('tool_call', event, context('child')), undefined);
    await emit('tool_execution_end', { toolCallId: 'write-1' });
    await call('child', { action: 'release' });
    await call('one', { action: 'release' });
    await call('two', { action: 'release' });
    writeFileSync(path.join(root, 'linked'), 'keep');
    linkSync(path.join(root, 'linked'), path.join(dir, 'outside-hardlink'));
    assert.equal((await emit('tool_call', { toolName: 'write', toolCallId: 'hardlink-write', input: { path: path.join(dir, 'outside-hardlink') } }, context('one'))).block, true);
    const shell = { toolName: 'bash', input: { command: 'printf read-only' } };
    await emit('tool_call', shell, { ...context('one'), cwd: dir });
    if (hasSandbox()) assert.match(shell.input.command, /^\/usr\/bin\/sandbox-exec/);
  } finally {
    await ctx.fiber.dispose();
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    rmSync(dir, { recursive: true, force: true });
  }
});
