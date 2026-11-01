import { FWorkflowEngine } from './engine.mjs';
import { snapshotParent } from '../subagent/index.mjs';
import { result, objectSchema, stringSchema } from '../core/kernel.mjs';

export async function mountWorkflow(ctx) {
  await ctx.plugin({ name: 'f-workflow', inject: ['subagents', 'host', 'tools', 'systemPrompt'], apply(ctx) {
    const engine = new FWorkflowEngine(ctx);
    const records = new Map();
    ctx.tools.register({ name: 'workflow', label: 'Workflow',
      description: 'ONLY for explicit workflows or large multi-agent orchestration. Write a JavaScript async function body with no exports. Hooks: await agent(prompt,{label?,phase?,schema?,provider?,model?}) returns text/structured value or null for child failure; await parallel([()=>...]) runs thunks; await pipeline(items,...stages) transforms items; phase(title), log(text); args is an object. Return plain JSON. Runs in a separate cancellable Node process; max 4 concurrent and 32 total agents. VM is not a security boundary.',
      parameters: objectSchema({ meta: objectSchema({ name: stringSchema, description: stringSchema, whenToUse: stringSchema,
        phases: { type: 'array', items: objectSchema({ title: stringSchema, detail: stringSchema, provider: stringSchema, model: stringSchema }, ['title']) } }, ['name','description']),
        script: stringSchema, args: { type: 'object', additionalProperties: true }, run_in_background: { type: 'boolean' } }, ['meta','script']),
      async execute(_id, input, signal, update, context) {
        const parent = snapshotParent(context);
        if (process.env.F_REMOTE_PROJECT) parent.effectiveCwd = JSON.parse(process.env.F_REMOTE_PROJECT).cwd;
        const run = engine.start({ ...input, parent, signal: input.run_in_background ? undefined : signal });
        const record = { runId: run.id, parentId: parent.sessionManager.getSessionId(), state: 'running', meta: input.meta, progress: [] };
        records.set(run.id, record);
        ctx.host.pi.appendEntry('f-workflow/start', { runId: run.id, meta: input.meta });
        const completion = run.result.then(value => {
          record.state = value.stopReason; record.result = value;
          ctx.host.pi.appendEntry('f-workflow/end', { runId: run.id, ...value });
          if (input.run_in_background) ctx.host.pi.sendMessage({ customType: 'workflow-result', display: true,
            content: JSON.stringify({ runId: run.id, ...value }), details: { runId: run.id, source: 'workflow-settled' } }, { triggerTurn: true, deliverAs: 'followUp' });
          return value;
        });
        if (input.run_in_background) return result({ kind: 'background', runId: run.id });
        try {
          const value = await completion;
          if (value.stopReason !== 'completed') throw new Error(`Workflow ${value.stopReason}: ${value.error ?? ''}`);
          return result({ kind: 'foreground', runId: run.id, agentsStarted: value.agentsStarted, result: value.value });
        } finally { await run.dispose(); }
      },
    });
    ctx.tools.register({ name: 'workflow_control', label: 'Workflow status', description: 'List, inspect or cancel owned background workflows.',
      parameters: objectSchema({ action: { type: 'string', enum: ['list','status','cancel'] }, runId: stringSchema }, ['action']),
      async execute(_id, { action, runId }, _signal, _update, context) {
        const owner = context.sessionManager.getSessionId();
        if (action === 'list') return result([...records.values()].filter(r => r.parentId === owner));
        const record = records.get(runId);
        if (!record || record.parentId !== owner) throw new Error('Workflow is not owned by this conversation');
        if (action === 'cancel') await engine.runs.get(runId)?.dispose();
        return result(record);
      } });
    for (const name of ['phase','log','agent-start','agent-end']) ctx.on('workflow/' + name, info => {
      const record = records.get(info.runId);
      if (record && record.parentId === ctx.host.pi.getHarnessSessionId()) {
        if (name === 'agent-start' || name === 'agent-end') ctx.host.pi.appendEntry('f-workflow/' + name, { runId: info.runId, ...info.value });
        record.progress.push({ kind: name, value: info.value }); if (record.progress.length > 200) record.progress.shift(); }
    });
    ctx.host.on(ctx, 'agent_before_settle', async (event, context) => {
      const cancel = () => { for (const run of engine.runs.values()) if (run.parentId === context.sessionManager.getSessionId()) run.cancel(); };
      context.signal?.addEventListener('abort', cancel, { once: true });
      if (event.outcome === 'aborted' || context.signal?.aborted) cancel();
      try { await Promise.all([...engine.runs.values()].filter(r => r.parentId === context.sessionManager.getSessionId()).map(r => r.result)); } finally { context.signal?.removeEventListener('abort', cancel); }
    });
    ctx.host.on(ctx, 'session_before_switch', async () => { await engine.dispose(); });
    ctx.systemPrompt.register('workflow', () => 'Use workflow ONLY when the user explicitly requests a workflow or large multi-agent orchestration. For one or two delegations, use subagent. Workflow children return to the script, not to this conversation. Cancel or failure is never partial success.');
  }});
}
