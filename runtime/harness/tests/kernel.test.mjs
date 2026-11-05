import test from 'node:test';
import assert from 'node:assert/strict';
import { Context, Service } from '../dist/upstream.mjs';
import { startHarness } from '../src/index.mjs';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

export function fakePi() {
  const listeners = new Map(), tools = new Map(), messages = [], entries = [];
  return { listeners, tools, messages, entries, getActiveTools: () => [...tools.keys()], setActiveTools() {},
    on(name, fn) { const set = listeners.get(name) ?? new Set(); set.add(fn); listeners.set(name,set); return () => set.delete(fn); },
    registerTool(t) { tools.set(t.name,t); }, sendMessage(m) { messages.push(m); }, appendEntry(type,data) { entries.push({type,data}); } };
}

test('upstream Cordis dependency suspension, remount and reverse disposal', async () => {
  const ctx = new Context(), events=[];
  const consumer = await ctx.plugin({ name:'consumer', inject:['testService'], apply(ctx) {
    ctx.effect(() => { events.push('start'); return () => events.push('stop'); });
  }});
  assert.deepEqual(events,[]);
  const provider = await ctx.plugin({ name:'provider', apply(ctx) { ctx.provide('testService', {}); }});
  await new Promise(resolve=>setImmediate(resolve)); assert.deepEqual(events,['start']);
  await provider.dispose(); assert.deepEqual(events,['start','stop']);
  const second=await ctx.plugin({name:'provider2',apply(ctx){ctx.provide('testService',{});}});
  await new Promise(resolve=>setImmediate(resolve)); assert.deepEqual(events,['start','stop','start']);
  await ctx.fiber.dispose(); assert.deepEqual(events,['start','stop','start','stop']);
});

test('F composition exposes plugin capabilities and bus, and unloads all subscriptions', async () => {
  const pi=fakePi(),ctx=await startHarness(pi,{dataRoot:'/tmp/f-harness-test'});
  try {
    assert.deepEqual([...pi.tools.keys()],['skill','subagent','list_agents','send_message','interrupt_agent','workflow','workflow_control','dataset','project_version','gmail','browser','task_scheduler','computer_use','bus','resource_scope','goal_flow']);
    assert.ok(ctx.skills && ctx.subagents && ctx.workflowEngine);
  } finally { await ctx.fiber.dispose(); }
  assert.equal(ctx.skills,undefined);assert.equal(ctx.subagents,undefined);
  assert.equal([...pi.listeners.values()].reduce((n,s)=>n+s.size,0),0);
  await assert.rejects(async () => pi.tools.get('list_agents').execute('',{},undefined,undefined,{}),/unloaded/);
});

test('skills: project rank, strict invocation policy, live body, add/delete and user load', async () => {
  const dir=await mkdtemp(path.join(os.tmpdir(),'f-skills-'));
  const root=path.join(dir,'project'); await mkdir(path.join(root,'.git'),{recursive:true});
  await mkdir(path.join(root,'.dsh/skills'),{recursive:true});
  const file=path.join(root,'.dsh/skills/f-plugins.md');
  await writeFile(file,'---\nname: f-plugins\ndescription: project rules\n---\nfirst body');
  const pi=fakePi(),ctx=await startHarness(pi,{dataRoot:path.join(dir,'data')});
  try {
    const skill=await ctx.skills.get('f-plugins',{cwd:root});
    assert.equal(skill.source,'project-dsh');assert.equal(skill.content.trim(),'first body');
    await writeFile(file,'---\nname: f-plugins\ndescription: project rules\n---\nchanged body');
    assert.equal((await ctx.skills.get('f-plugins',{cwd:root})).content.trim(),'changed body');
    await writeFile(path.join(root,'.dsh/skills/hidden.md'),'---\nname: hidden\ndescription: user only\ndisable-model-invocation: true\n---\nhidden body');
    ctx.refreshSkills();
    await assert.rejects(pi.tools.get('skill').execute('',{name:'hidden'},undefined,undefined,{cwd:root}),/unavailable/);
    const input=[...pi.listeners.get('input')][0];
    const transformed=await input({source:'rpc',text:'/hidden act'},{cwd:root});assert.match(transformed.text,/hidden body/);
    await writeFile(path.join(root,'.dsh/skills/invalid.md'),'---\nname: invalid\ndescription: bad\nuser-invocable: perhaps\n---\nbad');
    ctx.refreshSkills();assert.equal(await ctx.skills.get('invalid',{cwd:root}),undefined);
    await rm(file);ctx.refreshSkills();assert.equal((await ctx.skills.get('f-plugins',{cwd:root})).source,'bundled');
  } finally {await ctx.fiber.dispose();await rm(dir,{recursive:true,force:true});}
});

test('persisted capability switches remove schemas and dependency consumers', async () => {
  const old=process.env.F_DISABLED_PLUGINS;process.env.F_DISABLED_PLUGINS='skills,subagent,datasets,versions,aios,gmail,browser,task-scheduler,computer-use';
  let ctx;
  try {const pi=fakePi();ctx=await startHarness(pi);assert.deepEqual([...pi.tools.keys()],['bus','resource_scope']);assert.equal(ctx.subagents,undefined);assert.equal(ctx.workflowEngine,undefined);assert.ok(ctx.skills);}
  finally {await ctx?.fiber.dispose();if(old===undefined)delete process.env.F_DISABLED_PLUGINS;else process.env.F_DISABLED_PLUGINS=old;}
});

test('host model adapter initialization is awaited and provider registration reverses on unload',async()=>{
 const pi=fakePi(),providers=new Set();
 pi.registerProvider=provider=>providers.add(typeof provider==='string'?provider:provider.id);
 pi.unregisterProvider=id=>providers.delete(id);
 const ctx=await startHarness(pi,{adapters:[['probe-provider',async api=>{await Promise.resolve();api.registerProvider({id:'probe'});}]]});
 assert.ok(providers.has('probe'));await ctx.fiber.dispose();assert.equal(providers.size,0);
});
