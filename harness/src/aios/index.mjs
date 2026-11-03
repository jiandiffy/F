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
    if (enabled) scope.tools.register({ name: 'goal_flow', label: 'Goal state machine', description: 'Manage goal phases. begin classifies simple/complex and code/prose/other. discuss runs research + three experts and an independent voting round. plan submits <=1000-character technical report. Only user /goal approve can cross review gates. delivered triggers simplification/testing; simplify runs a dedicated cleanup agent; test runs an independent goal-derived tester; rework chooses repair/replan.',
      parameters: objectSchema({ action: { type: 'string', enum: ['status','begin','discuss','plan','delivered','simplify','test','rework'] }, goal: stringSchema, complexity: { type: 'string', enum: ['simple','complex'] }, artifact: { type: 'string', enum: ['code','prose','other'] }, domains: arrayOfStrings, report: stringSchema, route: { type: 'string', enum: ['repair','replan'] }, paths: arrayOfStrings }, ['action']),
      async execute(_id, args, signal, update, context) {
        const store = stateFor(context);
        if (args.action === 'status') return result(await store.current() ?? { phase: 'idle' });
        if (args.action === 'begin') { const goal = await store.begin(args); bus.record('goal-start', goal); return result(goal); }
        const goal = await store.current(); if (!goal) throw new Error('Begin a goal first');
        let value;
        if (args.action === 'discuss') {
          if (goal.phase !== 'discussing') throw new Error('Goal is not awaiting discussion');
          const previous = goal.rounds.at(-1), common = `目标：${goal.goal}\n用户反馈：${goal.feedback ?? '无'}\n请只研究与讨论，不修改项目文件。需要能力时先 bus list/activate，引用真实来源，不编造证据。`;
          update?.(result({ phase: 'research-and-experts' }));
          const tasks = [agent(context, signal, 'research', common + '\n负责 arXiv / Zotero 文献研究，返回可验证引用与适用性。可使用 datasets 插件把确实读取的论文加入 paper dataset。', objectSchema({ report: stringSchema, sources: arrayOfStrings })),
            ...goal.domains.map((domain, i) => agent(context, signal, domain + '专家', common + `\n你是${domain}专家。提出算法架构、约束与验收标准，report 不超过200字。`, objectSchema({ report: stringSchema, rationale: stringSchema }), previous?.candidates[i]?.childId))];
          const settled = await Promise.allSettled(tasks);
          const failure = settled.find(r => r.status === 'rejected'); if (failure) throw failure.reason;
          const [research, ...candidates] = settled.map(r => r.value);
          candidates.forEach(c => boundedReport(c.report, 200, 'Expert proposal'));
          update?.(result({ phase: 'expert-vote' }));
          const votes = await Promise.all(candidates.map((candidate, i) => agent(context, signal, goal.domains[i] + '专家',
            common + '\n研究结果：' + JSON.stringify(research) + '\n三个候选：' + JSON.stringify(candidates.map(c => ({ childId: c.childId, report: c.report, rationale: c.rationale }))) + '\n讨论后选择最能完成目标的候选childId作为proposalId，可以选择其他专家的方案。rationale说明共识或分歧。', objectSchema({ proposalId: stringSchema, rationale: stringSchema }), candidate.childId)));
          value = await store.consensus(goal.id, { research, candidates, votes });
        } else if (args.action === 'plan') value = await store.plan(goal.id, args.report);
        else if (args.action === 'delivered') value = await store.delivered(goal.id, args.report);
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
        if (['consensus_review','plan_review'].includes(value.phase)) return result(value, JSON.stringify(value, null, 2) + `\n请用户审核：/goal approve ${value.id} ${value.revision}\n修改意见：/goal revise ${value.id} ${value.revision} 修改要求`);
        return result(value);
      } });
    if (enabled) scope.host.on(scope, 'input', async (event, context) => {
      if (!['interactive','rpc'].includes(event.source)) return;
      const match = /^\/goal\s+(approve|revise)\s+([a-f0-9-]+)\s+(\d+)(?:\s+([\s\S]+))?$/.exec(event.text.trim());
      if (!match) return;
      const value = await stateFor(context).review({ decision: match[1], id: match[2], revision: Number(match[3]), feedback: match[4] ?? '' });
      bus.record('user-review', { id: value.id, phase: value.phase, revision: value.revision });
      return { action: 'transform', text: `用户已${match[1] === 'approve' ? '批准' : '要求修改'}当前报告。状态机已验证：${JSON.stringify(value)}。按当前phase继续。` };
    });
    scope.host.on(scope, 'before_agent_start', async (_event, context) => { await bus.sync(context); });
    scope.systemPrompt.register('aios', async (_event, context) => {
      const current = enabled ? await stateFor(context).current() : undefined;
      const catalog = bus.catalog().filter(c => c.name !== 'core').map(c => ({ name: c.name, description: c.description }));
      if (!enabled || !scope.host.pi.getActiveTools().includes('goal_flow')) return `${Number(process.env.F_AGENT_DEPTH ?? 0) > 0 ? '你只完成当前分工并返回结果；目标编排与审核由主agent负责。' : '按当前用户任务直接执行；当前目标编排已关闭或未授权。'}F 能力总线：先 bus list，根据 name/description 按需 activate。画板写入必须 resource_scope 申请矩形，多agent文件修改先申请范围并重读后再改，结束时释放。能力：${JSON.stringify(catalog)}`;
      return `F 是插件化 AI OS。每个目标先 goal_flow begin，用判断选择 simple 或 complex；简单目标单agent处理，复杂目标用 discuss 建立研究员与三领域专家，达到共识和技术计划分别等待用户 /goal approve 审核。不能用工具或自己发消息伪造批准。仅按需用 bus activate 启用能力，停用不用的能力。工具/技能/数据集按 name、description 发现。画板必须先 resource_scope 申请矩形；多agent文件修改先申请范围，重读后再改、完毕释放。完成工程后 goal_flow delivered → simplify → test；测试失败由主agent选择 repair 或 replan。自然语言交付必须调用并应用 unslop 技能，运行时记录真实加载；简单非代码目标在 delivered 后直接完成，不增加测试子agent。技术/测试报告各<=1000字，共识<=200字。\n能力目录：${JSON.stringify(catalog)}\n当前目标：${JSON.stringify(current ?? null)}`;
    });
    scope.host.on(scope, 'tool_call', async (event, context) => {
      if (!['write','edit','bash'].includes(event.toolName)) return;
      const store = stateFor(context), goal = enabled ? await store.current() : undefined;
      const planning = goal && ['discussing','consensus_review','planning','plan_review'].includes(goal.phase);
      const required = Number(process.env.F_AGENT_DEPTH ?? 0) > 0 || goal?.complexity === 'complex';
      const leases = leasesFor(context), owner = resourceOwner(context);
      try {
        if (process.env.F_REMOTE_PROJECT) {
          if (required || planning) throw new Error('Remote multi-agent mutations and shell execution require a remote lease provider; use read tools or a single execution owner');
          return;
        }
        if (event.toolName === 'bash') {
          const guard = maintenanceShellGuard(event);
          if (guard && guard.mode !== 'sandbox') return;
          const state = await leases.status();
          if (!required && !planning && !state.leases.some(l => l.paths.length)) return;
          const allowed = planning ? [] : state.leases.filter(l => l.owner === owner).flatMap(l => l.paths);
          if (!hasSandbox()) throw new Error('Scoped shell execution requires sandbox-exec; use read tools or leased write/edit');
          const exceptions = allowed.map(p => `(require-not (subpath ${JSON.stringify(p)}))`).join('');
          const project = await realpath(context.cwd), metadata = await realpath(resourceDirectory(context));
          const rules = `(deny file-write* (require-all (subpath ${JSON.stringify(project)})${exceptions}))(deny file-write* (subpath ${JSON.stringify(metadata)}))`;
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
