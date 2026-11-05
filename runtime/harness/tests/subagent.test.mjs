import test from 'node:test';
import assert from 'node:assert/strict';
import { setup } from './helpers.mjs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
const spec=(parent,prompt,extra={})=>({label:'test',provider:'spawn',signal:new AbortController().signal,delivery:'parent',request:{parent,prompt:[{type:'text',text:prompt}],...extra}});

test('every spawn and cold resume pins cbi flash medium and refuses model overrides',async()=>{
 const t=await setup();try{
  for(const agentOptions of [{provider:'cbc'},{model:'other'},{reasoningEffort:'high'}])await assert.rejects(t.ctx.subagents.startActivation(spec(t.parent('policy'),'x',{agentOptions})),/cbi/);
  const run=await t.ctx.subagents.startActivation(spec(t.parent('policy'),'hang'));
  const argv=t.ctx.subagents.active.get(run.childId).child.process.spawnargs.join(' ');
  assert.match(argv,/--provider cbi --model deepseek-v4\.1-flash --thinking medium/);
  await run.dispose();
  const resumed=await t.ctx.subagents.sendMessage(t.parent('policy'),run.childId,'resumed');const value=await resumed.result;
  assert.deepEqual(value.model,{provider:'cbi',model:'deepseek-v4.1-flash',reasoningEffort:'medium'});
 }finally{await t.cleanup();}
});

test('activation completes after teardown, durable owner catalog and cold resume',async()=>{
 const t=await setup();try{
  const p=t.parent('a'),other=t.parent('b'),run=await t.ctx.subagents.startActivation(spec(p,'hello'));
  const value=await run.result;assert.equal(value.stopReason,'completed');assert.equal(value.output[0].text,'hello');
  assert.equal(t.ctx.subagents.active.size,0);assert.equal(t.delivered.length,1);
  assert.equal((await t.ctx.subagents.listChildren(p))[0].state,'inactive');
  await assert.rejects(t.ctx.subagents.sendMessage(other,run.childId,'steal'),/owned/);
  const resumed=await t.ctx.subagents.sendMessage(p,run.childId,'resumed');assert.equal((await resumed.result).output[0].text,'resumed');
  await run.dispose();assert.equal(t.ctx.subagents.active.size,0);
 }finally{await t.cleanup();}
});

test('structured output, failure status, cancellation and pre-cancel leave no active work',async()=>{
 const t=await setup();try{
  const p=t.parent('a');
  const structured=await t.ctx.subagents.startActivation(spec(p,'schema',{outputSchema:{type:'object',properties:{count:{type:'integer'}},required:['count'],additionalProperties:false}}));
  assert.deepEqual((await structured.result).structured,{count:2});
  const schema={type:'object',properties:{count:{type:'integer'}},required:['count'],additionalProperties:false};
  const fenced=await t.ctx.subagents.startActivation(spec(p,'fenced',{outputSchema:schema}));assert.deepEqual((await fenced.result).structured,{count:2});
  const ambiguous=await t.ctx.subagents.startActivation(spec(p,'ambiguous',{outputSchema:schema}));assert.equal((await ambiguous.result).stopReason,'error');
  const wrongType=await t.ctx.subagents.startActivation(spec(p,'schema',{outputSchema:{...schema,properties:{count:{type:'string'}}}}));const rejected=await wrongType.result;assert.equal(rejected.stopReason,'error');assert.match(rejected.diagnostic,/count|string/);
  const failed=await t.ctx.subagents.startActivation(spec(p,'fail'));assert.equal((await failed.result).stopReason,'error');
  const controller=new AbortController(),hung=await t.ctx.subagents.startActivation({...spec(p,'hang'),signal:controller.signal});controller.abort();
  assert.equal((await hung.result).stopReason,'aborted');assert.equal(t.ctx.subagents.active.size,0);
  await assert.rejects(t.ctx.subagents.startActivation({...spec(p,'x'),signal:AbortSignal.abort()}));
  await assert.rejects(t.ctx.subagents.startActivation(spec(p,'x',{maxDepth:0})),/depth/);
 }finally{await t.cleanup();}
});

test('concurrent starts reserve capacity atomically and siblings stay independent',async()=>{
 const t=await setup();try{
  const p=t.parent('a');
  // Keep the cancelled child pending explicitly; a timer may expire during sibling startup under load.
  const runs=await Promise.allSettled(Array.from({length:8},(_,i)=>t.ctx.subagents.startActivation(spec(p,i===0?'hang':'hello'))));
  assert.equal(runs.filter(r=>r.status==='fulfilled').length,4);
  const accepted=runs.filter(r=>r.status==='fulfilled').map(r=>r.value);
  await accepted[0].dispose();
  const values=await Promise.all(accepted.map(r=>r.result));
  assert.equal(values[0].stopReason,'aborted');
  assert.ok(values.slice(1).every(v=>v.output[0].text==='hello'));
  assert.equal(values.filter(v=>v.stopReason==='completed').length,3);assert.equal(t.ctx.subagents.active.size,0);
 }finally{await t.cleanup();}
});

test('remote execution uses the local transport directory while retaining remote child cwd',async()=>{
 const t=await setup(),oldRemote=process.env.F_REMOTE_PROJECT,oldLocal=process.env.F_LOCAL_PROJECT;
 process.env.F_REMOTE_PROJECT=JSON.stringify({cwd:'/only-on-remote/workspace',arguments:[],endpoint:'test'});process.env.F_LOCAL_PROJECT=t.root;
 try{
  const p=t.parent('remote');p.cwd='/only-on-remote/workspace';
  const run=await t.ctx.subagents.startActivation(spec(p,'remote-ok'));
  assert.equal((await run.result).stopReason,'completed');
  const catalog=await t.ctx.subagents.listChildren(p);assert.equal(catalog[0].cwd,'/only-on-remote/workspace');assert.equal('sessionFile' in catalog[0],false);
 }finally{
  if(oldRemote===undefined)delete process.env.F_REMOTE_PROJECT;else process.env.F_REMOTE_PROJECT=oldRemote;
  if(oldLocal===undefined)delete process.env.F_LOCAL_PROJECT;else process.env.F_LOCAL_PROJECT=oldLocal;
  await t.cleanup();
 }
});

test('a proposer moves to its experiment branch without losing its session identity or history',async()=>{
 const t=await setup();try{
  const parent=t.parent('relocation'),run=await t.ctx.subagents.startActivation(spec(parent,'proposal'));
  await run.result;
  const entry=(await t.ctx.subagents.catalog(parent))[0],history='{"type":"message","id":"earlier-direction","message":{"role":"assistant","content":[]}}\n';
  await writeFile(entry.sessionFile,JSON.stringify({type:'session',version:3,id:run.childId,cwd:t.root})+'\n'+history);
  const branch=path.join(t.root,'experiment');await mkdir(branch);
  const resumed=await t.ctx.subagents.startActivation({...spec(parent,'experiment',{cwd:branch,execution:{role:'experiment'}}),childId:run.childId});
  await resumed.result;
  const saved=await readFile(entry.sessionFile,'utf8'),newline=saved.indexOf('\n'),header=JSON.parse(saved.slice(0,newline));
  assert.equal(header.id,run.childId);assert.equal(header.cwd,branch);assert.equal(saved.slice(newline+1),history);
  assert.equal((await t.ctx.subagents.listChildren(parent))[0].cwd,branch);
 }finally{await t.cleanup();}
});
