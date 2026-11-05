import { mkdtemp,writeFile,readFile,rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createKernel } from '../src/core/kernel.mjs';
import { mountAIOS } from '../../../packages/agent-bus/agent/index.mjs';
import { mountWorkflow } from '../../../workflows/engine/index.mjs';
import { WorkflowProject } from '../../../packages/versions/agent/workflow.mjs';
import { command } from '../../../packages/data-base/agent/providers.mjs';

export const tree={id:'root',title:'Experiment',objective:'Deliver verified independent branches',children:[{id:'one',title:'Stage one',objective:'Compare methods'},{id:'two',title:'Stage two',objective:'Improve selected methods'}]};
export async function workflowFixture(t) {
 const root=await mkdtemp(path.join(os.tmpdir(),'f-staged-workflow-')),project=path.join(root,'project'),remote=path.join(root,'remote.git');
 await command('mkdir',['-p',project]);await writeFile(path.join(project,'initial.txt'),'original');await command('git',['init','--bare',remote]);
 const settings={failTests:0,duplicate:false,proposalCounts:new Map()},calls=[],tools=new Map(),handlers=new Map();let active=[];
 const pi={registerTool(tool){tools.set(tool.name,tool);active.push(tool.name);},getAllTools:()=>[...tools.values()],getActiveTools:()=>active,setActiveTools:names=>{active=names;},appendEntry(){},getHarnessSessionId:()=> 'root',sendMessage(){},
  on(name,fn){const list=handlers.get(name)??[];list.push(fn);handlers.set(name,list);return()=>list.splice(list.indexOf(fn),1);},async emit(name,event,context){return Promise.all((handlers.get(name)??[]).map(fn=>fn(event,context)));}};
 const ctx=createKernel(pi),states=new Map();
 const runner=async(file,args,options)=>{
  if(file==='gh'){
   const milliseconds=settings.githubDelay??0;settings.githubDelay=0;
   if(milliseconds)await new Promise(resolve=>setTimeout(resolve,milliseconds));
   return JSON.stringify({isPrivate:settings.public!==true});
  }
  return command(file,args.map(arg=>arg==='https://github.com/fixture/private.git'?remote:arg),options);
 };
 const projectFactory=(_cwd,signal,agentId)=>new WorkflowProject(project,{dataRoot:path.join(root,'versions'),runner,signal,agentId});
 const emitTool=async(childId,name,args={})=>{
  const toolCallId=randomUUID();await ctx.emit('subagent/event',{childId,event:{type:'tool_execution_start',toolName:name,toolCallId,args}});
  await ctx.emit('subagent/event',{childId,event:{type:'tool_execution_end',toolName:name,toolCallId,isError:false,result:{}}});
 };
 const manager={active:new Map(),options:{maxConcurrentAgents:4},async startActivation({request,childId,signal}){
  const id=childId??randomUUID(),{role,candidateId,stateFile}=request.execution;
  await request.started?.(id);
  const call={id,role,candidateId,cwd:request.cwd,parent:request.parent.sessionManager.getSessionId(),stateFile,prompt:request.prompt.map(c=>c.text).join('\n')};calls.push(call);manager.active.set(id,call);
  const result=(async()=>{
   signal?.throwIfAborted();const goal=await ctx.goalStates(context).current();
   const all=items=>items.flatMap(c=>[c,...all(c.children??[])]),candidate=all(goal.stages.at(-1).candidates).find(c=>c.id===candidateId);
   let value;
   if(role==='proposal'){
    const count=(settings.proposalCounts.get(id)??0)+1;settings.proposalCounts.set(id,count);
    if(settings.invalidProposal && candidate.number===2 && count===1)return{stopReason:'error',diagnostic:'Unexpected property type in proposal'};
    value={summary:'A reproducible direction '+candidate.number,method:'method '+(settings.duplicate&&candidate.number===2&&count===1?1:candidate.number),hypothesis:'Measurable outcome',evaluation:'Run the artifact checks'};
    await emitTool(id,'read');
   }else if(role==='experiment'){
    const name='result-'+candidate.id+'.txt';let committed;
    if(settings.reuseCommit && await readFile(path.join(request.cwd,name)).then(()=>true,error=>{if(error.code!=='ENOENT')throw error;return false;})){committed={commit:await projectFactory().git(['rev-parse','HEAD'],request.cwd)};await emitTool(id,'bash');}
    else{await writeFile(path.join(request.cwd,name),'verified '+candidate.number+' '+randomUUID());committed=await projectFactory(undefined,signal,id).commit({node:candidate.node.id,paths:[name],message:'Run independent experiment'});await emitTool(id,'project_version',{action:'commit'});}
    if(settings.onExperiment)await settings.onExperiment({candidate,id,goal,call,signal});
    value={report:'Executed experiment and committed the result.',commit:committed.commit,changedPaths:[name]};
   }else if(role==='simplifier'){
    await readFile(path.join(request.cwd,'initial.txt'));await emitTool(id,'read');value={report:'Inspected actual changes; no redundant code.',changedPaths:[]};
   }else{
    await command(process.execPath,['-e',"require('node:assert/strict').equal(require('node:fs').readFileSync('initial.txt','utf8'),'original')"],{cwd:request.cwd});await emitTool(id,'bash');
    const passed=settings.failTests--<=0;value={passed,report:passed?'Actual executable checks passed.':'Deliberately failing an acceptance criterion.',checks:[{subgoal:'Preserve the original input',method:'Node assert',passed,evidence:'Executed isolated Node command'}]};
   }
   signal?.throwIfAborted();return{stopReason:'completed',structured:value,model:{provider:'cbi',model:'deepseek-v4.1-flash',reasoningEffort:'medium'}};
  })().finally(()=>manager.active.delete(id));
  return{childId:id,result,dispose:async()=>{await result;}};
 }};
 await ctx.plugin({name:'fixture-subagents',apply(scope){scope.provide('subagents',manager);}});
 await mountWorkflow(ctx,{projectFactory});await mountAIOS(ctx,{root,dataRoot:path.join(root,'state')});
 const context={cwd:project,thinkingLevel:'high',model:{provider:'test',id:'parent'},sessionManager:{getSessionId:()=> 'root',getSessionFile:()=>undefined,getBranch:()=>[],getHeader:()=>({type:'session',id:'root'})}};
 const engine=ctx.workflowEngine,store=ctx.goalStates(context),execute=args=>engine.execute(args,context,new AbortController().signal);
 async function approved(){let goal=await execute({action:'begin',goal:'Compare reproducible implementations',artifact:'code',repository:'fixture/private'});goal=await execute({action:'plan',tree});await pi.emit('input',{source:'rpc',text:'批准阶段目标树'},context);return store.current();}
 async function accept(){let goal=await execute({action:'propose'});return execute({action:'review',distinctness:'Each method uses a distinct manipulation and evaluation.',judgments:goal.stages.at(-1).candidates.map(c=>({candidateId:c.id,valid:true,reason:'Feasible and independently testable.'}))});}
 async function settled(){const run=engine.runs.values().next().value;if(run)await run.promise;return store.current();}
 t.after(async()=>{await ctx.fiber.dispose();await rm(root,{recursive:true,force:true});});
 return{root,project,remote,ctx,pi,context,engine,store,execute,approved,accept,settled,calls,settings,projectFactory};
}
