import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { GoalState, boundedReport } from '../src/aios/state.mjs';

async function fixture(t) { const directory = await mkdtemp(path.join(os.tmpdir(),'f-goal-')); t.after(() => rm(directory,{recursive:true,force:true})); return {directory, store:new GoalState({directory,sessionId:'root'})}; }
const consensus = { research: {sources:['https://arxiv.org/abs/1234.5678']}, candidates: ['a','b','c'].map(childId=>({childId,report:'可测试的算法'})), votes: [{childId:'a',proposalId:'a'},{childId:'b',proposalId:'a'},{childId:'c',proposalId:'c'}] };

test('complex goals persist distinct user approval gates and reject stale approvals', async t => {
 const {store,directory}=await fixture(t); let goal=await store.begin({goal:'机器人控制',complexity:'complex',artifact:'code'});
 await assert.rejects(store.delivered(goal.id,'done'),/executing/);
 goal=await store.consensus(goal.id,consensus); assert.equal(goal.phase,'consensus_review');
 await assert.rejects(store.plan(goal.id,'技术报告'),/planning/);
 await assert.rejects(store.review({id:goal.id,revision:0,decision:'approve'}),/stale/);
 goal=await store.review({id:goal.id,revision:1,decision:'revise',feedback:'考虑延迟'}); assert.equal(goal.phase,'discussing');
 goal=await store.consensus(goal.id,consensus); assert.equal(goal.revision,2);
 goal=await store.review({id:goal.id,revision:2,decision:'approve'}); assert.equal(goal.phase,'planning');
 goal=await store.plan(goal.id,'按传感、估计、控制分层实现。');
 await assert.rejects(store.delivered(goal.id,'done'),/executing/);
 goal=await store.review({id:goal.id,revision:3,decision:'approve'}); assert.equal(goal.phase,'executing');
 goal=await store.delivered(goal.id,'完成实现'); assert.equal(goal.phase,'simplifying');
 goal=await store.simplified(goal.id,{childId:'cleaner',report:'移除重复'}); assert.equal(goal.phase,'testing');
 await assert.rejects(store.tested(goal.id,{childId:'tester',passed:true,report:'成功',checks:[],evidence:[]}),/subgoals/);
 goal=await store.tested(goal.id,{childId:'tester',passed:false,report:'控制不稳定',checks:[{passed:false}],evidence:[{toolName:'bash'}]}); assert.equal(goal.phase,'rework');
 goal=await store.rework(goal.id,{route:'repair',reason:'修正误差限'}); assert.equal(goal.phase,'simplifying');
 await store.simplified(goal.id,{childId:'cleaner2'});
 goal=await store.tested(goal.id,{childId:'tester2',passed:true,report:'所有目标通过',checks:[{passed:true}],evidence:[{toolName:'bash'}]}); assert.equal(goal.phase,'complete');
 assert.equal((await new GoalState({directory,sessionId:'root'}).current()).phase,'complete');
 assert.equal(await new GoalState({directory,sessionId:'other'}).current(),undefined);
});

test('simple goals stay single-agent; prose requires an observed unslop skill load',async t=>{
 const {store}=await fixture(t);let goal=await store.begin({goal:'概括论文',complexity:'simple',artifact:'other'});
 assert.equal((await store.delivered(goal.id,'概括完成')).phase,'complete');
 goal=await store.begin({goal:'写摘要',complexity:'simple',artifact:'prose'});
 await assert.rejects(store.delivered(goal.id,'摘要'),/unslop/);await store.skillUsed('unslop');
 assert.equal((await store.delivered(goal.id,'摘要')).phase,'complete');
});

test('consensus requires independent participants and two matching votes; reports count Unicode characters', async t=>{
 const {store}=await fixture(t); const goal=await store.begin({goal:'设计系统',complexity:'complex'});
 await assert.rejects(store.consensus(goal.id,{...consensus,votes:[consensus.votes[0],consensus.votes[0],consensus.votes[2]]}),/independent/);
 const value=await store.consensus(goal.id,{...consensus,votes:['a','b','c'].map(childId=>({childId,proposalId:childId}))}); assert.equal(value.phase,'discussing');
 assert.equal(boundedReport('😀'.repeat(200),200).length,400);assert.throws(()=>boundedReport('字'.repeat(201),200),/200/);
 for(let n=0;n<40;n++) await assert.rejects(store.review({id:goal.id,revision:n,decision:'approve'}),/stale/);
});
