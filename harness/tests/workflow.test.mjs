import test from 'node:test';
import assert from 'node:assert/strict';
import { FWorkflowEngine } from '../src/workflow/engine.mjs';
import { setup } from './helpers.mjs';

async function fixture(){const t=await setup();await t.ctx.plugin({name:'test-workflow',inject:['subagents'],apply(ctx){new FWorkflowEngine(ctx);}});return t;}
const request=(parent,script,extra={})=>({parent,script,meta:{name:'test',description:'test workflow'},...extra});

test('real DSH workflow helpers fan out, pipeline, structured output and caller-only delivery',async()=>{
 const t=await fixture();try{
  const events=[];t.ctx.on('workflow/phase',e=>events.push(e.value));
  const run=t.ctx.workflowEngine.start(request(t.parent('a'),`phase('research');log('start');
const rows=await parallel([()=>agent('one'),()=>agent('two')]);
const pipe=await pipeline([1,2],n=>n+1,n=>n*2);
const structured=await agent('json',{schema:{type:'object',properties:{count:{type:'integer'}},required:['count']}});
return {rows,pipe,structured,input:args.input};`,{args:{input:'ok'}}));
  const value=await run.result;assert.equal(value.stopReason,'completed');
  assert.deepEqual(value.value,{rows:['one','two'],pipe:[4,6],structured:{count:2},input:'ok'});
  assert.equal(value.agentsStarted,3);assert.equal(t.delivered.length,0);assert.deepEqual(events,['research']);
  assert.equal(t.ctx.subagents.active.size,0);await run.dispose();
 }finally{await t.cleanup();}
});

test('parse, metadata, non-JSON and cooperative caps fail truthfully',async()=>{
 const t=await fixture();try{
  const p=t.parent('a'),engine=t.ctx.workflowEngine;
  assert.throws(()=>engine.start(request(p,'return {',{})));
  assert.throws(()=>engine.start(request(p,'return 1',{meta:{name:'bad'}})),/meta/);
  const bad=await engine.start(request(p,'return {bad:NaN}')).result;assert.equal(bad.stopReason,'error');
  engine.limits.maxTotalAgents=1;
  const cap=await engine.start(request(p,"await agent('a');await agent('b');return 'bad'")).result;assert.equal(cap.stopReason,'error');
  assert.equal(t.ctx.subagents.active.size,0);
 }finally{await t.cleanup();}
});

test('cancel stops a hung VM and its owned children, including dropped promises',async()=>{
 const t=await fixture();try{
  const controller=new AbortController();
  const run=t.ctx.workflowEngine.start(request(t.parent('a'),"await agent('hang');return 'bad'",{signal:controller.signal}));
  setTimeout(()=>controller.abort(),100);
  assert.equal((await run.result).stopReason,'cancelled');assert.equal(t.ctx.subagents.active.size,0);
  const dropped=t.ctx.workflowEngine.start(request(t.parent('a'),"agent('hang');return 'done'"));
  assert.equal((await dropped.result).stopReason,'completed');assert.equal(t.ctx.subagents.active.size,0);
  const loop=t.ctx.workflowEngine.start(request(t.parent('a'),'await Promise.resolve();while(true){}'));
  setTimeout(()=>loop.cancel(),100);assert.equal((await loop.result).stopReason,'cancelled');
 }finally{await t.cleanup();}
});

test('workflow separates remote effective cwd from local process transport cwd',async()=>{
 const t=await fixture();try{
  const parent={...t.parent('remote'),cwd:'/only-on-remote/project',executionCwd:t.root,effectiveCwd:'/only-on-remote/project'};
  assert.equal((await t.ctx.workflowEngine.start(request(parent,"return 'transport-ok'")).result).value,'transport-ok');
 }finally{await t.cleanup();}
});
