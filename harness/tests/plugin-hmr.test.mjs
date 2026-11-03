import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { digest, counterSource } from './hmr-fixture.mjs';
import { createKernel } from '../src/core/kernel.mjs';
import { mountPluginHmr } from '../src/core/plugin-hmr.mjs';

async function setup(t) {
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'f-hmr-unit-'));
  const listeners = new Map(), tools = new Map(), active = new Set(), commands = new Map(), journal = [];
  const pi = {
    tools, active, commands, journal,
    getActiveTools: () => [...active],
    setActiveTools(names) { active.clear(); for (const name of names) if (tools.get(name)?.exposure !== 'hidden') active.add(name); },
    registerTool(definition) { tools.set(definition.name, definition); if (definition.exposure === 'hidden') active.delete(definition.name); else active.add(definition.name); },
    registerCommand(name, definition) { commands.set(name, definition); },
    appendEntry(type, value) { journal.push({type, value}); },
    on(name, fn) { const set = listeners.get(name) ?? new Set(); listeners.set(name, set); set.add(fn); return () => set.delete(fn); },
  };
  const ctx = createKernel(pi);
  await mountPluginHmr(ctx);
  const context = {cwd, isIdle: () => true, ui: {notify() {}}};
  const candidate = async (source, id = 'counter') => {
    const dir = path.join(cwd, '.f/plugins', id);
    await mkdir(dir, {recursive:true});
    const sha = digest(source), file = path.join(dir, sha + '.mjs');
    await writeFile(file, source);
    return {file, sha};
  };
  t.after(async () => { delete globalThis.__fHmrHold; await ctx.fiber.dispose(); await rm(cwd, {recursive:true,force:true}); });
  return {cwd, ctx, pi, context, candidate, manager:ctx.pluginHmr, listeners};
}

test('HMR unloads old scope, tests only the candidate, preserves state and hides removed tools', async t => {
  const {manager, candidate, context, pi, ctx, listeners} = await setup(t);
  const unrelated = await ctx.plugin({name:'unrelated',inject:['systemPrompt'],apply(scope){scope.systemPrompt.register('unrelated',()=> 'kept');}});
  const first = await candidate(counterSource('v1'));
  const loaded = await manager.load('counter', first.file, first.sha, context);
  assert.equal(loaded.state, 'accepted');
  assert.equal((await pi.tools.get('hmr_counter_echo').execute('live',{message:'user'})).details.count, 1, 'self-test mutations must not leak into live state');
  const second = await candidate(counterSource('v2'));
  await manager.load('counter', second.file, second.sha, context);
  const value = await pi.tools.get('hmr_counter_echo').execute('live',{message:'next'});
  assert.equal(value.content[0].text, 'v2:next');
  assert.equal(value.details.count, 2, 'previous snapshot must survive, without counting candidate acceptance');
  assert.equal((await ctx.systemPrompt.assemble({systemPrompt:'base'},context)), 'base\n\nkept\n\nv2');
  assert.equal(ctx.get('hmr.counter.value').version, 'v2');
  assert.equal(listeners.get('agent_settled').size, 1);
  assert.equal(manager.status()[0].tests[0].passed, true);
  assert.equal((await manager.load('counter', second.file, second.sha, context)).state, 'unchanged');
  await manager.unload('counter', context);
  assert.equal(pi.tools.get('hmr_counter_echo').exposure, 'hidden');
  assert.ok(!pi.active.has('hmr_counter_echo'));
  assert.throws(() => pi.tools.get('hmr_counter_echo').execute('x',{}), /unloaded/);
  assert.equal(ctx.get('hmr.counter.value'), undefined);
  assert.equal(listeners.get('agent_settled').size, 0);
  assert.deepEqual([...ctx.systemPrompt.sections.keys()], ['unrelated']);
  await unrelated.dispose();
});

test('failed candidate mount/test/empty acceptance rolls back old implementation and state', async t => {
  const {manager, candidate, context, pi} = await setup(t);
  const first = await candidate(counterSource('stable'));
  await manager.load('counter', first.file, first.sha, context);
  await pi.tools.get('hmr_counter_echo').execute('live',{message:'before'});
  for (const failure of ['apply-failure', 'test-failure', 'empty-tests']) {
    const next = await candidate(counterSource('broken-' + failure, failure));
    await assert.rejects(manager.load('counter', next.file, next.sha, context));
    assert.equal(manager.status()[0].sha256, first.sha);
    assert.equal(manager.status()[0].state, 'active');
    assert.match((await pi.tools.get('hmr_counter_echo').execute('live',{message:'after'})).content[0].text, /^stable:/);
  }
  assert.ok(pi.journal.some(entry => entry.value.state === 'rejected'));
});

test('HMR rejects busy work and concurrent transactions without stopping tools', async t => {
  const {manager, candidate, context, pi} = await setup(t);
  const first = await candidate(counterSource('v1'));
  await manager.load('counter', first.file, first.sha, context);
  const next = await candidate(counterSource('v2'));
  await assert.rejects(manager.load('counter', next.file, next.sha, {...context,isIdle:()=>false}), /idle/);
  let release;
  globalThis.__fHmrHold = new Promise(resolve => {release = resolve;});
  const running = pi.tools.get('hmr_counter_echo').execute('live',{message:'held'});
  assert.equal(manager.status()[0].activeCalls, 1);
  await assert.rejects(manager.load('counter', next.file, next.sha, context), /running/);
  await assert.rejects(manager.unload('counter', context), /running/);
  release(); await running; delete globalThis.__fHmrHold;
  const loading = manager.load('counter', next.file, next.sha, context);
  await assert.rejects(manager.unload('counter', context), /transaction/);
  await loading;
  assert.equal(manager.status()[0].sha256, next.sha);
});

test('hash/path/import/schema/ownership validation never replaces a valid live plugin', async t => {
  const {manager, candidate, context, pi, cwd} = await setup(t);
  const first = await candidate(counterSource('stable'));
  await manager.load('counter', first.file, first.sha, context);
  await assert.rejects(manager.load('counter', first.file, '0'.repeat(64), context), /SHA256/);
  const outside = path.join(cwd, 'outside.mjs'); await writeFile(outside, counterSource('outside'));
  await assert.rejects(manager.load('counter', outside, digest(counterSource('outside')), context), /under/);
  const alias = path.join(cwd, '.f/plugins/counter/alias.mjs'); await symlink(outside, alias);
  await assert.rejects(manager.load('counter', alias, digest(counterSource('outside')), context), /under/);
  const imports = await candidate("import fs from 'node:fs';\n" + counterSource('imported'));
  await assert.rejects(manager.load('counter', imports.file, imports.sha, context), /self-contained/);
  const wrongID = await candidate(counterSource('wrong').replace("id: 'counter'", "id: 'different'"));
  await assert.rejects(manager.load('counter', wrongID.file, wrongID.sha, context), /must export/);
  const wrongTool = await candidate(counterSource('collision').replace("name:'hmr_counter_echo'", "name:'write'"));
  await assert.rejects(manager.load('counter', wrongTool.file, wrongTool.sha, context), /Tool names/);
  assert.equal(manager.status()[0].sha256, first.sha);
  assert.match((await pi.tools.get('hmr_counter_echo').execute('live',{message:'ok'})).content[0].text, /^stable:/);
});

test('cleanup failure quarantines the changed plugin instead of loading over live resources', async t => {
  const {manager, candidate, context, pi} = await setup(t);
  const marker = '__hmr_cleanup_' + randomUUID().replaceAll('-','');
  globalThis[marker] = false;
  t.after(()=>delete globalThis[marker]);
  const code = counterSource('v1').replace('api.effect(() => () => {});', `api.effect(() => () => { if (globalThis[${JSON.stringify(marker)}]) throw new Error('cleanup refused'); });`);
  const first = await candidate(code); await manager.load('counter', first.file, first.sha, context);
  globalThis[marker] = true;
  const next = await candidate(counterSource('v2'));
  await assert.rejects(manager.load('counter', next.file, next.sha, context), /cleanup failed/);
  assert.equal(manager.status()[0].state, 'disabled');
  assert.ok(!pi.active.has('hmr_counter_echo'));
  assert.equal(manager.status()[0].sha256, first.sha);
  // Cleanup errors are explicit on teardown; this test has already proved the refusal.
  manager.records.get('counter').cleanupError = undefined;
});

test('accepted code is the exact tested instance, without a hidden second apply', async t => {
  const {manager,candidate,context,pi} = await setup(t);
  const source = `let mounts=0;
export default {apiVersion:1,id:'counter',
 apply(api) { mounts++; api.tools.register({name:'hmr_counter_echo',label:'Mount probe',description:'Mount probe',
 parameters:{type:'object',properties:{},additionalProperties:false},
 async execute(){return {content:[{type:'text',text:String(mounts)}],details:{mounts}};}}); },
 async test(t){const r=await t.invoke('hmr_counter_echo',{});t.assert(r.details.mounts===1);return [{name:'first-mount',passed:true}];}
};`;
  const next = await candidate(source);
  await manager.load('counter',next.file,next.sha,context);
  assert.equal((await pi.tools.get('hmr_counter_echo').execute('live',{})).details.mounts,1);
});

test('queued work cannot enter api.track during asynchronous teardown', async t => {
  const {manager,candidate,context,pi} = await setup(t);
  const key='__hmr_async_' + randomUUID().replaceAll('-','');
  let release;
  const fixture = {block:false,api:undefined,entered:false,finished:false,gate:new Promise(resolve=>{release=resolve;})};
  globalThis[key]=fixture;
  t.after(()=>{release();delete globalThis[key];});
  const source = counterSource('old').replace('api.effect(() => () => {});',
    `globalThis[${JSON.stringify(key)}].api=api; api.effect(() => async () => { const f=globalThis[${JSON.stringify(key)}]; if(f.block){f.entered=true;await f.gate;f.finished=true;} });`);
  const first = await candidate(source); await manager.load('counter',first.file,first.sha,context);
  fixture.block=true;
  const next=await candidate(counterSource('new'));
  const loading=manager.load('counter',next.file,next.sha,context);
  while(!fixture.entered) await new Promise(resolve=>setImmediate(resolve));
  let ran=false;
  await assert.rejects(fixture.api.track(async()=>{ran=true;}),/stopping/);
  assert.equal(ran,false);
  assert.equal(manager.status()[0].state,'disabled');
  assert.equal(fixture.finished,false);
  release(); await loading;
  assert.equal(fixture.finished,true);
  assert.equal((await pi.tools.get('hmr_counter_echo').execute('live',{message:'ok'})).content[0].text,'new:ok');
});

test('a caught failing assertion still rejects acceptance and restores the old plugin', async t => {
  const {manager,candidate,context,pi}=await setup(t);
  const first=await candidate(counterSource('stable'));await manager.load('counter',first.file,first.sha,context);
  const source=counterSource('bad').replace("return [{name:'echo-version',passed:true}];", "try { t.assert(false, 'swallowed failure'); } catch {} return [{name:'claimed-pass',passed:true}];");
  const bad=await candidate(source);
  await assert.rejects(manager.load('counter',bad.file,bad.sha,context),/assertion failed.*swallowed failure/);
  assert.equal(manager.status()[0].sha256,first.sha);
  assert.equal((await pi.tools.get('hmr_counter_echo').execute('live',{message:'ok'})).content[0].text,'stable:ok');
});

test('unfinished acceptance is quarantined and its temporary directory survives until safe unload', async t => {
  const {manager,candidate,context}=await setup(t);
  const key='__hmr_pending_' + randomUUID().replaceAll('-','');
  let release;
  globalThis[key]={api:undefined,gate:new Promise(resolve=>{release=resolve;})};
  const source=counterSource('pending')
    .replace('api.effect(() => () => {});', `globalThis[${JSON.stringify(key)}].api=api; api.effect(() => () => {});`)
    .replace("return [{name:'echo-version',passed:true}];", `void globalThis[${JSON.stringify(key)}].api.track(()=>globalThis[${JSON.stringify(key)}].gate); return [{name:'echo-version',passed:true}];`);
  try {
    const next=await candidate(source);
    await assert.rejects(manager.load('counter',next.file,next.sha,context),/left plugin work running/);
    const status=manager.status()[0];
    assert.equal(status.state,'disabled');assert.equal(status.activeCalls,1);
    assert.ok(status.acceptanceDirectory);
    const {access}=await import('node:fs/promises');await access(status.acceptanceDirectory);
    release();await new Promise(resolve=>setImmediate(resolve));
    await manager.unload('counter',context);
    await assert.rejects(access(status.acceptanceDirectory));
  } finally {release();delete globalThis[key];}
});

test('a rejected colliding namespace cannot hide another plugin\'s registered tool', async t => {
  const {manager,candidate,context,pi}=await setup(t);
  const first=await candidate(counterSource('owner').replaceAll('hmr_counter_echo','hmr_counter_two_echo'));
  await manager.load('counter',first.file,first.sha,context);
  const second=await candidate(counterSource('collision').replace("id: 'counter'", "id: 'counter-two'").replaceAll('hmr_counter_echo','hmr_counter_two_echo'),'counter-two');
  await assert.rejects(manager.load('counter-two',second.file,second.sha,context),/Duplicate tool/);
  assert.ok(pi.active.has('hmr_counter_two_echo'));
  assert.equal((await pi.tools.get('hmr_counter_two_echo').execute('live',{message:'ok'})).content[0].text,'owner:ok');
  assert.equal(manager.status().length,1);
});
