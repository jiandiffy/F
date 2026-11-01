import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { lstat, readFile, realpath, mkdtemp, rm } from 'node:fs/promises';
import { assertObjectJsonSchema, validateJsonSchemaValue } from '../../dist/upstream.mjs';

const validID = id => typeof id === 'string' && /^[a-z][a-z0-9-]{0,47}$/.test(id);
const inside = (file, root) => file.startsWith(root + path.sep);
const clone = value => {
  if (value === undefined) return undefined;
  const errors = validateJsonSchemaValue({}, value);
  if (errors.length) throw new Error('Plugin state must be lossless JSON: ' + errors.join('; '));
  const json = JSON.stringify(value);
  if (Buffer.byteLength(json) > 1024 * 1024) throw new Error('Plugin state/report exceeds 1 MB');
  return JSON.parse(json);
};

/** Opt-in, single-file Agent plugins only. Not native Swift/dylib replacement.
 * Trusted local code has the same OS permissions as Pi; this is a lifecycle API,
 * not an isolation boundary. No watchers, downloaded code or automatic discovery.
 */
export class PluginHmr {
  records = new Map();
  changing = false;
  closed = false;
  constructor(ctx, { record = () => {} } = {}) {
    this.ctx = ctx;
    this.instanceID = randomUUID();
    this.record = record;
  }
  status() {
    return [...this.records.values()].map(entry => ({ id: entry.id, sha256: entry.sha256,
      path: entry.path, state: entry.accepted ? 'active' : 'disabled', phase: entry.phase, activeCalls: entry.active,
      tests: clone(entry.tests ?? []), tools: [...entry.tools.keys()], acceptanceDirectory: entry.scratch }));
  }
  assertIdle(context) {
    if (this.closed) throw new Error('HMR runtime is closed');
    if (context?.isIdle?.() !== true) throw new Error('HMR requires an idle conversation; finish tools and queued work first');
    if (this.changing) throw new Error('Another HMR transaction is in progress');
    if ([...this.records.values()].some(entry => entry.active)) throw new Error('Plugin work is still running; HMR will not force-stop it');
  }
  async load(id, file, sha256, context) {
    this.assertIdle(context);
    if (!validID(id) || !/^[a-f0-9]{64}$/.test(sha256)) throw new Error('Expected plugin id and lowercase SHA256');
    if (process.env.F_REMOTE_PROJECT) throw new Error('HMR only loads explicitly reviewed local Agent plugins');
    this.changing = true;
    let old, candidate, state, stopped = false;
    try {
      const project = await realpath(context.cwd);
      const allowed = path.join(project, '.f/plugins', id);
      const absolute = path.resolve(project, file);
      const resolved = await realpath(absolute);
      const stat = await lstat(absolute);
      if (!inside(resolved, allowed) || !stat.isFile() || stat.nlink !== 1 || path.extname(resolved) !== '.mjs')
        throw new Error('HMR expects a regular, unlinked .mjs file under <project>/.f/plugins/<id>/');
      if (stat.size > 1024 * 1024) throw new Error('HMR bundle exceeds 1 MB');
      const bytes = await readFile(absolute);
      if (bytes.length > 1024 * 1024) throw new Error('HMR bundle exceeds 1 MB');
      if (createHash('sha256').update(bytes).digest('hex') !== sha256) throw new Error('HMR SHA256 mismatch; review and hash the exact candidate');
      const source = bytes.toString('utf8');
      // Conservative bundle contract, not a JS security parser. Dependency-free
      // modules avoid pretending cache-busting one entry reloads its import graph.
      if (/\bimport\b|\brequire\s*\(|\bexport\s*(?:\*|\{)[\s\S]*?\bfrom\b/.test(source))
        throw new Error('HMR v1 requires a self-contained bundle without imports/requires/re-exports');
      old = this.records.get(id);
      if (old?.accepted && old.sha256 === sha256) return { id, sha256, state: 'unchanged', tests: clone(old.tests) };
      // Evaluate the verified bytes, not a mutable file. The content-addressed URL
      // bypasses path-based ESM caching without touching the signed application.
      const definition = (await import('data:text/javascript;base64,' + bytes.toString('base64') + '#' + this.instanceID)).default;
      if (!definition || definition.apiVersion !== 1 || definition.id !== id || typeof definition.apply !== 'function' || typeof definition.test !== 'function')
        throw new Error('Plugin must export { apiVersion: 1, id, apply(api, state), test(testApi) }');
      if (old && !old.accepted) throw new Error('Previous cleanup failed; restart the Agent before replacing this plugin');
      if (old?.active) throw new Error('Plugin started work during candidate validation');
      if (context.isIdle() !== true) throw new Error('Conversation became busy during candidate validation');
      if (old) {
        state = clone(await old.definition.snapshot?.());
        await this.stop(old);
        stopped = true;
      }
      candidate = this.entry(id, absolute, sha256, definition);
      this.records.set(id, candidate);
      await this.start(candidate, clone(state));
      candidate.tests = await this.test(candidate);
      if (this.closed) throw new Error('HMR runtime was disposed during acceptance');
      if (candidate.active) throw new Error('Candidate started work before acceptance committed');
      candidate.phase = 'active';
      this.activate(candidate);
      this.record('f-plugin-hmr', { id, sha256, state: 'accepted', tests: clone(candidate.tests), timestamp: Date.now() });
      candidate.accepted = true;
      return { id, sha256, state: 'accepted', tests: clone(candidate.tests) };
    } catch (error) {
      const failures = [error.message];
      if (candidate) {
        try { await this.stop(candidate); } catch (cleanup) {
          candidate.quarantined = true;
          candidate.accepted = false;
          this.withdraw(candidate);
          failures.push('candidate cleanup: ' + cleanup.message);
        }
      }
      if (!this.closed && old && stopped && !candidate?.quarantined) {
        let restored;
        try {
          restored = this.entry(old.id, old.path, old.sha256, old.definition);
          this.records.set(id, restored);
          await this.start(restored, clone(state));
          restored.tests = old.tests;
          restored.phase = 'active';
          this.activate(restored);
          restored.accepted = true;
        } catch (rollback) {
          failures.push('rollback failed: ' + rollback.message);
          try { if (restored) await this.stop(restored); } catch (cleanup) { failures.push('rollback cleanup: ' + cleanup.message); }
        }
      } else if (candidate && !candidate.quarantined) this.records.delete(id);
      try { this.record('f-plugin-hmr', { id, sha256, state: 'rejected', error: failures.join('; '), timestamp: Date.now() }); } catch {}
      throw new Error(failures.join('; '));
    } finally { this.changing = false; }
  }
  entry(id, file, sha256, definition) {
    return { id, path: file, sha256, definition, fiber: undefined, accepted: false, phase: 'mounting', active: 0,
      tools: new Map(), cleanupError: undefined, tests: [] };
  }
  async start(entry, state) {
    let applied = false;
    const fiber = this.ctx.plugin({ name: 'hmr-' + entry.id, inject: ['host', 'tools', 'systemPrompt'], apply: async scope => {
      const prefix = 'hmr_' + entry.id.replaceAll('-', '_') + '_';
      const run = async callback => {
        if (this.closed || !['mounting', 'testing', 'active'].includes(entry.phase)) throw new Error('Plugin is stopping or not accepting new work');
        entry.active++;
        try { return await callback(); } finally { entry.active--; }
      };
      const api = Object.freeze({
        id: entry.id,
        tools: Object.freeze({ register: definition => {
          if (typeof definition.name !== 'string' || !definition.name.startsWith(prefix) || definition.name.length <= prefix.length || definition.name.length > 64 || !/^[a-z][a-z0-9_]*$/.test(definition.name) || typeof definition.execute !== 'function')
            throw new Error('Tool names must start with ' + prefix + ', include a suffix, and fit in 64 characters');
          assertObjectJsonSchema(definition.parameters);
          definition = Object.freeze({ ...definition, parameters: clone(definition.parameters) });
          if (entry.tools.has(definition.name)) throw new Error('Duplicate plugin tool: ' + definition.name);
          scope.tools.register({ ...definition, execute: (...args) => {
            if (!entry.accepted || this.changing) throw new Error('Plugin is being replaced or has not passed acceptance');
            return run(() => definition.execute(...args));
          }});
          entry.tools.set(definition.name, definition);
          // Pi tools cannot be unregistered. Explicit hidden exposure also
          // withdraws nested/deferred access instead of merely deactivating it.
          scope.effect(() => () => this.hideTool(definition, entry.id));
        }}),
        prompts: Object.freeze({ register: (name, render) => {
          if (typeof name !== 'string' || !/^[a-z][a-z0-9_-]*$/.test(name) || typeof render !== 'function') throw new Error('Invalid prompt registration');
          scope.systemPrompt.register('hmr-' + entry.id + '-' + name, (...args) => entry.accepted ? run(() => render(...args)) : '');
        }}),
        on: (event, handler) => {
          if (!['message_start', 'message_end', 'tool_execution_end', 'agent_settled'].includes(event) || typeof handler !== 'function') throw new Error('Unsupported HMR notification');
          return scope.host.on(scope, event, (...args) => entry.accepted ? run(() => handler(...args)) : undefined);
        },
        effect: setup => scope.effect(() => {
          const cleanup = setup();
          if (typeof cleanup !== 'function') throw new Error('HMR effect must return a cleanup function');
          return async () => {
            try { await cleanup(); } catch (error) { entry.cleanupError = error; throw error; }
          };
        }),
        provide: (name, value) => {
          if (!/^[a-z][a-z0-9_-]*$/.test(name)) throw new Error('Invalid service key');
          scope.provide('hmr.' + entry.id + '.' + name, value);
        },
        get: name => scope.get('hmr.' + entry.id + '.' + name),
        track: callback => run(callback),
      });
      await entry.definition.apply(api, state);
      entry.phase = 'staged';
      applied = true;
    }});
    entry.fiber = fiber;
    await fiber;
    if (!applied) throw new Error('Plugin dependencies are unavailable');
  }
  hideTool(definition, id) {
    this.ctx.host.pi.registerTool({ ...definition, exposure: 'hidden',
      execute() { throw new Error('Plugin is unloaded: ' + id); } });
  }
  withdraw(entry) {
    for (const definition of entry.tools.values()) this.hideTool(definition, entry.id);
  }
  activate(entry) {
    this.ctx.host.pi.setActiveTools([...new Set([...this.ctx.host.pi.getActiveTools(), ...entry.tools.keys()])]);
    const active = new Set(this.ctx.host.pi.getActiveTools());
    const blocked = [...entry.tools.keys()].filter(name => !active.has(name));
    if (blocked.length) throw new Error('Host tool allowlist excludes HMR tools: ' + blocked.join(', ') + '; explicitly authorize them before loading');
  }
  async test(entry) {
    const scratch = await mkdtemp(path.join(os.tmpdir(), 'f-plugin-hmr-'));
    const succeeded = new Set();
    const controller = new AbortController();
    let assertions = 0;
    let assertionFailure;
    entry.phase = 'testing';
    try {
      const tests = await entry.definition.test(Object.freeze({
        cwd: scratch,
        assert(condition, message) {
          assertions++;
          try { assert.ok(condition, message); }
          catch (error) { assertionFailure ??= error; throw error; }
        },
        invoke: async (name, args) => {
          if (entry.phase !== 'testing') throw new Error('Acceptance invocation is closed');
          const tool = entry.tools.get(name);
          if (!tool) throw new Error('Acceptance can only invoke this candidate\'s own tools');
          const errors = validateJsonSchemaValue(tool.parameters, args);
          if (errors.length) throw new Error(errors.join('; '));
          entry.active++;
          try {
            const value = await tool.execute('hmr-acceptance', args, controller.signal, () => {}, { cwd: scratch, signal: controller.signal });
            if (!value || !Array.isArray(value.content) || value.isError) throw new Error('Candidate tool returned an invalid/failed result');
            succeeded.add(name);
            return value;
          } finally { entry.active--; }
        },
      }));
      if (assertionFailure) throw new Error('Acceptance assertion failed: ' + assertionFailure.message);
      if (!assertions || !Array.isArray(tests) || !tests.length || tests.some(test => !test || typeof test.name !== 'string' || !test.name.trim() || test.passed !== true))
        throw new Error('Acceptance must assert real behavior and return non-empty [{ name, passed: true }]');
      if ([...entry.tools.keys()].some(name => !succeeded.has(name))) throw new Error('Acceptance did not successfully exercise every candidate tool');
      if (entry.active) throw new Error('Acceptance left plugin work running');
      return tests.map(test => ({ name: test.name, passed: true }));
    } finally {
      entry.phase = 'staged';
      controller.abort();
      // Never remove a fixture while a badly behaved acceptance still uses it.
      // Keep it quarantined until the tracked work finishes and unload succeeds.
      if (entry.active) entry.scratch = scratch;
      else await rm(scratch, { recursive: true, force: true });
    }
  }
  async stop(entry) {
    if (entry.active) throw new Error('Plugin work is still running; refusing unload');
    entry.phase = 'stopping';
    entry.accepted = false;
    this.withdraw(entry);
    await entry.fiber?.dispose();
    entry.phase = 'stopped';
    if (entry.active) throw new Error('Plugin still has work after cleanup; refusing replacement');
    if (entry.cleanupError) throw new Error('Plugin cleanup failed: ' + entry.cleanupError.message);
    if (entry.scratch) {
      await rm(entry.scratch, { recursive: true, force: true });
      entry.scratch = undefined;
    }
  }
  async unload(id, context) {
    this.assertIdle(context);
    if (!validID(id) || !this.records.has(id)) throw new Error('Unknown HMR plugin');
    this.changing = true;
    try {
      await this.stop(this.records.get(id));
      this.records.delete(id);
      this.record('f-plugin-hmr', { id, state: 'unloaded', timestamp: Date.now() });
      return { id, state: 'unloaded' };
    } finally { this.changing = false; }
  }
  async dispose() {
    this.closed = true;
    for (const entry of this.records.values()) await this.stop(entry);
    this.records.clear();
  }
}

export async function mountPluginHmr(ctx) {
  await ctx.plugin({ name: 'f-plugin-hmr', inject: ['host', 'tools', 'systemPrompt'], apply(scope) {
    const pi = scope.host.pi;
    const manager = new PluginHmr(scope, { record: (type, value) => pi.appendEntry(type, value) });
    scope.provide('pluginHmr', manager);
    scope.effect(() => () => manager.dispose());
    if (typeof pi.registerCommand !== 'function') return; // Minimal non-Pi test hosts.
    pi.registerCommand('hmr', { description: 'Agent plugin HMR: status | load <id> <sha256> <path> | unload <id>. Trusted local single-file bundles only.',
      async handler(args, context) {
        try {
          let result;
          if (args.trim() === 'status' || !args.trim()) result = manager.status();
          else if (/^unload\s+[a-z][a-z0-9-]*\s*$/.test(args)) result = await manager.unload(args.trim().split(/\s+/)[1], context);
          else {
            const match = /^load\s+([a-z][a-z0-9-]*)\s+([a-f0-9]{64})\s+(.+)$/.exec(args.trim());
            if (!match) throw new Error('Usage: /hmr status | /hmr load <id> <sha256> <path> | /hmr unload <id>');
            result = await manager.load(match[1], match[3], match[2], context);
          }
          context.ui.notify('Agent HMR: ' + JSON.stringify(result), 'info');
        } catch (error) { context.ui.notify('Agent HMR rejected: ' + error.message, 'error'); }
      },
    });
  }});
}
