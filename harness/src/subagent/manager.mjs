import { Service, assertObjectJsonSchema, validateJsonSchemaValue } from '../../dist/upstream.mjs';
import { mkdir, readFile, writeFile, rename, readdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { watch } from 'node:fs';
import { randomUUID, createHash } from 'node:crypto';
import { ChildRPC } from './rpc.mjs';

/** F provider for the DSH activation contract, with Pi's persistent session format. */
export class SubagentManager extends Service {
  providers = new Map(); active = new Map(); catalogs = new Map(); writes = new Map();
  constructor(ctx, options) { super(ctx, 'subagents'); this.options = options; }
  registerProvider(provider) {
    return this.ctx.effect(() => {
      if (this.providers.has(provider.name)) throw new Error(`Duplicate subagent provider: ${provider.name}`);
      this.providers.set(provider.name, provider);
      return () => this.providers.delete(provider.name);
    });
  }
  directory(parent) {
    const owner = createHash('sha256').update(parent.sessionManager.getSessionId()).digest('hex');
    return path.join(this.options.dataRoot, owner);
  }
  async catalog(parent) {
    const directory = this.directory(parent);
    if (!this.catalogs.has(directory)) {
      const file = path.join(directory, 'catalog.json');
      const loading = readFile(file, 'utf8').then(JSON.parse, error => {
        if (error.code !== 'ENOENT') throw error;
        return [];
      });
      this.catalogs.set(directory, loading);
    }
    return this.catalogs.get(directory);
  }
  async persist(parent) {
    const directory = this.directory(parent), catalog = await this.catalog(parent);
    const previous = this.writes.get(directory) ?? Promise.resolve();
    const writing = previous.then(async () => {
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const tmp = path.join(directory, `catalog.${randomUUID()}.tmp`);
      await writeFile(tmp, JSON.stringify(catalog, null, 2), { mode: 0o600 });
      await rename(tmp, path.join(directory, 'catalog.json'));
    });
    this.writes.set(directory, writing); await writing;
  }
  async listChildren(parent) {
    return (await this.catalog(parent)).map(entry => ({ childId: entry.childId, provider: entry.provider, label: entry.label, cwd: entry.cwd, depth: entry.depth, state: this.active.has(entry.childId) ? 'running' : 'inactive',
      mode: this.providers.has(entry.provider) ? 'continuable' : 'unknown' }));
  }
  async startActivation({ provider = 'spawn', label, request, signal, delivery = 'parent', childId }) {
    signal?.throwIfAborted();
    const backend = this.providers.get(provider);
    if (!backend) throw new Error(`Unknown subagent provider: ${provider}`);
    const parent = request.parent, depth = Number(process.env.F_AGENT_DEPTH ?? 0) + 1;
    const maxDepth = Math.min(request.maxDepth ?? this.options.maxDepth, this.options.maxDepth);
    if (!Number.isSafeInteger(maxDepth) || maxDepth < 0 || depth > maxDepth) throw new Error('Subagent delegation depth exceeded');
    if (request.agentPreset !== undefined && !backend.capabilities.agentPreset) throw new Error('Provider does not support agentPreset');
    if (request.outputSchema && !backend.capabilities.outputSchema) throw new Error('Provider does not support outputSchema');
    if (request.outputSchema) assertObjectJsonSchema(request.outputSchema);
    const catalog = await this.catalog(parent);
    let entry = childId && catalog.find(c => c.childId === childId);
    if (childId && !entry) throw new Error('Child is not owned by this parent');
    if (this.active.size >= this.options.maxConcurrentAgents) throw new Error('Subagent capacity reached');
    if (childId && this.active.has(childId)) throw new Error('Child already has an active activation');
    const id = childId ?? randomUUID();
    const record = { parent, controller: new AbortController(), child: undefined };
    record.ready = new Promise(resolve => { record.markReady = resolve; });
    this.active.set(id, record); // Reserve capacity before asynchronous preparation.
    const onAbort = () => record.controller.abort(signal.reason);
    signal?.addEventListener('abort', onAbort, { once: true });
    if (signal?.aborted) onAbort();
    const controller = record.controller;
    let child, relay;
    try {
      const remote = process.env.F_REMOTE_PROJECT && JSON.parse(process.env.F_REMOTE_PROJECT);
      const origin = remote?.cwd ?? parent.cwd;
      const cwd = entry?.cwd ?? path.resolve(origin, request.cwd ?? '.');
      const route = entry?.agentOptions ?? { provider: parent.model?.provider, model: parent.model?.id, reasoningEffort: parent.thinkingLevel,
        ...request.agentOptions };
      const directory = this.directory(parent);
      await mkdir(directory, { recursive: true, mode: 0o700 });
      entry ??= { childId: id, provider, label: label ?? 'subagent', cwd, depth, agentOptions: route,
        sessionFile: path.join(directory, id + '.jsonl') };
      const env = { ...process.env, F_AGENT_DEPTH: String(entry.depth), F_PARENT_AGENT_ID: parent.sessionManager.getSessionId(), F_AGENT_ID: id };
      // A child can never publish a self-update manifest on behalf of its root conversation.
      env.F_UPDATE_DELEGATED = '1';
      env.F_AGENT_RELAY_DIR = path.join(directory, 'relay', id);
      await mkdir(env.F_AGENT_RELAY_DIR, { recursive: true, mode: 0o700 });
      let reading = Promise.resolve();
      const scan = async () => {
        const names = (await readdir(env.F_AGENT_RELAY_DIR)).filter(name => name.endsWith('.json')).sort();
        for (const name of names) {
          const file = path.join(env.F_AGENT_RELAY_DIR, name);
          const message = JSON.parse(await readFile(file, 'utf8'));
          if (typeof message.text !== 'string' || message.text.length > 64000) throw new Error('Invalid child relay message');
          await unlink(file);
          this.options.deliverMessage?.(parent, id, message.text);
        }
      };
      relay = watch(env.F_AGENT_RELAY_DIR, { persistent: false }, () => {
        reading = reading.then(scan).catch(error => this.ctx.logger.error(error));
      });
      relay.on('error', error => this.ctx.logger.error(error));
      record.closeRelay = async () => { relay.close(); await reading; await scan(); };
      if (remote) env.F_REMOTE_PROJECT = JSON.stringify({ ...remote, cwd });
      child = await backend.start({ cli: this.options.cli, entry, cwd: remote ? (process.env.F_LOCAL_PROJECT ?? process.cwd()) : cwd, env, parent,
        onEvent: event => this.ctx.emit('subagent/event', { childId: id, event }) });
      record.child = child;
      const stop = () => { void child.dispose(); };
      controller.signal.addEventListener('abort', stop, { once: true });
      controller.signal.throwIfAborted();
      if (route.provider && route.model) await child.request('set_model', { provider: route.provider, modelId: route.model });
      if (route.reasoningEffort) await child.request('set_thinking_level', { level: route.reasoningEffort });
      const prompt = request.prompt.map(c => c.text ?? '').join('\n');
      const instructions = request.outputSchema ? `\nReturn ONLY a JSON object matching this schema: ${JSON.stringify(request.outputSchema)}` : '';
      // Attach settlement handlers before catalog I/O, including an immediate RPC rejection.
      const outcome = child.prompt(prompt + instructions).then(value => ({ value }), error => ({ error }));
      if (!childId) { catalog.push(entry); await this.persist(parent); }
      this.ctx.emit('subagent/start', { childId: id, provider, label: entry.label });
      let disposal;
      const dispose = () => disposal ??= (async () => { controller.abort(); await child.dispose(); await result; })();
      const result = outcome.then(async settled => {
        let value;
        try {
          if (settled.error) throw settled.error;
          value = settled.value;
          if (request.outputSchema && value.stopReason === 'completed') {
            const text = value.output.filter(c => c.type === 'text').map(c => c.text).join('').trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
            try {
              const structured = JSON.parse(text);
              const errors = validateJsonSchemaValue(request.outputSchema, structured);
              if (errors.length) throw new Error(errors.join('; '));
              value = { ...value, structured };
            } catch { value = { ...value, stopReason: 'error', diagnostic: 'Child output did not satisfy outputSchema' }; }
          }
        } finally {
          try { await child.dispose(); await record.closeRelay(); }
          finally {
            this.active.delete(id);
            signal?.removeEventListener('abort', onAbort);
            controller.signal.removeEventListener('abort', stop);
          }
        }
        this.ctx.emit('subagent/end', { childId: id, ...value });
        if (delivery === 'parent' && (record.interrupted || !controller.signal.aborted)) this.options.deliver(parent, id, value);
        return value;
      });
      result.catch(error => this.ctx.logger.error(error));
      record.result = result; record.markReady();
      return { childId: id, result, dispose };
    } catch (error) {
      try {
        if (child) await child.dispose();
        if (record.closeRelay) await record.closeRelay();
      } finally {
        this.active.delete(id); record.markReady(); signal?.removeEventListener('abort', onAbort);
      }
      throw error;
    }
  }
  async sendMessage(parent, id, text, signal) {
    const entry = (await this.catalog(parent)).find(c => c.childId === id);
    if (!entry) throw new Error('Only an owned direct child can receive a message');
    const record = this.active.get(id);
    if (record) return record.child.request('prompt', { message: text, streamingBehavior: 'steer' });
    return this.startActivation({ provider: entry.provider, childId: id, label: entry.label,
      request: { parent, prompt: [{ type: 'text', text }] }, signal, delivery: 'parent' });
  }
  async interrupt(parent, id) {
    if (!(await this.catalog(parent)).some(c => c.childId === id)) throw new Error('Child is not owned by this parent');
    const record = this.active.get(id);
    if (record) { record.interrupted = true; record.controller.abort(); await record.ready; await record.child?.dispose(); await record.result; }
  }
  async drain(parent, signal) {
    const abort = () => { for (const r of this.active.values()) if (r.parent.sessionManager.getSessionId() === parent.sessionManager.getSessionId()) r.controller.abort(); };
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    try {
    while ([...this.active.values()].some(r => r.parent.sessionManager.getSessionId() === parent.sessionManager.getSessionId())) {
      await Promise.all([...this.active.values()].filter(r => r.parent.sessionManager.getSessionId() === parent.sessionManager.getSessionId()).map(async r => { await r.ready; return r.result; }));
    }
    } finally { signal?.removeEventListener('abort', abort); }
  }
  async dispose() {
    for (const record of this.active.values()) record.controller.abort();
    await Promise.all([...this.active.values()].map(async r => { await r.ready; await r.child?.dispose(); await r.result; }));
  }
}

export const spawnProvider = { name: 'spawn', capabilities: { agentOptions: true, outputSchema: true, depthLimit: true, agentPreset: false },
  inheritsParentContext: false,
  start({ cli, entry, cwd, env, onEvent }) { return new ChildRPC(cli, ['--session', entry.sessionFile], { cwd, env, onEvent }); },
};
