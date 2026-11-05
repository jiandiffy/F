import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink, realpath } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { createKernel } from '../src/core/kernel.mjs';
import { mountMaintenance, maintenanceSourceContext, maintenanceShellGuard, hasSandbox } from '../src/skills/maintenance.mjs';
import { mountAIOS } from '../../../packages/agent-bus/agent/index.mjs';

async function fixture(t) {
 const directory=await realpath(await mkdtemp(path.join(os.tmpdir(),'f-combined-gates-'))),root=path.join(directory,'F'),project=path.join(directory,'other'),board=path.join(directory,'board');
 await Promise.all([mkdir(root),mkdir(project),mkdir(board)]);const prior=process.env.F_BOARD_DIR;process.env.F_BOARD_DIR=board;
 const tools=new Map(),listeners=new Map();let active=[];
 const pi={registerTool(tool){tools.set(tool.name,tool);active.push(tool.name);},getAllTools:()=>[...tools.values()],getActiveTools:()=>active,setActiveTools(names){active=names;},appendEntry(){},on(name,fn){const set=listeners.get(name)??new Set();set.add(fn);listeners.set(name,set);return()=>set.delete(fn);}};
 const kernel=createKernel(pi),calls=[];
 await mountMaintenance(kernel,{root,coordinator:(_root,owner,action,args)=>{calls.push({owner,action,args});return{token:'test-pin'};}});
 await mountAIOS(kernel,{dataRoot:path.join(directory,'states')});
 const context=cwd=>({cwd,sessionManager:{getSessionId:()=> 'combined'}});
 const emit=async(name,event,ctx)=>{for(const fn of listeners.get(name)??[]){const result=await fn(event,ctx);if(result?.block)return result;}};
 t.after(async()=>{await kernel.fiber.dispose();if(prior===undefined)delete process.env.F_BOARD_DIR;else process.env.F_BOARD_DIR=prior;await rm(directory,{recursive:true,force:true});});
 return{directory,root,project,tools,context,emit,calls};
}
test('combined maintenance and AIOS hooks use one real sandbox and preserve both project and source scopes',{skip:!hasSandbox()},async t=>{
 const f=await fixture(t);await writeFile(path.join(f.root,'protected'),'keep');
 for(const project of [f.root,f.project]){
  const ctx=f.context(project),lease=(await f.tools.get('resource_scope').execute('',{action:'claim',paths:['owned']},null,null,ctx)).details;
  const commands=[[`cat '${f.root}/protected'; printf verified > '${f.directory}/test-output'`,true],[`printf denied > '${f.root}/protected'`,false],["printf allowed > owned",project!==f.root],["printf denied > other",false]];
  for(const [command,success] of commands){
   const event={toolName:'bash',toolCallId:command,input:{command,maintenanceGuard:true}};
   assert.equal(maintenanceShellGuard(event),undefined);assert.equal(await f.emit('tool_call',event,ctx),undefined);
   assert.equal(event.input.command.split('/usr/bin/sandbox-exec').length-1,1);
   const result=spawnSync('/bin/bash',['--noprofile','--norc','-c',event.input.command],{cwd:project,encoding:'utf8'});assert.equal(result.status===0,success,result.stderr);
   event.input.command='printf tampered';assert.equal(maintenanceShellGuard(event),undefined);
   await f.emit('tool_execution_end',{toolCallId:command},ctx);
  }
  await f.tools.get('resource_scope').execute('',{action:'release',leaseId:lease.id},null,null,ctx);
 }
 assert.equal(await readFile(path.join(f.root,'protected'),'utf8'),'keep');assert.equal(await readFile(path.join(f.directory,'test-output'),'utf8'),'verified');
});
test('verified legacy symlink roots gain maintenance tools while edits still require canonical source paths',async t=>{
 const f=await fixture(t);await mkdir(path.join(f.root,'ui/desktop'),{recursive:true});await mkdir(path.join(f.root,'runtime/pi'),{recursive:true});await writeFile(path.join(f.root,'F_MAINTENANCE.md'),'rules');
 for(const [name,target] of [['gui-mac','ui/desktop'],['pi','runtime/pi'],['F_MAINTENANCE.md','F_MAINTENANCE.md']])await symlink(path.join(f.root,target),path.join(f.directory,name));
 assert.equal(maintenanceSourceContext(f.root,f.directory),true);assert.equal(maintenanceSourceContext(f.root,f.project),false);
 const ctx=f.context(f.directory);await f.emit('before_agent_start',{},ctx);
 await f.tools.get('maintenance_scope').execute('',{action:'claim',paths:['gui-mac']},null,null,ctx);assert.equal(f.calls.at(-1).action,'claim');
 assert.match((await f.emit('tool_call',{toolName:'write',toolCallId:'alias',input:{path:'gui-mac/new.swift'}},ctx)).reason,/符号链接/);
 assert.equal(await f.emit('tool_call',{toolName:'write',toolCallId:'canonical',input:{path:path.join(f.root,'ui/desktop/new.swift')}},ctx),undefined);await f.emit('tool_execution_end',{toolCallId:'canonical'},ctx);
});
