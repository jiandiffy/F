import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createKernel } from '../src/core/kernel.mjs';
import { mountAIOS } from '../../../packages/agent-bus/agent/index.mjs';

function host() {
 const tools=new Map(),listeners=new Map();let active=[];
 return {tools,listeners,entries:[],registerTool(t){tools.set(t.name,t);active.push(t.name);},getAllTools:()=>[...tools.values()],getActiveTools:()=>active,setActiveTools(names){active=names;},on(event,fn){const list=listeners.get(event)??new Set();list.add(fn);listeners.set(event,list);return()=>list.delete(fn);},appendEntry(type,value){this.entries.push({type,value});},async emit(name,event,context){const values=[];for(const fn of listeners.get(name)??[])values.push(await fn(event,context));return values;}};
}
async function fixture(t,options={}) {
 const directory=await mkdtemp(path.join(os.tmpdir(),'f-bus-'));const pi=host(),ctx=createKernel(pi);
 await ctx.plugin({name:'fixture-tools',inject:['tools'],apply(ctx){
 ctx.tools.register({name:'read',description:'read file',execute:async()=>({})});
 ctx.tools.register({name:'whiteboard_read',description:'read board',execute:async()=>({})});
 }});
 await mountAIOS(ctx,{dataRoot:directory,...options});
 const context={cwd:directory,sessionManager:{getSessionId:()=> 'one'}};
 t.after(async()=>{await ctx.fiber.dispose();await rm(directory,{recursive:true,force:true});});return{pi,ctx,context,directory};
}

test('bus hides optional schemas until activation, enforces execution, and persists per session',async t=>{
 const {pi,ctx,context}=await fixture(t);await pi.emit('before_agent_start',{},context);
 assert.ok(pi.getActiveTools().includes('bus'));assert.ok(!pi.getActiveTools().includes('whiteboard_read'));
 await assert.rejects(async()=>pi.tools.get('whiteboard_read').execute('',{},null,null,context),/Activate/);
 const list=await pi.tools.get('bus').execute('',{action:'list'},null,null,context);assert.equal(list.details.find(x=>x.name==='whiteboard').active,false);
 await pi.tools.get('bus').execute('',{action:'activate',names:['whiteboard']},null,null,context);
 await pi.tools.get('whiteboard_read').execute('',{},null,null,context);
 const other={...context,sessionManager:{getSessionId:()=> 'two'}};await pi.emit('before_agent_start',{},other);assert.ok(!pi.getActiveTools().includes('whiteboard_read'));
 await pi.emit('before_agent_start',{},context);assert.ok(pi.getActiveTools().includes('whiteboard_read'));
 assert.ok(ctx.bus.events.length);
});

test('plugin capability metadata overrides SDK summaries without duplicate groups',async t=>{
 const {pi,ctx,context}=await fixture(t);
 await ctx.plugin({name:'fixture-capabilities',inject:['tools'],apply(ctx){
  for(const [name,group] of [['dataset','datasets'],['project_version','versions']])
   ctx.tools.register({name,description:name,capability:{name:group,description:group},execute:async()=>({})});
 }});
 pi.getAllTools=()=>[...pi.tools.values()].map(({name,description})=>({name,description}));
 const catalog=await ctx.bus.sync(context);
 assert.equal(catalog.some(group=>['dataset','project_version'].includes(group.name)),false);
 assert.deepEqual(catalog.find(group=>group.name==='datasets').tools,['dataset']);
 assert.deepEqual(catalog.find(group=>group.name==='versions').tools,['project_version']);
 assert.equal(catalog.find(group=>group.name==='core').tools.filter(name=>name==='read').length,1);
 await ctx.bus.choose(context,['datasets'],true);
 assert.ok(pi.getActiveTools().includes('dataset'));
 assert.equal(pi.getActiveTools().includes('project_version'),false);
});

test('only actual user input can approve current revisions, and successful unslop result gates prose completion',async t=>{
 const {pi,context}=await fixture(t);const tool=pi.tools.get('goal_flow');
 let goal=(await tool.execute('',{action:'begin',goal:'摘要',complexity:'simple',artifact:'prose'},null,null,context)).details;
 await assert.rejects(tool.execute('',{action:'approve'},null,null,context),/Unsupported/);
 await assert.rejects(tool.execute('',{action:'delivered',report:'已完成'},null,null,context),/unslop/);
 await pi.emit('tool_result',{toolName:'skill',input:{name:'unslop'},isError:true},context);
 await assert.rejects(tool.execute('',{action:'delivered',report:'已完成'},null,null,context),/unslop/);
 await pi.emit('tool_result',{toolName:'skill',input:{name:'unslop'},isError:false},context);
 goal=(await tool.execute('',{action:'delivered',report:'已完成'},null,null,context)).details;assert.equal(goal.phase,'complete');
 const ignored=await pi.emit('input',{source:'extension',text:'/goal approve '+goal.id+' 1'},context);assert.ok(ignored.every(x=>!x));
});

test('child agents and explicit tool subsets receive no recursive goal orchestration instructions',async t=>{
 const original=process.env.F_AGENT_DEPTH;process.env.F_AGENT_DEPTH='1';
 let child;
 try{child=await fixture(t);assert.equal(child.pi.tools.has('goal_flow'),false);const prompt=await child.ctx.systemPrompt.assemble({systemPrompt:''},child.context);assert.ok(!prompt.includes('先 goal_flow begin'));assert.match(prompt,/只完成当前分工/);}
 finally{if(original===undefined)delete process.env.F_AGENT_DEPTH;else process.env.F_AGENT_DEPTH=original;}
 const parent=await fixture(t);parent.pi.setActiveTools(['read','whiteboard_read']);
 const prompt=await parent.ctx.systemPrompt.assemble({systemPrompt:''},parent.context);assert.ok(!prompt.includes('先 goal_flow begin'));
});

test('disabling goal flow retains bus and resource reservations',async t=>{
 const {pi,context}=await fixture(t,{enabled:false});assert.ok(pi.tools.has('bus'));assert.ok(pi.tools.has('resource_scope'));assert.ok(!pi.tools.has('goal_flow'));
 const lease=(await pi.tools.get('resource_scope').execute('',{action:'claim',paths:['source'],purpose:'test'},null,null,context)).details;
 await pi.tools.get('resource_scope').execute('',{action:'release',leaseId:lease.id},null,null,context);
});

test('file gates pin active edits and sandbox shell writes to the owned scope',async t=>{
 const {pi,context,directory}=await fixture(t);const resource=pi.tools.get('resource_scope');
 const scope=(await resource.execute('',{action:'claim',paths:['owned.txt']},null,null,context)).details;
 const edit={toolName:'write',toolCallId:'edit-1',input:{path:'owned.txt'}};
 assert.ok((await pi.emit('tool_call',edit,context)).every(v=>!v?.block));
 await assert.rejects(resource.execute('',{action:'release',leaseId:scope.id},null,null,context),/in-flight/);
 await pi.emit('tool_execution_end',{toolCallId:'edit-1'},context);
 const bash={toolName:'bash',toolCallId:'shell-1',input:{command:'printf allowed > owned.txt; printf denied > other.txt'}};
 const outcome=await pi.emit('tool_call',bash,context);
 if(outcome.some(v=>v?.block)) { await resource.execute('',{action:'release',leaseId:scope.id},null,null,context);return; }
 await assert.rejects(resource.execute('',{action:'release',leaseId:scope.id},null,null,context),/in-flight/);
 const {execFile}=await import('node:child_process');const {promisify}=await import('node:util');const {readFile}=await import('node:fs/promises');
 await assert.rejects(promisify(execFile)('/bin/bash',['-c',bash.input.command],{cwd:directory}),/not permitted|Permission denied/);
 assert.equal(await readFile(path.join(directory,'owned.txt'),'utf8'),'allowed');
 await assert.rejects(readFile(path.join(directory,'other.txt')),/ENOENT/);
 await pi.emit('tool_execution_end',{toolCallId:'shell-1'},context);await resource.execute('',{action:'release',leaseId:scope.id},null,null,context);
});

test('missing branch assignment or corrupt workflow state blocks mutations instead of losing the guard',async t=>{
 const {pi,ctx,context,directory}=await fixture(t),file=path.join(directory,'workflow.json');
 await writeFile(file,JSON.stringify({version:2,goals:[],selected:null}));
 const environment={F_WORKFLOW_STATE_FILE:file,F_WORKFLOW_ROLE:'experiment',F_AGENT_ID:'unassigned',F_WORKFLOW_CANDIDATE:'unknown'},saved=Object.fromEntries(Object.keys(environment).map(k=>[k,process.env[k]]));
 try{
  Object.assign(process.env,environment);
  for(const toolName of ['write','edit','bash'])assert.ok((await pi.emit('tool_call',{toolName,input:{path:'source.txt',command:'true'}},context)).some(v=>v?.block&&/not assigned/.test(v.reason)));
  for(const[k,v]of Object.entries(saved)){if(v===undefined)delete process.env[k];else process.env[k]=v;}
  await writeFile(ctx.goalStates(context).file,'{invalid state');
  assert.ok((await pi.emit('tool_call',{toolName:'write',input:{path:'source.txt'}},context)).some(v=>v?.block));
 }finally{for(const[k,v]of Object.entries(saved)){if(v===undefined)delete process.env[k];else process.env[k]=v;}}
});
