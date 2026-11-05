import { Service } from '../../dist/upstream.mjs';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { GoalState, boundedReport, independentTest } from '../aios/state.mjs';
import { WorkflowProject } from '../versions/workflow.mjs';
import { cleanPath } from '../versions/project.mjs';
import { snapshotParent } from '../subagent/index.mjs';
import { objectSchema, stringSchema } from '../core/kernel.mjs';
import { command } from '../datasets/providers.mjs';

const strings = { type:'array', items:stringSchema };
const proposalSchema = objectSchema({ summary:{type:'string',description:'中文方向简介，建议120至160个Unicode字符，硬上限200个字符。英文字母、数字和标点逐字符计数，不是200个英文单词；只写方法，不写工具调用记录。'}, method:stringSchema, hypothesis:stringSchema, evaluation:stringSchema });
const experimentSchema = objectSchema({ report:{type:'string',description:'Actual experiment summary, at most 2000 Unicode characters, not words.'}, commit:stringSchema, changedPaths:strings });
const cleanupSchema = objectSchema({ report:{type:'string',description:'Actual cleanup summary, prefer 300–500 Chinese characters; hard limit 1000 Unicode characters, not words.'}, changedPaths:strings });
const testSchema = objectSchema({ passed:{type:'boolean'}, report:{type:'string',description:'Actual test summary in 400–600 Chinese characters; hard limit 1000 Unicode characters including every ASCII letter. Put detailed commands in checks, not report.'}, checks:{type:'array',items:objectSchema({subgoal:stringSchema,method:stringSchema,passed:{type:'boolean'},evidence:stringSchema})} });
const activePhases = ['proposing','direction_review','ready','executing','rework','reporting','paused'];
const flatten = items => items.flatMap(item => [item,...flatten(item.children ?? [])]);
const find = (goal,id) => flatten(goal?.stages?.at(-1)?.candidates ?? []).find(c => c.id === id);
const methodKey = text => text.toLowerCase().replace(/[\s\p{P}\p{S}]/gu,'');

export class FWorkflowEngine extends Service {
  runs = new Map(); events = new Map(); slots = 0; experiments = 0; operations = new Set();
  constructor(ctx, { projectFactory = (project,signal) => new WorkflowProject(project,{signal,runner:(file,args,options)=>command(file,args,{...options,signal})}), publish } = {}) {
    super(ctx,'workflowEngine'); this.projectFactory = projectFactory;
    this.publish = publish ?? ((project,version,repository) => project.publishWorkflow(version,repository));
    const starts = new Map();
    ctx.on('subagent/event', ({childId,event}) => {
      const key=childId+'\0'+event.toolCallId;
      if (event.type === 'tool_execution_start') starts.set(key,event.args);
      if (event.type !== 'tool_execution_end') return;
      const args = starts.get(key); starts.delete(key);
      this.events.get(childId)?.push({ childId, toolName:event.toolName, isError:!!event.isError, action:args?.action, toolCallId:event.toolCallId });
    });
    ctx.effect(() => () => this.dispose());
  }
  store(context) { return process.env.F_WORKFLOW_STATE_FILE ? new GoalState({file:process.env.F_WORKFLOW_STATE_FILE}) : this.ctx.get('goalStates')(context); }
  project(goal,signal) { return this.projectFactory(goal.project,signal); }
  async change(store,id,fn) { return store.update(id,activePhases,fn); }
  async patch(store,goalId,id,fn) { return this.change(store,goalId,g => { const candidate=find(g,id); if (!candidate) throw new Error('Unknown stage branch'); fn(candidate,g); }); }
  async agent(context,store,goal,candidate,role,prompt,schema,signal,childId) {
    const experiment=role==='experiment' && candidate.depth===1;
    // Keep one main-agent slot available for grandchild reviewers while their
    // three experimental parents are awaiting split results.
    while ((experiment && this.experiments>=3) || this.slots >= 4 || this.ctx.subagents.active.size >= this.ctx.subagents.options.maxConcurrentAgents) await delay(40,undefined,{signal});
    signal?.throwIfAborted(); this.slots++;if(experiment)this.experiments++;
    let activationId;
    try {
      const activation = await this.ctx.subagents.startActivation({label:role,childId,delivery:'caller',signal,
        request:{ parent:snapshotParent(context),cwd:candidate.node?.worktree ?? goal.project,maxDepth:2,
          started:id=>this.patch(store,goal.id,candidate.id,c=>{
            activationId=id;this.events.set(id,[]);
            if(role==='proposal')c.proposerId=id;if(role==='experiment')c.experimenterId=id;
            c.attempts=[...(c.attempts??[]),{role,childId:id,at:new Date().toISOString()}];
          }),
          execution:{role,candidateId:candidate.id,stateFile:store.file,capabilities:['experiment','simplifier'].includes(role)?['versions']:[]},prompt:[{type:'text',text:prompt}],outputSchema:schema } });
      const value = await activation.result;
      if (value.stopReason !== 'completed') throw new Error(`${role} failed: ${value.diagnostic ?? value.stopReason}`);
      return { ...value.structured,childId:activation.childId,model:value.model,evidence:this.events.get(activation.childId) ?? [] };
    } finally { if(activationId)this.events.delete(activationId);this.slots--;if(experiment)this.experiments--; }
  }
  async begin(args,context,signal) {
    if (process.env.F_REMOTE_PROJECT) throw new Error('Remote staged experiments require a remote Git/worktree and lease provider; the local SSH descriptor is never snapshotted');
    const store=this.store(context); let current=await store.current();
    if (current?.complexity==='complex' && !current.stages && !['complete','archived'].includes(current.phase)) { await store.archive(current.id,'旧复杂流程已退役，原记录保留');current=await store.current(); }
    if (current?.phase!=='initializing') current=await store.begin({ ...args,complexity:'complex',initializing:true,project:context.cwd,paths:(args.paths ?? ['.']).map(cleanPath) });
    else if (current.goal!==args.goal) throw new Error('Resume the original snapshot publication before starting another complex goal');
    signal?.throwIfAborted();
    const project=this.project(current,signal),baseline=await project.original(current.id,current.goal);
    const publication=await this.publish(project,baseline,args.repository);
    signal?.throwIfAborted();
    return store.update(current.id,'initializing',g => {g.baseline={...baseline,publication};g.repository=publication.repository;g.phase='planning';});
  }
  async propose(store,goal,context,signal) {
    if (!['proposing','direction_review'].includes(goal.phase) || !goal.treeApproval) throw new Error('Approve the stage tree once before requesting directions');
    const project=this.project(goal);
    if (goal.stages.at(-1)?.index!==goal.stageIndex) goal=await this.change(store,goal.id,g => {
      const candidates=g.selectedVersions.flatMap(baseVersion => Array.from({length:3},(_,i)=>({id:randomUUID(),baseVersion,number:i+1,depth:1,phase:'draft',children:[],splitUsed:false})));
      g.stages.push({index:g.stageIndex,goal:g.approvedTree.children[g.stageIndex],candidates});g.phase='proposing';
    });
    const stage=goal.stages.at(-1),pending=stage.candidates.filter(c => c.phase!=='accepted');
    await Promise.all(pending.map(async candidate => {
      await this.patch(store,goal.id,candidate.id,c => {c.phase='proposing';});
      try {
        const base=await project.version(candidate.baseVersion);
        const proposal=await this.agent(context,store,goal,candidate,'proposal',`你是第${candidate.number}名方向实验者。阶段目标：${JSON.stringify(stage.goal)}。起点版本：${base.commit}。主 Agent 反馈：${candidate.judgment?.reason ?? candidate.error ?? '首次提案'}。已接受的同行方法：${JSON.stringify(stage.candidates.filter(c=>c.phase==='accepted'&&c.baseVersion===candidate.baseVersion).map(c=>c.proposal))}。只研究，不修改文件。先发现主线 skills、datasets 和所需工具。给出中文120至160字符、绝不超过200个Unicode字符的 summary。英文字母数字标点都逐字符计数，不是200个英文单词，summary只写方向，不写读取技能或工具的流水账。另给具体 method、hypothesis、evaluation。与同组其他方向独立提出可检验的方法。`,proposalSchema,signal,candidate.proposerId);
        boundedReport(proposal.summary,200,'Direction summary');
        for (const key of ['method','hypothesis','evaluation']) boundedReport(proposal[key],2000,key);
        await this.patch(store,goal.id,candidate.id,c => {c.proposal=proposal;c.proposerId=proposal.childId;c.phase='proposed';delete c.error;});
      } catch (error) { await this.patch(store,goal.id,candidate.id,c => {c.phase='proposal_error';c.error=error.message;}); }
    }));
    return this.change(store,goal.id,g => {g.phase='direction_review';});
  }
  async judge(store,goal,{judgments,distinctness}) {
    if (goal.phase!=='direction_review') throw new Error('Directions are not awaiting main-agent review');
    boundedReport(distinctness,2000,'Main-agent distinctness assessment');
    const candidates=goal.stages.at(-1).candidates;
    if (!Array.isArray(judgments) || judgments.length!==candidates.length || new Set(judgments.map(j=>j.candidateId)).size!==candidates.length) throw new Error('The main agent must review every direction exactly once');
    for (const c of candidates) {
      const judgment=judgments.find(j=>j.candidateId===c.id);
      if (!judgment || typeof judgment.valid!=='boolean') throw new Error('Unknown direction judgment');
      boundedReport(judgment.reason,1000,'Method validity assessment');
      if (judgment.valid && !c.proposal) throw new Error('A failed or missing proposal cannot be accepted');
      const peers=candidates.filter(p=>p.baseVersion===c.baseVersion);
      if (judgment.valid && peers.some(p=>p.id!==c.id && judgments.find(j=>j.candidateId===p.id)?.valid && methodKey(p.proposal?.method ?? '')===methodKey(c.proposal.method))) throw new Error('Duplicate experimental methods cannot both be accepted');
    }
    return this.change(store,goal.id,g => {
      for (const c of g.stages.at(-1).candidates) {c.judgment=judgments.find(j=>j.candidateId===c.id);c.phase=c.judgment.valid?'accepted':'rejected';}
      g.stages.at(-1).distinctness=distinctness;g.phase=g.stages.at(-1).candidates.every(c=>c.phase==='accepted')?'ready':'proposing';
    });
  }
  async prepareNode(store,goal,candidate,signal) {
    if (candidate.node) return candidate;
    const project=this.project(goal,signal),base=await project.version(candidate.baseVersion);
    const node=await project.fork({parent:candidate.parentNode ?? base.sourceNode,commit:candidate.startCommit ?? base.commit,versionBase:base.id,label:`阶段${goal.stageIndex+1} · ${candidate.number}`,paths:goal.paths});
    const experimenterId=candidate.experimenterId ?? candidate.proposerId;
    await this.patch(store,goal.id,candidate.id,c => {c.node=node;c.experimenterId=experimenterId;});
    return {...candidate,node,experimenterId};
  }
  experimentPrompt(goal,candidate) {
    return `你是第${candidate.number}名该分支唯一的实验者。阶段目标：${JSON.stringify(goal.stages.at(-1).goal)}。方向：${JSON.stringify(candidate.proposal)}。工作目录：${candidate.node.worktree}，版本节点：${candidate.node.id}。只改该分支的授权路径 ${JSON.stringify(goal.paths)}。先 resource_scope claim，重新读取后修改，最后释放。主线 skills/datasets/已启用工具可用。必须实际实验，并自己用 project_version action commit、node=${candidate.node.id} 提交，不调用 complete/branch，不修改主线。${candidate.depth===1?'可按需要使用 workflow action split，一生效最多3个子目标，只能用一次；失败孙分支用 workflow retry 恢复原实验者，不得新增孙分支。所有孙分支也必须通过主 Agent 派出的独立精简和测试。':'你是孙实验者，不得继续拆分或创建子 Agent。'}\n反馈：${candidate.error ?? ''}。完成后返回 report、确切 commit 和 changedPaths；不要声称未执行的测试通过。`;
  }
  async experiment(store,goal,candidate,context,signal) {
    try {
      candidate=await this.prepareNode(store,goal,candidate,signal);
      await this.patch(store,goal.id,candidate.id,c => {c.phase='working';});
      const experiment=await this.agent(context,store,goal,candidate,'experiment',this.experimentPrompt(goal,candidate),experimentSchema,signal,candidate.experimenterId);
      boundedReport(experiment.report,2000,'Experiment report');
      const project=this.project(goal,signal),node=await project.node(candidate.node.id),checkpoint=await project.validationState(node);
      const committed=experiment.evidence.some(e=>e.toolName==='project_version' && e.action==='commit' && !e.isError);
      const prior=!committed && !candidate.authoredCommit && (await project.enabledState()).versions.findLast(v=>v.sourceNode===node.id && v.agentId===experiment.childId);
      const authored=candidate.authoredCommit ?? (prior?{childId:prior.agentId,commit:prior.commit}:undefined);
      if (experiment.commit!==checkpoint.head || checkpoint.head===node.base || checkpoint.status || (!committed && authored?.childId!==experiment.childId)) throw new Error('The experimental author must commit its own clean branch before independent review');
      if(!committed)await project.git(['merge-base','--is-ancestor',authored.commit,checkpoint.head]);
      await this.patch(store,goal.id,candidate.id,c => {c.authoredCommit=committed?{childId:experiment.childId,commit:checkpoint.head}:authored;c.experiment=experiment;c.experimenterId=experiment.childId;c.phase='awaiting_reviews';delete c.error;});
      return find(await store.current(),candidate.id);
    } catch (error) { await this.patch(store,goal.id,candidate.id,c => {c.phase='rework';c.error=error.message;});return null; }
  }
  async close(store,goal,candidate,context,signal) {
    const project=this.project(goal,signal);
    try {
      if (candidate.children?.some(c=>c.phase!=='candidate')) throw new Error('Every grandchild branch must close through independent review before its parent closes');
      await this.patch(store,goal.id,candidate.id,c => {c.phase='simplifying';});
      const simplified=await this.agent(context,store,goal,candidate,'simplifier',`独立精简该实验分支，不改变实验方向。目标：${JSON.stringify(goal.stages.at(-1).goal)}；实验结果：${JSON.stringify(candidate.experiment)}。工作目录 ${candidate.node.worktree}，node=${candidate.node.id}。先阅读实际修改，删除已证明冗余的代码，保留磁盘/网络/认证边界的错误处理。需要修改时先申请 resource_scope 并重新读取，自己 project_version commit 到该 node，最后释放。不要修改主线或其他分支。返回实际 report 与 changedPaths，未改动也说明依据。`,cleanupSchema,signal);
      boundedReport(simplified.report,1000,'Simplification report');
      if (simplified.childId===candidate.experimenterId || !simplified.evidence.some(e=>!e.isError && ['read','bash','edit'].includes(e.toolName))) throw new Error('Simplification must be performed by an independent agent with observed inspection');
      const node=await project.node(candidate.node.id),checkpoint=await project.validationState(node);
      if (checkpoint.status) throw new Error('The simplifier must commit all authorized changes before testing');
      await this.patch(store,goal.id,candidate.id,c => {c.simplification=simplified;c.phase='testing';});
      const tested=await this.agent(context,store,goal,candidate,'tester',`独立验证整个候选分支。目标：${JSON.stringify(goal.stages.at(-1).goal)}，方法：${JSON.stringify(candidate.proposal)}，实验：${JSON.stringify(candidate.experiment)}。工作目录 ${candidate.node.worktree}，固定提交 ${checkpoint.head}。根据阶段目标自行设计边界、暴力和异常测试，必须实际执行 bash 检查并记录命令、结果与证据。不得修改项目、提交或委派子代理；夹具与输出只能放临时目录。返回 passed、<=1000字report、非空checks，失败如实标记。`,testSchema,signal);
      independentTest(tested,[candidate.experimenterId,simplified.childId]);
      await project.assertValidationState(node,checkpoint);
      await this.patch(store,goal.id,candidate.id,c => {c.test=tested;});
      if (!tested.passed) throw new Error('Independent tests failed: '+tested.report);
      const validation={...tested,simplifier:simplified.childId,experimenter:candidate.experimenterId};
      signal?.throwIfAborted();
      const version=await project.candidate({goalId:goal.id,node:node.id,baseVersion:candidate.baseVersion,summary:candidate.proposal.summary,validation,expected:checkpoint});
      const publication=await this.publish(project,version,goal.repository);
      await this.patch(store,goal.id,candidate.id,c => {c.version=version;c.publication=publication;c.phase='candidate';delete c.error;});
    } catch (error) { await this.patch(store,goal.id,candidate.id,c => {c.phase='rework';c.error=error.message;}); }
  }
  async watchGrandchildren(store,goal,context,signal) {
    while (!signal.aborted) {
      const current=await store.current();
      const candidate=flatten(current?.stages.at(-1)?.candidates ?? []).find(c=>c.depth===2 && c.phase==='awaiting_reviews');
      if (candidate) await this.close(store,current,candidate,context,signal);
      else await delay(60,undefined,{signal}).catch(error=>{if(!signal.aborted)throw error;});
    }
  }
  start(store,goal,candidates,context,signal) {
    if (this.runs.has(goal.id)) throw new Error('This workflow already has an active stage operation');
    const controller=new AbortController(),monitor=new AbortController();
    controller.signal.addEventListener('abort',()=>monitor.abort(),{once:true});
    const cancel=()=>controller.abort(signal?.reason);signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
    const watcher=this.watchGrandchildren(store,goal,context,monitor.signal);
    const promise=(async()=>{
      try {
        const tasks=await Promise.allSettled(candidates.map(async candidate=>{
          const done=await this.experiment(store,goal,candidate,context,controller.signal);
          if(done)await this.close(store,await store.current(),done,context,controller.signal);
        }));
        return await this.change(store,goal.id,g=>{g.phase=controller.signal.aborted?'paused':g.stages.at(-1).candidates.every(c=>c.phase==='candidate')?'reporting':'rework';g.operationErrors=tasks.filter(t=>t.status==='rejected').map(t=>String(t.reason?.message??t.reason));});
      } finally {monitor.abort();await watcher;signal?.removeEventListener('abort',cancel);this.runs.delete(goal.id);}
    })();
    const run={id:goal.id,parentId:context.sessionManager.getSessionId(),promise,cancel};this.runs.set(goal.id,run);
    promise.then(value=>this.notify(run,value),error=>this.notify(run,{phase:'rework',error:error.message}));
    return {goalId:goal.id,phase:'executing',background:true};
  }
  notify(run,value) {
    if(this.ctx.host.pi.getHarnessSessionId?.()!==run.parentId)return;
    this.ctx.host.pi.sendMessage({customType:'workflow-result',display:true,content:JSON.stringify(value),details:{goalId:run.id,source:'workflow-settled'}},{triggerTurn:true,deliverAs:'followUp'});
  }
  async split(store,goal,args,context,signal) {
    const owner=find(goal,process.env.F_WORKFLOW_CANDIDATE);
    if(process.env.F_WORKFLOW_ROLE!=='experiment' || Number(process.env.F_AGENT_DEPTH)!==1 || !owner || owner.experimenterId!==process.env.F_AGENT_ID || owner.depth!==1 || owner.phase!=='working' || goal.phase!=='executing')throw new Error('Only the active assigned experimenter may split once; closed branches and grandchildren cannot delegate');
    let children;
    if(args.action==='split') {
      if(!Array.isArray(args.subgoals)||!args.subgoals.length||args.subgoals.length>3)throw new Error('A single split requires one to three subgoals');
      args.subgoals.forEach(s=>{boundedReport(s.summary,200,'Grandchild direction');boundedReport(s.method,2000,'Grandchild method');});
      const project=this.project(goal,signal),node=await project.node(owner.node.id),checkpoint=await project.validationState(node);
      if(checkpoint.status)throw new Error('Commit the parent experiment before splitting from its fixed current version');
      await this.patch(store,goal.id,owner.id,c=>{if(c.splitUsed)throw new Error('This branch has already used its one split');c.splitUsed=true;c.children=args.subgoals.map((proposal,i)=>({id:randomUUID(),parentCandidate:owner.id,parentNode:node.id,startCommit:checkpoint.head,baseVersion:owner.baseVersion,number:i+1,depth:2,proposal,children:[],phase:'draft',splitUsed:true}));});
      children=find(await store.current(),owner.id).children;
    } else {
      const child=owner.children.find(c=>c.id===args.candidateId && ['rework','draft'].includes(c.phase));
      if(!child)throw new Error('Retry only one of this experimenter’s existing failed grandchildren');children=[child];
    }
    await Promise.all(children.map(c=>this.experiment(store,goal,c,context,signal)));
    while(true) {
      signal?.throwIfAborted();const current=find(await store.current(),owner.id).children.filter(c=>children.some(ch=>ch.id===c.id));
      if(current.every(c=>['candidate','rework'].includes(c.phase)))return current;
      await delay(80,undefined,{signal});
    }
  }
  async execute(args,context,signal) {
    const store=this.store(context),goal=await store.current();
    if(args.action==='status')return goal ?? {phase:'idle'};
    if(Number(process.env.F_AGENT_DEPTH ?? 0)>0) {
      if(['split','retry'].includes(args.action))return this.split(store,goal,args,context,signal);
      throw new Error('Stage planning, review, publication and selection belong to the main agent');
    }
    if(args.action==='cancel') {const run=goal&&this.runs.get(goal.id);run?.cancel();await run?.promise;return store.current();}
    if(this.operations.has(store.file))throw new Error('Another main-agent stage operation is in progress');
    this.operations.add(store.file);
    try {
      if(args.action==='begin')return await this.begin(args,context,signal);
      if(!goal || goal.complexity!=='complex')throw new Error('Begin a complex staged goal first');
      if(args.action==='plan')return await store.plan(goal.id,args.tree);
      if(args.action==='propose')return await this.propose(store,goal,context,signal);
      if(args.action==='review')return await this.judge(store,goal,args);
      if(args.action==='report') {if(!goal.prosePolish)throw new Error('Load and apply unslop before the stage report');return await store.report(goal.id,args.report);}
      if(args.action==='archive') {if(this.runs.has(goal.id))throw new Error('Cancel and settle the active stage before archiving');return await store.archive(goal.id,args.report);}
      if(args.action==='run' || args.action==='retry') {
        if(args.action==='run' && goal.phase!=='ready')throw new Error('All three methods per stage base must pass the main-agent review before experiments');
        const candidates=args.action==='run'?goal.stages.at(-1).candidates:goal.stages.at(-1).candidates.filter(c=>c.id===args.candidateId && ['rework','working','simplifying','testing','awaiting_reviews'].includes(c.phase));
        if(!candidates.length)throw new Error('Choose an unfinished experiment branch to retry');
        const current=await this.change(store,goal.id,g=>{g.phase='executing';});
        return this.start(store,current,candidates,context,signal);
      }
      throw new Error('Unsupported staged workflow action; script execution and expert voting have been retired');
    } finally {this.operations.delete(store.file);}
  }
  async drain(context,signal) {
    const owned=[...this.runs.values()].filter(r=>r.parentId===context.sessionManager.getSessionId());
    const cancel=()=>owned.forEach(r=>r.cancel());signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
    try {await Promise.allSettled(owned.map(r=>r.promise));} finally {signal?.removeEventListener('abort',cancel);}
  }
  async dispose() {const runs=[...this.runs.values()];runs.forEach(r=>r.cancel());await Promise.allSettled(runs.map(r=>r.promise));}
}
