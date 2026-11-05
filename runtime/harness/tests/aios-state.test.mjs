import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { GoalState,boundedReport,stageTree } from '../../../packages/agent-bus/agent/state.mjs';

async function fixture(t) { const directory=await mkdtemp(path.join(os.tmpdir(),'f-goal-'));t.after(()=>rm(directory,{recursive:true,force:true}));return new GoalState({directory,sessionId:'root'}); }
export const tree={id:'goal',title:'目标',objective:'完成实验',children:[{id:'s1',title:'阶段一',objective:'验证方向'},{id:'s2',title:'阶段二',objective:'完善入选版本'}]};
test('one tree approval survives stage selection and cannot be forged or replayed',async t=>{
 const store=await fixture(t);
 assert.throws(()=>store.begin({goal:'实验',complexity:'complex'}),/original/);
 let goal=await store.begin({goal:'实验',complexity:'complex',baseline:{id:'original',publication:{repository:'private/repo'}}});
 await assert.rejects(store.delivered(goal.id,'done'),/executing/);
 goal=await store.plan(goal.id,tree);
 await assert.rejects(store.review({id:goal.id,revision:0,decision:'approve'}),/stale/);
 goal=await store.review({id:goal.id,revision:goal.revision,decision:'approve'});assert.equal(goal.phase,'proposing');
 await assert.rejects(store.plan(goal.id,tree),/planning/);
 for(let i=0;i<2;i++) {
  goal=await store.update(goal.id,'proposing',g=>{g.stages.push({candidates:[1,2,3].map(n=>({phase:'candidate',version:{id:`s${i}-v${n}`},publication:{commit:'fixed'}}))});g.phase='reporting';});
  goal=await store.report(goal.id,'本阶段三条方法均已验证。');
  for(const selections of [[],['fake'],['s0-v1','s0-v1'],[1,2,3,4]])await assert.rejects(store.review({id:goal.id,revision:goal.revision,decision:'select',selections}),/Select/);
  goal=await store.review({id:goal.id,revision:goal.revision,decision:'select',selections:[`s${i}-v1`,`s${i}-v3`]});
 }
 assert.equal(goal.phase,'complete');assert.equal(goal.history.filter(h=>h.action==='approve').length,1);
 assert.equal((await new GoalState({file:store.file}).current()).phase,'complete');
});
test('simple goals preserve independent code gates and actual unslop loading',async t=>{
 const store=await fixture(t);let goal=await store.begin({goal:'文字',complexity:'simple',artifact:'prose'});
 await assert.rejects(store.delivered(goal.id,'摘要'),/unslop/);await store.skillUsed('unslop');await store.delivered(goal.id,'摘要');
 goal=await store.begin({goal:'代码',complexity:'simple',artifact:'code'});await store.delivered(goal.id,'实现完成');await store.simplified(goal.id,{childId:'cleaner'});
 await assert.rejects(store.tested(goal.id,{childId:'cleaner',passed:true,report:'测试',checks:[{passed:true}],evidence:[{toolName:'bash'}]}),/Independent/);
 await assert.rejects(store.tested(goal.id,{childId:'tester',passed:true,report:'测试',checks:[{passed:true}],evidence:[{toolName:'read'}]}),/executable/);
 assert.equal((await store.tested(goal.id,{childId:'tester',passed:true,report:'通过',checks:[{passed:true}],evidence:[{toolName:'bash'}]})).phase,'complete');
});
test('tree and Unicode bounds reject duplicate nodes, cycles and oversized reports',()=>{
 assert.equal(boundedReport('😀'.repeat(200),200).length,400);assert.throws(()=>boundedReport('字'.repeat(201),200),/200/);
 assert.deepEqual(stageTree(tree),tree);
 assert.throws(()=>stageTree({...tree,children:[tree.children[0],tree.children[0]]}),/unique/);
 const cyclic={id:'cycle',title:'x',objective:'x',children:[]};cyclic.children.push(cyclic);assert.throws(()=>stageTree(cyclic),/unique/);
 for(let i=0;i<50;i++)assert.throws(()=>stageTree({id:'x',title:'x',objective:'x',children:[]}),/stages/);
});
