import assert from 'node:assert/strict';
import { mkdir,writeFile,readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

/** Real pinned children + real Git, with a disposable bare publication transport. */
export async function stagedCBI({root,temporary,signal}) {
 const harness=process.env.F_HARNESS_DIR ?? path.join(root,'runtime/harness');
 const load=name=>import(pathToFileURL(path.join(harness,'src',name)).href);
 const {startHarness}=await load('index.mjs'),{WorkflowProject}=await load('versions/workflow.mjs'),{DatasetStore}=await load('datasets/store.mjs'),{command}=await load('datasets/providers.mjs');
 const base=path.join(temporary,'staged'),project=path.join(base,'project'),remote=path.join(base,'publication.git'),datasets=path.join(base,'datasets');
 await mkdir(project,{recursive:true});await command('git',['init','--bare',remote]);
 await writeFile(path.join(project,'base.txt'),'STAGED_BASE');
 const skillDirectory=path.join(project,'.agents/skills/staged-live');await mkdir(skillDirectory,{recursive:true});
 const skill=marker=>'---\nname: staged-live\ndescription: Read the staged acceptance marker from the current mainline.\n---\nThe live marker is '+marker+'. Use this exact marker when the stage goal asks for it.\n';
 await writeFile(path.join(skillDirectory,'SKILL.md'),skill('OLD_BRANCH_MARKER'));
 const record=await new DatasetStore(datasets).put({dataset:'code',title:'STAGED_SHARED_DATASET_MARKER',summary:'Isolated acceptance fixture',source:{url:'https://example.test/staged-fixture'},content:'STAGED_DATASET_VALUE'});
 const keys=['F_SHARED_PROJECT','F_DATASET_DIRECTORY','F_DATA_DIRECTORY','F_TASK_DIRECTORY','F_LOCAL_PROJECT','F_BOARD_DIR','F_CONVERSATION_DIR','F_DISABLED_PLUGINS','F_INHERITED_TOOL_ARGS','F_WORKFLOW_STATE_FILE','F_WORKFLOW_ROLE','F_AGENT_DEPTH'];
 const original=Object.fromEntries(keys.map(k=>[k,process.env[k]]));
 Object.assign(process.env,{F_SHARED_PROJECT:project,F_LOCAL_PROJECT:project,F_DATASET_DIRECTORY:datasets,F_DATA_DIRECTORY:path.join(base,'workspaces'),F_TASK_DIRECTORY:path.join(base,'tasks'),F_BOARD_DIR:path.join(base,'board'),F_CONVERSATION_DIR:path.join(base,'conversation'),F_DISABLED_PLUGINS:'',F_INHERITED_TOOL_ARGS:'[]',F_AGENT_DEPTH:'0'});
 delete process.env.F_WORKFLOW_STATE_FILE;delete process.env.F_WORKFLOW_ROLE;
 const tools=new Map(),hooks=new Map(),events=[];let active=[],ctx;
 const pi={registerTool(tool){tools.set(tool.name,tool);active.push(tool.name);},getAllTools:()=>[...tools.values()],getActiveTools:()=>active,setActiveTools:names=>{active=names;},appendEntry(){},sendMessage(){},registerCommand(){},
  on(name,fn){const list=hooks.get(name)??[];list.push(fn);hooks.set(name,list);return()=>list.splice(list.indexOf(fn),1);},async emit(name,event,context){return Promise.all((hooks.get(name)??[]).map(fn=>fn(event,context)));}};
 const context={cwd:project,model:{provider:'cbi',id:'deepseek-v4.1-flash'},thinkingLevel:'medium',sessionManager:{getSessionId:()=> 'staged-cbi-root',getSessionFile:()=>undefined,getBranch:()=>[],getHeader:()=>({type:'session',id:'staged-cbi-root'})}};
 try{
  ctx=await startHarness(pi,{root,dataRoot:path.join(base,'children')});
  await pi.emit('session_start',{},context);await pi.emit('before_agent_start',{systemPrompt:''},context);
  await ctx.get('bus').choose(context,['datasets','versions'],true);
  ctx.on('subagent/event',event=>events.push(event));
  const runner=(file,args,options)=>file==='gh'?Promise.resolve(JSON.stringify({isPrivate:true})):command(file,args.map(arg=>arg==='https://github.com/fixture/staged.git'?remote:arg),options);
  ctx.workflowEngine.projectFactory=(cwd,operationSignal)=>new WorkflowProject(cwd,{dataRoot:path.join(base,'versions'),signal:operationSignal,runner:(file,args,options)=>runner(file,args,{...options,signal:operationSignal})});
  const invoke=async(args)=> (await tools.get('goal_flow').execute('',args,signal,null,context)).details;
  let goal=await invoke({action:'begin',goal:'Produce three independently validated text artifacts while preserving base.txt.',complexity:'complex',artifact:'code',repository:'fixture/staged'});
  assert.ok(goal.baseline.publication);assert.equal(events.length,0);
  await writeFile(path.join(skillDirectory,'SKILL.md'),skill('LIVE_MAINLINE_MARKER'));
  const objective=`Every experimental author must load skill staged-live again during implementation and use dataset get id ${record.id}, after bus activate datasets and versions. The live skill tool must return LIVE_MAINLINE_MARKER from the mainline even inside the branch. Preserve base.txt exactly STAGED_BASE. Never edit any SKILL.md; the branch intentionally has OLD_BRANCH_MARKER. Each branch creates only result.txt containing LIVE_MAINLINE_MARKER and STAGED_DATASET_VALUE. Run a Node assertion with node -e for both values and base.txt; do not create .js/.mjs/test/README files. Commit result.txt through project_version using node (not nodeId) and only fields in its schema. Use three distinct text-construction methods. For this bounded acceptance do not split; nested behavior is covered by the deterministic Git suite. No external services or user data.`;
  await invoke({action:'plan',tree:{id:'root',title:'Bounded staged acceptance',objective,children:[{id:'one',title:'Three candidates',objective},{id:'two',title:'Selected next stage',objective:'Propose three distinct refinements per selected base. Read the live skill; do not modify files.'}]}});
  await pi.emit('input',{source:'rpc',text:'批准阶段目标树'},context);
  for(let attempt=0;attempt<2;attempt++){
   goal=await invoke({action:'propose'});const seen=new Set(),judgments=goal.stages.at(-1).candidates.map(c=>{const key=c.proposal?.method.toLowerCase().replace(/\s+/g,'');const valid=!!key&&!seen.has(key);seen.add(key);return{candidateId:c.id,valid,reason:valid?'Concrete construction method with executable acceptance criteria.':c.error??'The method duplicates an accepted direction; choose a different construction.'};});
   goal=await invoke({action:'review',judgments,distinctness:'The fixture compares three separately implemented construction methods against the same immutable input and exact output assertions.'});if(goal.phase==='ready')break;
  }
  assert.equal(goal.phase,'ready');const beforeRun=events.length;
  await invoke({action:'run'});const run=ctx.workflowEngine.runs.get(goal.id);assert.ok(run);await run.promise;goal=await ctx.goalStates(context).current();
  const repairs=[];
  for(let attempt=0;attempt<2 && goal.phase==='rework';attempt++){
   for(const failed of goal.stages[0].candidates.filter(c=>c.phase==='rework')){
    repairs.push({candidateId:failed.id,experimenterId:failed.experimenterId,reason:failed.error});
    await invoke({action:'retry',candidateId:failed.id});await ctx.workflowEngine.runs.get(goal.id).promise;
   }
   goal=await ctx.goalStates(context).current();
  }
  if(goal.phase!=='reporting')throw new Error('Real staged branches did not close: '+JSON.stringify(goal.stages.at(-1).candidates.map(c=>({id:c.id,phase:c.phase,error:c.error}))));
  const candidates=goal.stages[0].candidates;
  for(const candidate of candidates){
   assert.equal(candidate.node.base,goal.baseline.commit);assert.equal(candidate.experimenterId,candidate.proposerId);assert.notEqual(candidate.simplification.childId,candidate.test.childId);assert.ok(![candidate.test.childId,candidate.simplification.childId].includes(candidate.experimenterId));assert.ok(candidate.publication);
   assert.match(await readFile(path.join(candidate.node.worktree,'result.txt'),'utf8'),/LIVE_MAINLINE_MARKER/);
   assert.match(await command('git',['-C',candidate.node.worktree,'show',candidate.version.commit+':.agents/skills/staged-live/SKILL.md']),/OLD_BRANCH_MARKER/);
   assert.deepEqual(candidate.experiment.model,{provider:'cbi',model:'deepseek-v4.1-flash',reasoningEffort:'medium'});
   const toolsForAuthor=events.slice(beforeRun).filter(e=>e.childId===candidate.experimenterId&&e.event.type==='tool_execution_end');
   assert.ok(toolsForAuthor.some(e=>e.event.toolName==='skill'&&!e.event.isError&&JSON.stringify(e.event.result).includes('LIVE_MAINLINE_MARKER')),'branch author must actually load the current mainline skill');
   assert.ok(toolsForAuthor.some(e=>e.event.toolName==='dataset'&&!e.event.isError&&JSON.stringify(e.event.result).includes('STAGED_DATASET_VALUE')),'branch author must actually read the shared isolated dataset');
  }
  const polished=await tools.get('skill').execute('',{name:'unslop'},signal,null,context);assert.ok(polished.content[0].text.includes('Unslop'));await pi.emit('tool_result',{toolName:'skill',input:{name:'unslop'},isError:false},context);
  await invoke({action:'report',report:'Three isolated variants preserved the original input and passed independent executable checks. Their authors loaded the current mainline skill and shared fixture dataset. Each candidate was reviewed by separate simplification and testing agents.'});
  await pi.emit('input',{source:'rpc',text:'选择候选 1 3'},context);
  const proposalRepairs=[];
  for(let attempt=0;attempt<3;attempt++){
   goal=await invoke({action:'propose'});const seen=new Set();
   const judgments=goal.stages[1].candidates.map(c=>{
    const key=c.baseVersion+'\0'+c.proposal?.method.toLowerCase().replace(/[\s\p{P}\p{S}]/gu,''),valid=!!c.proposal&&!c.error&&!seen.has(key);seen.add(key);
    if(!valid)proposalRepairs.push({candidateId:c.id,proposerId:c.proposerId,error:c.error??'duplicate method'});
    return{candidateId:c.id,valid,reason:valid?'Feasible and distinct from the other methods for this selected base.':'Re-propose this direction only. Return exactly summary, method, hypothesis, evaluation; no type or other fields. Keep summary within 200 Unicode characters. Choose a method different from accepted peers. '+(c.error??'Duplicate method.')};
   });
   goal=await invoke({action:'review',judgments,distinctness:'Each selected version has three independently evaluated refinements; rejected formats or duplicate methods return only to their original authors.'});
   if(goal.phase==='ready')break;
  }
  assert.equal(goal.phase,'ready');assert.equal(goal.stages[1].candidates.length,6);assert.equal(goal.history.filter(h=>h.action==='approve').length,1);
  assert.ok(goal.stages[1].candidates.every(c=>c.proposal && !c.error),'all six next-stage authors must return valid bounded directions');
  return{passed:true,repairs,proposalRepairs,model:{provider:'cbi',id:'deepseek-v4.1-flash',thinking:'medium'},candidateCommits:candidates.map(c=>c.version.commit),reviewers:candidates.map(c=>({experimenter:c.experimenterId,simplifier:c.simplification.childId,tester:c.test.childId})),nextStageDirections:6,mainlineSkill:true,sharedDataset:true,publicationTransport:'isolated local bare Git; no fixture GitHub repository created',observedTools:events.filter(e=>e.event.type==='tool_execution_end').map(e=>({childId:e.childId,name:e.event.toolName,isError:!!e.event.isError}))};
 }finally{
  await ctx?.fiber.dispose();for(const k of keys){if(original[k]===undefined)delete process.env[k];else process.env[k]=original[k];}
 }
}
