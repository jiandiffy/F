import { FWorkflowEngine } from './engine.mjs';
import { result, objectSchema, stringSchema } from '../core/kernel.mjs';

const strings={type:'array',items:stringSchema};
export const workflowFields={
  action:{type:'string',enum:['begin','plan','propose','review','run','retry','report','status','cancel','split','archive']},
  goal:stringSchema,artifact:{type:'string',enum:['code','prose','other']},repository:stringSchema,paths:strings,
  tree:{type:'object',additionalProperties:true},candidateId:stringSchema,report:stringSchema,distinctness:stringSchema,
  judgments:{type:'array',items:objectSchema({candidateId:stringSchema,valid:{type:'boolean'},reason:stringSchema})},
  subgoals:{type:'array',items:objectSchema({summary:stringSchema,method:stringSchema,hypothesis:stringSchema,evaluation:stringSchema})},
};
export function workflowText(value) {
  let text=JSON.stringify(value,null,2);
  if(value.phase==='tree_review')text+='\n请向用户展示阶段目标树。用户输入“批准阶段目标树”即可一次批准，或使用 /goal approve '+value.id+' '+value.revision+'。实验方法由主 Agent 后续审核，不再要求用户批准。';
  if(value.phase==='direction_review')text+='\n主 Agent 逐项判断方法成立且互不重复，提交 review 的 judgments 和 distinctness。不通过者使用 propose 重提。';
  if(value.phase==='reporting')text+='\n全部分支已独立精简、测试并上传。主 Agent 应加载 unslop，写不超过1000字阶段报告，调用 report。';
  if(value.phase==='selection')text+='\n请用户挑选1至3个版本，输入“选择候选 1 3”等。候选序号按本阶段 candidates 的顺序。仅用户输入能进入下一阶段。';
  return text;
}
export async function mountWorkflow(ctx,options={}) {
  await ctx.plugin({name:'f-workflow',inject:['subagents','host','tools','systemPrompt'],apply(ctx){
    const engine=new FWorkflowEngine(ctx,options);
    ctx.tools.register({name:'workflow',label:'阶段实验工作流',
      description:'Staged experiments for complex goals. begin publishes a secret-scanned original private Git snapshot; plan submits a stage-goal tree for one human approval. propose starts 3 direction authors per selected base (<=200 characters each); review is the main agent’s validity/distinctness decision. run creates 3 isolated fixed-base branches per base, with independent simplifier and tester gates. Failed branches use retry. report submits <=1000 characters, then only user input selects 1–3 published candidates for the next stage. An assigned experimenter may split once into <=3 grandchildren, never deeper. All children are cbi/deepseek-v4.1-flash/medium. No JavaScript script API.',
      parameters:objectSchema(workflowFields,['action']),
      async execute(_id,args,signal,_update,context){const value=await engine.execute(args,context,signal);return result(value,workflowText(value));}});
    ctx.tools.register({name:'workflow_control',label:'Workflow status',description:'Inspect or cancel only this conversation’s staged experiment work.',
      parameters:objectSchema({action:{type:'string',enum:['list','status','cancel']},runId:stringSchema},['action']),
      async execute(_id,args,signal,_update,context){
        const current=await engine.execute({action:'status'},context,signal);
        if(args.runId && args.runId!==current.id)throw new Error('Workflow is not owned by this conversation');
        const value=args.action==='cancel'?await engine.execute({action:'cancel'},context,signal):current;
        return result(args.action==='list'?(value.phase==='idle'?[]:[value]):value);
      }});
    if (Number(process.env.F_AGENT_DEPTH ?? 0) === 0) ctx.host.on(ctx, 'input', async (event, context) => {
      if (!['interactive','rpc'].includes(event.source)) return;
      const store=engine.store(context),current=await store.current();
      const match=/^\/goal\s+(approve|revise|select)\s+([a-f0-9-]+)\s+(\d+)(?:\s+([\s\S]+))?$/.exec(event.text.trim());
      let request;
      if(match)request={decision:match[1],id:match[2],revision:Number(match[3]),feedback:match[4]??'',selections:match[1]==='select'?(match[4]??'').trim().split(/\s+/):undefined};
      else if(current?.phase==='tree_review' && /^(?:我)?批准(?:这棵)?阶段目标树[。！!]?$/u.test(event.text.trim()))request={decision:'approve',id:current.id,revision:current.revision};
      else if(current?.phase==='selection' && /^选择候选\s+[1-9](?:[\s,，、和]+[1-9]){0,2}$/u.test(event.text.trim())) {
        const indexes=event.text.match(/[1-9]/g).map(Number),candidates=current.stages.at(-1).candidates;
        request={decision:'select',id:current.id,revision:current.revision,selections:indexes.map(i=>candidates[i-1]?.version?.id)};
      }
      if(!request)return;
      const value=await store.review(request);
      ctx.get('bus')?.record('user-review',{id:value.id,phase:value.phase,revision:value.revision});
      return {action:'transform',text:'用户输入已通过工作流状态校验。'+workflowText(value)+'。按当前阶段继续，不能再次请求目标树审批。'};
    });

    ctx.host.on(ctx,'agent_before_settle',async(event,context)=>{
      if(event.outcome==='aborted')await engine.dispose();
      await engine.drain(context,context.signal);
    });
    ctx.host.on(ctx,'session_before_switch',()=>engine.dispose());
    ctx.systemPrompt.register('workflow',()=> Number(process.env.F_AGENT_DEPTH ?? 0)>0 ? 'Only complete your assigned role. Do not plan stages or approve/select versions. Only a top-level assigned experimenter may call workflow split once, with at most three experimental grandchildren. Testers/proposal authors cannot write; reviewers cannot delegate. Use mainline skills, datasets and enabled tools as needed.' : 'Complex goals use only the staged workflow. Publish original first, discuss a stage-goal tree with the human, obtain one tree approval, then main-agent review of 3 distinct methods per selected base. The human intervenes again only to select 1–3 candidates after each <=1000-character stage report. Every experimental branch, including grandchildren, needs a new simplifier and a different tester, neither its experimental author. Test failure returns to that same author for repair. Split is once per top-level experiment, <=3 experimental grandchildren; reviewers are dispatched by the main agent, not counted as grandchildren. Never forge human approval or select candidates with a tool. All managed children are fixed to cbi/deepseek-v4.1-flash/medium and inherit mainline skills, datasets and enabled tools. Legacy expert voting and arbitrary workflow scripts are retired.');
  }});
}
