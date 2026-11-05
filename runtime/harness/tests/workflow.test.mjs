import test from 'node:test';
import assert from 'node:assert/strict';
import { writeFile,readFile,mkdir,lstat,rm } from 'node:fs/promises';
import path from 'node:path';
import { command } from '../../../packages/data-base/agent/providers.mjs';
import { workflowFixture,tree } from './workflow-fixture.mjs';

test('original publishes first; one human approval and one-to-three selection gates a real fixed-base Git tree',async t=>{
 const f=await workflowFixture(t);let goal=await f.execute({action:'begin',goal:'Compare reproducible implementations',artifact:'code',repository:'fixture/private'});
 assert.equal(goal.phase,'planning');assert.ok(goal.baseline.publication);assert.equal(f.calls.length,0);
 await assert.rejects(f.execute({action:'propose'}),/Approve/);await f.execute({action:'plan',tree});
 await assert.rejects(f.execute({action:'approve'}),/Unsupported/);
 await f.pi.emit('input',{source:'extension',text:'批准阶段目标树'},f.context);assert.equal((await f.store.current()).phase,'tree_review');
 await f.pi.emit('input',{source:'rpc',text:'批准阶段目标树'},f.context);
 await f.accept();assert.equal(f.calls.filter(c=>c.role==='proposal').length,3);
 await f.execute({action:'run'});goal=await f.settled();assert.equal(goal.phase,'reporting');
 const first=goal.stages[0].candidates;
 assert.equal(new Set(first.map(c=>c.node.base)).size,1);
 for(const c of first){assert.equal(c.node.base,goal.baseline.commit);assert.equal(c.phase,'candidate');assert.ok(c.publication);assert.equal(c.experimenterId,c.proposerId);assert.notEqual(c.test.childId,c.simplification.childId);assert.ok(![c.test.childId,c.simplification.childId].includes(c.experimenterId));}
 assert.equal(await readFile(path.join(f.project,'initial.txt'),'utf8'),'original');
 const project=f.projectFactory();
 for(const c of first){const parents=(await command('git',['--git-dir',f.remote,'rev-list','--parents','-n','1',c.version.publishCommit])).split(' ').slice(1);assert.deepEqual(parents,[goal.baseline.publishCommit]);await assert.rejects(command('git',['--git-dir',f.remote,'cat-file','-e',c.experiment.commit]));}
 await assert.rejects(f.execute({action:'report',report:'stage'}),/unslop/);await f.store.skillUsed('unslop');await f.execute({action:'report',report:'All three independent candidates passed executable checks.'});
 await f.pi.emit('input',{source:'rpc',text:'选择候选 1 3'},f.context);goal=await f.store.current();assert.equal(goal.phase,'proposing');assert.equal(goal.history.filter(h=>h.action==='approve').length,1);
 const selected=first.filter((_,i)=>i!==1);await f.accept();goal=await f.store.current();assert.equal(goal.stages[1].candidates.length,6);
 await f.execute({action:'run'});goal=await f.settled();assert.equal(goal.phase,'reporting');
 for(const c of goal.stages[1].candidates)assert.equal(c.node.base,selected.find(s=>s.version.id===c.baseVersion).version.commit);
 assert.equal(goal.history.filter(h=>h.action==='approve').length,1);
});
test('invalid or duplicate directions are not experiments; only rejected authors re-propose',async t=>{
 const f=await workflowFixture(t);f.settings.duplicate=true;await f.approved();let goal=await f.execute({action:'propose'}),c=goal.stages[0].candidates;
 await assert.rejects(f.execute({action:'run'}),/review/);
 await assert.rejects(f.execute({action:'review',distinctness:'Distinct',judgments:c.map(c=>({candidateId:c.id,valid:true,reason:'valid'}))}),/Duplicate/);
 await f.execute({action:'review',distinctness:'Second duplicates the first',judgments:c.map((c,i)=>({candidateId:c.id,valid:i!==1,reason:i===1?'Duplicate method; change it.':'valid'}))});
 goal=await f.execute({action:'propose'});assert.equal(f.calls.filter(c=>c.role==='proposal').length,4);assert.equal(goal.stages[0].candidates[1].proposerId,c[1].proposerId);
 await f.execute({action:'review',distinctness:'Three different methods',judgments:goal.stages[0].candidates.map(c=>({candidateId:c.id,valid:true,reason:'valid'}))});
 assert.equal((await f.store.current()).phase,'ready');assert.equal(f.calls.some(c=>c.role==='experiment'),false);
});
test('test failure returns to the same experimenter and runs new independent reviewers',async t=>{
 const f=await workflowFixture(t);f.settings.reuseCommit=true;await f.approved();await f.accept();f.settings.failTests=1;await f.execute({action:'run'});let goal=await f.settled();assert.equal(goal.phase,'rework');
 const failed=goal.stages[0].candidates.find(c=>c.phase==='rework'),experimenter=failed.experimenterId,oldCleaner=failed.simplification.childId,oldTester=failed.test.childId;
 assert.equal(failed.version,undefined);await f.execute({action:'retry',candidateId:failed.id});goal=await f.settled();assert.equal(goal.phase,'reporting');
 const done=goal.stages[0].candidates.find(c=>c.id===failed.id);assert.equal(done.experimenterId,experimenter);assert.notEqual(done.simplification.childId,oldCleaner);assert.notEqual(done.test.childId,oldTester);assert.equal(f.calls.filter(c=>c.id===experimenter&&c.role==='experiment').length,2);
});

test('a malformed proposal is returned only to its author with the main agent’s correction',async t=>{
 const f=await workflowFixture(t);f.settings.invalidProposal=true;await f.approved();let goal=await f.execute({action:'propose'}),failed=goal.stages[0].candidates[1];
 assert.equal(failed.phase,'proposal_error');assert.equal(failed.proposal,undefined);
 await f.execute({action:'review',distinctness:'Only the second output failed the protocol.',judgments:goal.stages[0].candidates.map(c=>({candidateId:c.id,valid:c.id!==failed.id,reason:c.id===failed.id?'MAIN_REVIEW_FIX: Return only the four proposal fields.':'Valid method.'}))});
 goal=await f.execute({action:'propose'});const attempts=f.calls.filter(c=>c.role==='proposal');
 assert.equal(attempts.length,4);assert.equal(attempts.at(-1).id,failed.proposerId);assert.match(attempts.at(-1).prompt,/MAIN_REVIEW_FIX/);assert.ok(goal.stages[0].candidates[1].proposal);
});
test('private paths, literal API material and public repositories are refused before publication',async t=>{
 const f=await workflowFixture(t);await writeFile(path.join(f.project,'.env'),'API_KEY='+('sk-'+'x'.repeat(40)));await writeFile(path.join(f.project,'auth.json'),'private');
 let goal=await f.execute({action:'begin',goal:'Exclude credentials',repository:'fixture/private'});const files=await command('git',['--git-dir',f.remote,'ls-tree','-r','--name-only',goal.baseline.publishCommit]);assert.ok(!files.includes('.env')&&!files.includes('auth.json'));
 const g=await workflowFixture(t);await writeFile(path.join(g.project,'source.js'),'const apiKey = "'+'sk-'+'z'.repeat(40)+'";');await assert.rejects(g.execute({action:'begin',goal:'Reject literal keys',repository:'fixture/private'}),/credential/);assert.equal(await command('git',['--git-dir',g.remote,'for-each-ref']),'');
 const h=await workflowFixture(t);h.settings.public=true;await assert.rejects(h.execute({action:'begin',goal:'Reject public destination',repository:'fixture/private'}),/private/);assert.equal(await command('git',['--git-dir',h.remote,'for-each-ref']),'');
});

test('one split creates at most three experimental grandchildren; root reviewers remain independent and no deeper split exists',async t=>{
 const f=await workflowFixture(t);let splitOwner,grandchildren;
 f.settings.onExperiment=async({candidate,id,signal})=>{
  if(candidate.depth!==1 || candidate.number!==1)return;
  splitOwner=id;
  const keys=['F_WORKFLOW_ROLE','F_AGENT_DEPTH','F_AGENT_ID','F_WORKFLOW_CANDIDATE'],old=Object.fromEntries(keys.map(k=>[k,process.env[k]]));
  Object.assign(process.env,{F_WORKFLOW_ROLE:'experiment',F_AGENT_DEPTH:'1',F_AGENT_ID:id,F_WORKFLOW_CANDIDATE:candidate.id});
  const childContext={...f.context,cwd:candidate.node.worktree,sessionManager:{...f.context.sessionManager,getSessionId:()=>id}};
  const subgoals=[1,2,3].map(i=>({summary:'Independent subgoal '+i,method:'Submethod '+i,hypothesis:'A subgoal hypothesis',evaluation:'Check the branch artifact'}));
  try{
   grandchildren=await f.engine.split(f.store,await f.store.current(),{action:'split',subgoals},childContext,signal);
   assert.equal(grandchildren.length,3);assert.ok(grandchildren.every(c=>c.phase==='candidate'&&c.publication));
   await assert.rejects(f.engine.split(f.store,await f.store.current(),{action:'split',subgoals},childContext,signal),/one split/);
   process.env.F_AGENT_DEPTH='2';process.env.F_AGENT_ID=grandchildren[0].experimenterId;process.env.F_WORKFLOW_CANDIDATE=grandchildren[0].id;
   await assert.rejects(f.engine.split(f.store,await f.store.current(),{action:'split',subgoals},childContext,signal),/grandchildren/);
  }finally{for(const k of keys){if(old[k]===undefined)delete process.env[k];else process.env[k]=old[k];}}
 };
 await f.approved();await f.accept();await f.execute({action:'run'});const goal=await f.settled();
 assert.equal(goal.phase,'reporting');
 const ids=new Set(grandchildren.map(c=>c.id));
 assert.equal(f.calls.filter(c=>c.role==='experiment'&&ids.has(c.candidateId)&&c.parent===splitOwner).length,3);
 const reviews=f.calls.filter(c=>['simplifier','tester'].includes(c.role)&&ids.has(c.candidateId));assert.equal(reviews.length,6);assert.ok(reviews.every(c=>c.parent==='root'));
 assert.equal(f.ctx.subagents.active.size,0);assert.equal(f.engine.slots,0);
});

test('cancellation joins experimental children, records pause and publishes no partial candidate',async t=>{
 const f=await workflowFixture(t);
 f.settings.onExperiment=({signal})=>new Promise((resolve,reject)=>{if(signal.aborted)reject(signal.reason);else signal.addEventListener('abort',()=>reject(signal.reason),{once:true});});
 await f.approved();await f.accept();await f.execute({action:'run'});await f.engine.dispose();
 const goal=await f.store.current();assert.equal(goal.phase,'paused');assert.equal(f.ctx.subagents.active.size,0);assert.equal(f.engine.slots,0);assert.ok(goal.stages[0].candidates.every(c=>!c.version));
});

test('network and token failures preserve committed work and siblings, then repair with the original authors',async t=>{
 const f=await workflowFixture(t),faults=new Map([[1,'ECONNRESET: network disconnected'],[2,'insufficient_quota: token budget exhausted']]);
 f.settings.reuseCommit=true;
 f.settings.onExperiment=({candidate})=>{const error=faults.get(candidate.number);if(error){faults.delete(candidate.number);throw new Error(error);}};
 await f.approved();await f.accept();await f.execute({action:'run'});let goal=await f.settled();
 assert.equal(goal.phase,'rework');assert.equal(f.ctx.subagents.active.size,0);assert.equal(f.engine.slots,0);
 const failed=goal.stages[0].candidates.filter(c=>c.phase==='rework'),sibling=goal.stages[0].candidates.find(c=>c.phase==='candidate');
 assert.equal(failed.length,2);assert.ok(failed.some(c=>/ECONNRESET/.test(c.error)));assert.ok(failed.some(c=>/insufficient_quota/.test(c.error)));
 for(const c of failed){
  const head=await command('git',['-C',c.node.worktree,'rev-parse','HEAD']);assert.notEqual(head,c.node.base);assert.equal(c.publication,undefined);
  const author=c.experimenterId;await f.execute({action:'retry',candidateId:c.id});goal=await f.settled();const repaired=goal.stages[0].candidates.find(x=>x.id===c.id);assert.equal(repaired.experimenterId,author);assert.equal(repaired.experiment.commit,head);
 }
 assert.equal(goal.phase,'reporting');assert.equal(goal.stages[0].candidates.find(c=>c.id===sibling.id).version.commit,sibling.version.commit);
 assert.equal(goal.history.filter(h=>h.action==='approve').length,1);
});

test('publication rejects credential text in snapshot commit metadata as well as source files',async t=>{
 const f=await workflowFixture(t);await f.approved();await f.accept();await f.execute({action:'run'});const goal=await f.settled(),candidate=goal.stages[0].candidates[0],project=f.projectFactory();
 const tree=await project.git(['rev-parse',candidate.version.commit+'^{tree}']);
 const publishCommit=await project.git(['-c','user.name=F','-c','user.email=f@localhost','-c','commit.gpgsign=false','commit-tree',tree,'-p',goal.baseline.publishCommit,'-m','sk-'+'q'.repeat(40)]);
 await assert.rejects(project.publishWorkflow({...candidate.version,id:'candidate-private-metadata',publishCommit},'fixture/private'),/credential/);
});

test('a slow GitHub response does not send healthy sibling experiments back for rework',async t=>{
 const f=await workflowFixture(t);await f.approved();await f.accept();await f.execute({action:'run'});assert.equal((await f.settled()).phase,'reporting');
 await f.store.skillUsed('unslop');await f.execute({action:'report',report:'Passed first-stage experiments.'});await f.pi.emit('input',{source:'rpc',text:'选择候选 1 3'},f.context);
 await f.accept();f.settings.githubDelay=6000;
 await f.execute({action:'run'});const goal=await f.settled();
 assert.equal(goal.stages[1].candidates.length,6);
 assert.equal(goal.phase,'reporting',JSON.stringify(goal.stages[1].candidates.map(c=>({phase:c.phase,error:c.error}))));
});

test('cancelling a queued version operation preserves the current lock owner',async t=>{
 const f=await workflowFixture(t);await f.approved();const controller=new AbortController(),project=f.projectFactory(undefined,controller.signal);await project.verify();
 await mkdir(project.lock);let entered=false;
 const pending=project.exclusive(async()=>{entered=true;});await new Promise(resolve=>setTimeout(resolve,60));controller.abort();
 await assert.rejects(pending,/abort/i);assert.equal(entered,false);assert.ok((await lstat(project.lock)).isDirectory());await rm(project.lock,{recursive:true});
});

test('resuming a closed experimental author cannot create grandchildren after validation',async t=>{
 const f=await workflowFixture(t);await f.approved();await f.accept();await f.execute({action:'run'});const goal=await f.settled(),owner=goal.stages[0].candidates[1];
 const environment={F_WORKFLOW_ROLE:'experiment',F_AGENT_DEPTH:'1',F_AGENT_ID:owner.experimenterId,F_WORKFLOW_CANDIDATE:owner.id},saved=Object.fromEntries(Object.keys(environment).map(k=>[k,process.env[k]]));
 try{
  Object.assign(process.env,environment);
  await assert.rejects(f.engine.split(f.store,goal,{action:'split',subgoals:[{summary:'Late child',method:'Unapproved late experiment'}]},f.context,new AbortController().signal),/active assigned/);
  const current=await f.store.current();assert.equal(current.phase,'reporting');assert.equal(current.stages[0].candidates[1].splitUsed,false);assert.deepEqual(current.stages[0].candidates[1].children,[]);
 }finally{for(const[k,v]of Object.entries(saved)){if(v===undefined)delete process.env[k];else process.env[k]=v;}}
});
