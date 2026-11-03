import { fork } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import vm from 'node:vm';
import { WorkflowEngine, validateMeta } from '../../dist/upstream.mjs';

export class FWorkflowEngine extends WorkflowEngine {
  runs = new Map();
  constructor(ctx, { maxConcurrentAgents = 4, maxTotalAgents = 32, maxItemsPerCall = 256, syncTimeoutMs = 1000 } = {}) {
    super(ctx); this.limits = { maxConcurrentAgents, maxTotalAgents, maxItemsPerCall, syncTimeoutMs };
    ctx.effect(() => () => this.dispose());
  }
  start({ meta, script, args = {}, parent, signal }) {
    signal?.throwIfAborted(); meta = validateMeta(meta);
    new vm.Script(`(async () => {\n${script}\n})()`); // Admission only; never run model code in the host.
    if (!args || Array.isArray(args) || typeof args !== 'object') throw new Error('workflow args must be an object');
    const id = randomUUID(), controller = new AbortController(), children = new Map(), pending = new Set();
    const manager = this.ctx.subagents; // Capture dependencies for the entire accepted run.
    const processHandle = fork(new URL('./worker.mjs', import.meta.url), { env: {}, cwd: parent.executionCwd ?? parent.cwd,
      detached: true, execArgv: [], stdio: ['ignore','ignore','pipe','ipc'], serialization: 'json' });
    processHandle.stderr.on('data', () => {});
    let settle, settled = false;
    const raw = new Promise(resolve => { settle = value => { if (!settled) { settled = true; resolve(value); } }; });
    const exited = new Promise(resolve => processHandle.once('close', () => {
      settle({ value: null, stopReason: controller.signal.aborted ? 'cancelled' : 'error', error: 'Workflow process ended unexpectedly', agentsStarted: children.size }); resolve();
    }));
    const cancel = () => { controller.abort(); processHandle.kill('SIGKILL'); };
    signal?.addEventListener('abort', cancel, { once: true });
    const eventNames = { phase: 'workflow/phase', log: 'workflow/log', agentStart: 'workflow/agent-start', agentEnd: 'workflow/agent-end' };
    processHandle.on('error', () => settle({ value: null, stopReason: 'error', error: 'Workflow process could not start', agentsStarted: 0 }));
    const handleCall = async message => {
      if (message.method === 'startAgent') {
        controller.signal.throwIfAborted();
        const r = message.request;
        const activation = await manager.startActivation({ provider: 'spawn', label: 'workflow',
          request: { parent, cwd: parent.effectiveCwd ?? parent.cwd, prompt: [{ type: 'text', text: r.prompt }], outputSchema: r.schema,
            agentOptions: { ...(r.provider ? { provider: r.provider } : {}), ...(r.model ? { model: r.model } : {}) } }, signal: controller.signal, delivery: 'caller' });
        children.set(activation.childId, activation);
        if (controller.signal.aborted) { await activation.dispose(); controller.signal.throwIfAborted(); }
        return activation.childId;
      }
      const child = children.get(message.childId);
      if (!child) throw new Error('Workflow does not own this child');
      if (message.method === 'result') return child.result;
      if (message.method === 'dispose') { await child.dispose(); return null; }
      throw new Error('Unknown workflow request');
    };
    processHandle.on('message', message => {
      if (message.type === 'result') { settle(message.value); return; }
      if (message.type === 'event') { this.emitWorkflowEvent(eventNames[message.name], { runId: id, value: message.value }); return; }
      if (message.type !== 'call') return;
      const task = handleCall(message).then(value => {
        if (processHandle.connected) processHandle.send({ type: 'response', id: message.id, value });
      }, error => { if (processHandle.connected) processHandle.send({ type: 'response', id: message.id, error: error.message }); });
      pending.add(task); task.finally(() => pending.delete(task));
    });
    this.emitWorkflowEvent('workflow/start', { runId: id, meta });
    processHandle.send({ type: 'start', meta, script, args, limits: this.limits });
    const result = raw.then(async value => {
      // A result can arrive while the script has dropped child promises. They must still be drained.
      controller.abort(); processHandle.kill('SIGKILL');
      await Promise.allSettled([...pending]);
      await Promise.all([...children.values()].map(async child => { await child.dispose(); await child.result; }));
      await exited; signal?.removeEventListener('abort', cancel);
      this.runs.delete(id);
      this.emitWorkflowEvent('workflow/end', { runId: id, ...value });
      return value;
    });
    const run = { id, parentId: parent.sessionManager.getSessionId(), meta, result, cancel, dispose: async () => { cancel(); await result; } };
    this.runs.set(id, run); return run;
  }
  async dispose() { await Promise.all([...this.runs.values()].map(run => run.dispose())); }
}
