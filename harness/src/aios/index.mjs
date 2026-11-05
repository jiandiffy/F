import path from 'node:path';
import os from 'node:os';
import { realpath } from 'node:fs/promises';
import { GoalState, boundedReport } from './state.mjs';
import { CapabilityBus } from './bus.mjs';
import { leasesFor, resourceOwner, resourceDirectory } from './leases.mjs';
import { result, objectSchema, stringSchema } from '../core/kernel.mjs';
import { snapshotParent } from '../subagent/index.mjs';
import { hasSandbox, maintenanceShellGuard, extendMaintenanceShell } from '../skills/maintenance.mjs';
import { VersionProject } from '../versions/project.mjs';
import { command } from '../datasets/providers.mjs';
import { workflowFields, workflowText } from '../workflow/index.mjs';
import { workflowAccess } from '../workflow/ownership.mjs';

const arrayOfStrings = { type: 'array', items: stringSchema };
const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
const rectangleSchema = objectSchema(Object.fromEntries(['x','y','width','height'].map(k => [k, { type: 'number' }])));
const textOf = value => value.output?.filter(c => c.type === 'text').map(c => c.text).join('\n') ?? '';
const checkSchema = objectSchema({ subgoal: stringSchema, method: stringSchema, passed: { type: 'boolean' }, evidence: stringSchema });

export async function mountAIOS(ctx, { root, dataRoot, enabled = true } = {}) {
  enabled = enabled && Number(process.env.F_AGENT_DEPTH ?? 0) === 0;
  await ctx.plugin({ name: 'f-aios', inject: ['host','tools','systemPrompt'], apply(scope) {
    const states = new Map(), pins = new Map(), evidence = new Map();
    const stateFor = context => {
      const sessionId = context.sessionManager.getSessionId();
      if (!states.has(sessionId)) states.set(sessionId, new GoalState({ sessionId,
        directory: dataRoot ?? path.join(process.env.F_CONVERSATION_DIR ?? process.env.F_BOARD_DIR ?? path.join(os.homedir(),'Library/Application Support/F'), 'harness/bus') }));
      return states.get(sessionId);
    };
    scope.provide('goalStates', stateFor);
    const bus = new CapabilityBus(scope, { stateFor });
    scope.on('subagent/event', ({ childId, event }) => {
      if (event.type !== 'tool_execution_end') return;
      const records = evidence.get(childId) ?? [];
      records.push({ toolName: event.toolName, isError: !!event.isError, result: JSON.stringify(event.result ?? {}).slice(0,4000) });
      evidence.set(childId, records.slice(-100));
    });
    async function agent(context, signal, label, prompt, outputSchema, childId) {
      const manager = scope.get('subagents');
      if (!manager) throw new Error('Enable the Subagent plugin to run this phase');
      const activation = await manager.startActivation({ label, childId, request: { parent: snapshotParent(context), prompt: [{ type: 'text', text: prompt }], outputSchema }, signal, delivery: 'caller' });
      const value = await activation.result;
      if (value.stopReason !== 'completed') throw new Error(`${label} failed: ${value.diagnostic ?? value.stopReason}`);
      return { childId: activation.childId, ...value.structured, text: textOf(value), evidence: evidence.get(activation.childId) ?? [] };
    }
    scope.tools.register({ name: 'bus', label: 'Capability bus', description: 'List plugin names/descriptions and activate only capabilities needed by the current goal. Optional tool schemas stay hidden until activation. Inspect recent attributed events.',
      parameters: objectSchema({ action: { type: 'string', enum: ['list','activate','deactivate','events'] }, names: arrayOfStrings }, ['action']),
      async execute(_id, args, _signal, _update, context) {
        if (args.action === 'events') return result(bus.events);
        if (args.action === 'list') return result(await bus.sync(context));
        if (!args.names?.length) throw new Error('Choose capability names from bus list');
        return result(await bus.choose(context, args.names, args.action === 'activate'));
      } });
    scope.tools.register({ name: 'resource_scope', label: 'Resource scope', description: 'Reserve a project board rectangle and/or literal project-relative file paths before writing. Reservations exclude other agents/conversations until released. Re-read after claiming. Transfer only to an owned child; the parent then loses write access.',
      parameters: objectSchema({ action: { type: 'string', enum: ['claim','status','release','delegate'] }, paths: arrayOfStrings, rectangle: rectangleSchema, purpose: stringSchema, leaseId: stringSchema, childId: stringSchema }, ['action']),
      async execute(_id, args, _signal, _update, context) {
        const leases = leasesFor(context), owner = resourceOwner(context);
        if (args.action === 'status') return result(await leases.status());
        if (args.action === 'claim') return result(await leases.claim({ ...args, owner }));
        if (args.action === 'release') return result(await leases.release({ owner, leaseId: args.leaseId }));
        if (!(await scope.get('subagents')?.listChildren(snapshotParent(context)))?.some(c => c.childId === args.childId)) throw new Error('Only an owned direct child can receive a lease');
        return result(await leases.transfer({ owner, leaseId: args.leaseId, childId: args.childId }));
      } });
    if (enabled) scope.tools.register({ name: 'goal_flow', label: 'Goal workflow',
      description: 'Classify simple or complex goals. Complex goals use the staged workflow: publish original, discuss one stage tree and obtain one human approval, 3 distinct experiments per selected base, independent simplification/testing, <=1000-character stage report, human selection of 1–3 candidates. Simple code tasks retain delivered/simplify/test.',
      parameters: objectSchema({ ...workflowFields, action: { type: 'string', enum: ['status','begin','plan','propose','review','run','retry','report','cancel','archive','delivered','simplify','test','rework'] },
        complexity: { type: 'string', enum: ['simple','complex'] }, route: { type: 'string', enum: ['repair','replan'] } }, ['action']),
      async execute(_id, args, signal, update, context) {
        const store = stateFor(context);
        if (args.action === 'status') return result(await store.current() ?? { phase: 'idle' });
        if (args.action === 'begin' && args.complexity === 'complex') {
          const engine=scope.get('workflowEngine');if(!engine)throw new Error('Enable Workflow and Subagent for staged complex goals');
          const goal=await engine.execute(args,context,signal);bus.record('goal-start',goal);return result(goal,workflowText(goal));
        }
        if (args.action === 'begin') { const goal=await store.begin(args);bus.record('goal-start',goal);return result(goal); }
        const goal = await store.current(); if (!goal) throw new Error('Begin a goal first');
        if (goal.complexity === 'complex') {
          const engine=scope.get('workflowEngine');if(!engine)throw new Error('Enable Workflow and Subagent for staged complex goals');
          const value=await engine.execute(args,context,signal);return result(value,workflowText(value));
        }
        let value;
        if (args.action === 'delivered') value=await store.delivered(goal.id,args.report);
        else if (args.action === 'simplify') {
          if (goal.phase !== 'simplifying') throw new Error('Goal is not awaiting simplification');
          const cleaned = await agent(context, signal, '最简化 agent', `目标：${goal.goal}\n执行结果：${goal.executionSummary ?? ''}\n测试反馈：${goal.feedback ?? ''}\n修改范围：${JSON.stringify(args.paths ?? [])}\n审核本项目本次修改，删除已证实无调用者的冗余代码和遮蔽错误的try/catch；保留磁盘/网络/安装边界必要错误处理。先申请 resource_scope 文件范围，重新读文件再修改，最终释放租约。F源码另需maintenance_scope。不要改未授权文件。实际完成清理并报告变更和验证，不得只给建议。`, objectSchema({ report: stringSchema, changedPaths: arrayOfStrings }));
          value = await store.simplified(goal.id, cleaned);
        } else if (args.action === 'test') {
          if (goal.phase !== 'testing') throw new Error('Goal is not awaiting independent testing');
          const versions = !process.env.F_REMOTE_PROJECT && goal.artifact === 'code' ? new VersionProject(context.cwd, { runner: (file, argv, options) => command(file, argv, { ...options, signal }) }) : null;
          const checkpoint = await versions?.goalCheckpoint();
          if (checkpoint && !args.paths?.length) throw new Error('Enabled project versions require explicit owned paths for the tested goal');
          const tested = await agent(context, signal, '独立测试 agent', `目标：${goal.goal}\n技术报告：${goal.technicalReport ?? ''}\n执行结果：${goal.executionSummary}\n修改范围：${JSON.stringify(args.paths ?? [])}\n根据目标自行设计子目标与验收方法，实际执行验证。${goal.artifact === 'code' ? '对修改部分设计暴力、边界和随机测试，并记录可复现命令与结果。' : ''}\n不要修改交付物。需要能力先bus activate，测试夹具放临时目录。只把实际验证通过的子目标标为passed。report必须<=1000字。`, objectSchema({ passed: { type: 'boolean' }, report: stringSchema, checks: { type: 'array', items: checkSchema } }));
          if (signal?.aborted) throw new Error('Independent goal test cancelled');
          if (checkpoint && tested.passed) await versions.assertValidationState(await versions.node('root'), checkpoint);
          value = await store.tested(goal.id, tested);
          if (checkpoint && value.phase === 'complete') {
            let version;
            try {
              version = await versions.recordGoal({ goal: value, paths: args.paths, expected: checkpoint, signal });
            } catch (error) {
              const message = String(error?.message ?? error).slice(0, 900);
              await store.update(goal.id, 'complete', entry => {
                entry.phase = 'rework';
                entry.feedback = '大版本记录失败：' + message;
                entry.versionFailure = { message, at: new Date().toISOString() };
              });
              throw new Error('独立测试已通过，但大版本记录失败，目标已转入修复：' + message);
            }
            if (value.versionFailure) value = await store.update(goal.id, 'complete', entry => {
              delete entry.versionFailure;
              entry.feedback = '';
            });
            bus.record('version-major', { goalId: value.id, version });
            value = { ...value, version };
          }
        } else if (args.action === 'rework') value = await store.rework(goal.id, { route: args.route, reason: args.report });
        else throw new Error('Unsupported goal action');
        bus.record('goal-transition', { id: value.id, phase: value.phase, revision: value.revision });
        return result(value);
      } });
    scope.host.on(scope, 'before_agent_start', async (_event, context) => { await bus.sync(context); });
    scope.systemPrompt.register('aios', async (_event, context) => {
      const current = enabled ? await stateFor(context).current() : undefined;
      const catalog = bus.catalog().filter(c => c.name !== 'core').map(c => ({ name: c.name, description: c.description }));
      if (!enabled || !scope.host.pi.getActiveTools().includes('goal_flow')) return `${Number(process.env.F_AGENT_DEPTH ?? 0) > 0 ? '你只完成当前分工并返回结果；目标编排与审核由主agent负责。' : '按当前用户任务直接执行；当前目标编排已关闭或未授权。'}F 能力总线：先 bus list，根据 name/description 按需 activate。画板写入必须 resource_scope 申请矩形，多agent文件修改先申请范围并重读后再改，结束时释放。能力：${JSON.stringify(catalog)}`;
      return 'F 是插件化 AI OS。每个目标先 goal_flow begin 判断 simple 或 complex。简单目标直接执行；复杂目标先上传排除凭据的原始 Git 版本，与用户讨论阶段目标树，只批准一次。每个入选起点派3个方向作者，各<=200字。主 Agent 判断方法成立且互不重复，不通过者重提；全通过后 run 从固定起点创建3条分支。实验者自己 commit，可自行拆分一次、最多3个孙实验者，孙不得再拆。每条分支含孙分支都要独立精简和测试，两者不同且不是实验者；失败退回原实验者 retry。全部收成已上传候选后，主 Agent 使用 unslop 写<=1000字阶段报告。只有用户输入可挑1至3个版本；下一阶段每个入选版本再派3人，不重新批准目标树。所有子代理固定cbi/deepseek-v4.1-flash/medium。按name/description发现并按需 bus activate 主线skills、datasets和应用工具。资源写入先申请resource_scope并重读，完成后释放。简单代码交付仍 delivered → simplify → test；自然语言交付需实际加载unslop。\\n能力目录：'+JSON.stringify(catalog)+'\n当前目标：'+JSON.stringify(current ?? null);
    });
    scope.host.on(scope, 'tool_call', async (event, context) => {
      if (!['write','edit','bash'].includes(event.toolName)) return;
      try {
        const store = stateFor(context), goal = await store.current();
        const access=await workflowAccess();
        const planning = (access && !access.canWrite) || ['proposal','tester'].includes(process.env.F_WORKFLOW_ROLE) || (goal?.complexity === 'complex' && goal.phase !== 'complete');
        const required = Number(process.env.F_AGENT_DEPTH ?? 0) > 0 || (goal?.complexity === 'complex' && goal.phase !== 'complete');
        const leases = leasesFor(context), owner = resourceOwner(context);
        if (process.env.F_REMOTE_PROJECT) {
          if (required || planning) throw new Error('Remote multi-agent mutations and shell execution require a remote lease provider; use read tools or a single execution owner');
          return;
        }
        if (event.toolName === 'bash') {
          const guard = maintenanceShellGuard(event);
          if (guard && guard.mode !== 'sandbox') return;
          const state = await leases.status(), leased = state.leases.some(l => l.paths.length);
          if (!goal && !required && !planning && !leased) return;
          const scoped=required || planning || leased;
          const allowed = planning ? [] : state.leases.filter(l => l.owner === owner).flatMap(l => l.paths);
          if (!hasSandbox()) throw new Error('Scoped shell execution requires sandbox-exec; use read tools or leased write/edit');
          const exceptions = allowed.map(p => `(require-not (subpath ${JSON.stringify(p)}))`).join('');
          const project = await realpath(context.cwd), metadata = await realpath(resourceDirectory(context));
          const shared=process.env.F_SHARED_PROJECT && path.resolve(process.env.F_SHARED_PROJECT)!==project ? await realpath(process.env.F_SHARED_PROJECT) : null;
          const stateDirectory=path.dirname(store.file), workflowDirectory=process.env.F_WORKFLOW_STATE_FILE && path.dirname(process.env.F_WORKFLOW_STATE_FILE);
          const rules = (scoped?`(deny file-write* (require-all (subpath ${JSON.stringify(project)})${exceptions}))`:'')+`(deny file-write* (subpath ${JSON.stringify(metadata)}))(deny file-write* (subpath ${JSON.stringify(stateDirectory)}))`+(workflowDirectory?`(deny file-write* (subpath ${JSON.stringify(workflowDirectory)}))`:'')+(shared?`(deny file-write* (subpath ${JSON.stringify(shared)}))`:'');
          const tokens = await leases.pinLeases({ owner, leaseIds: state.leases.filter(l => l.owner === owner && l.paths.length).map(l => l.id) });
          if (tokens.length) pins.set(event.toolCallId, { leases, tokens });
          if (extendMaintenanceShell(event, rules)) return;
          const profile = '(version 1)(allow default)' + rules;
          event.input.command = `/usr/bin/sandbox-exec -p ${quote(profile)} /bin/bash --noprofile --norc -c ${quote(String(event.input.command ?? ''))}`;
          return;
        }
        if (planning) throw new Error('The current report must be approved by the user before project edits');
        const file = path.resolve(context.cwd, event.input.path ?? '');
        if (file === resourceDirectory(context) || file.startsWith(resourceDirectory(context) + path.sep)) throw new Error('Use resource_scope to change reservations');
        if (!file.startsWith(path.resolve(context.cwd) + path.sep)) { if (required) throw new Error('Multi-agent writes must stay in the declared project'); return; }
        const token = await leases.pinFile({ owner, file, required });
        if (token) pins.set(event.toolCallId, { leases, tokens: [token] });
      } catch (error) { return { block: true, reason: error.message }; }
    });
    scope.host.on(scope, 'tool_result', async (event, context) => {
      if (event.toolName === 'skill' && event.input?.name === 'unslop' && !event.isError) await stateFor(context).skillUsed('unslop');
    });
    scope.host.on(scope, 'tool_execution_end', async event => {
      const pin = pins.get(event.toolCallId); if (pin) { for (const token of pin.tokens) await pin.leases.unpin(token); pins.delete(event.toolCallId); }
    });
    scope.effect(() => async () => { for (const { leases, tokens } of pins.values()) for (const token of tokens) await leases.unpin(token); });
  }});
}
