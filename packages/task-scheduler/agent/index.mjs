import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { atomicJSON, applicationData, withLock } from '../../data-base/agent/store.mjs';
import { command } from '../../data-base/agent/providers.mjs';
import { result, objectSchema, stringSchema } from '../../../runtime/harness/src/core/kernel.mjs';

export class TaskScheduler {
  constructor(directory = process.env.F_TASK_DIRECTORY ?? path.join(applicationData(), 'applications/task-scheduler'), { run = command, now = Date.now } = {}) {
    this.file = path.join(directory, 'tasks.json'); this.run = run; this.now = now; this.active = new Map(); this.stopped = false;
  }
  async transaction(change) {
    return withLock(this.file + '.lock', async () => {
      let tasks;
      try { tasks = JSON.parse(await readFile(this.file, 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; tasks = []; }
      if (!Array.isArray(tasks)) throw Error('Invalid task database; existing data was preserved');
      const before = JSON.stringify(tasks), value = await change(tasks);
      if (JSON.stringify(tasks) !== before) await atomicJSON(this.file, tasks);
      return value;
    });
  }
  async add({ title, at, everyMs, argv, cwd }) {
    if (!title?.trim() || !Number.isFinite(Date.parse(at)) || !Array.isArray(argv) || !argv.length || argv.some(s => typeof s !== 'string' || s.includes('\0')) || !path.isAbsolute(cwd) || (everyMs !== undefined && (!Number.isSafeInteger(everyMs) || everyMs < 1000))) throw Error('Task needs a title, ISO time, argv, absolute cwd, and optional interval >= 1000 ms');
    const task = { id: randomUUID(), title, at, everyMs, argv, cwd, status: 'scheduled' };
    await this.transaction(tasks => { tasks.push(task); }); return task;
  }
  list() { return this.transaction(tasks => structuredClone(tasks)); }
  async cancel(id) {
    const value = await this.transaction(tasks => { const task = tasks.find(t => t.id === id); if (!task) throw Error('Unknown task'); task.status = 'cancelled'; return { ...task }; });
    this.active.get(id)?.abort(); return value;
  }
  async tick() {
    if (this.stopped) return;
    const due = await this.transaction(tasks => {
      for (const task of tasks.filter(t => t.status === 'running' && t.ownerPID)) {
        try { process.kill(task.ownerPID, 0); }
        catch (error) { if (error.code !== 'ESRCH') throw error; task.status = 'interrupted'; task.error = 'Previous F process exited; command was not replayed'; }
      }
      const due = tasks.filter(t => t.status === 'scheduled' && Date.parse(t.at) <= this.now()).slice(0, 4);
      for (const task of due) { task.status = 'running'; task.ownerPID = process.pid; task.startedAt = new Date(this.now()).toISOString(); }
      return structuredClone(due);
    });
    await Promise.all(due.map(async task => {
      const controller = new AbortController(); this.active.set(task.id, controller);
      let output = '', error;
      try {
        const current = await this.transaction(tasks => tasks.find(t => t.id === task.id).status);
        if (this.stopped || current === 'cancelled') controller.abort();
        controller.signal.throwIfAborted();
        output = await this.run(task.argv[0], task.argv.slice(1), { cwd: task.cwd, signal: controller.signal, timeout: 300000 });
      }
      catch (failure) { error = failure.message; }
      finally { this.active.delete(task.id); }
      await this.transaction(tasks => {
        const current = tasks.find(t => t.id === task.id);
        if (current.status === 'cancelled') return;
        current.output = String(output).slice(-12000); current.error = error; current.finishedAt = new Date(this.now()).toISOString();
        current.status = error ? 'failed' : task.everyMs ? 'scheduled' : 'completed';
        if (!error && task.everyMs) current.at = new Date(this.now() + task.everyMs).toISOString();
      });
    }));
  }
  async stop() { this.stopped = true; for (const controller of this.active.values()) controller.abort(); }
}

export async function mountTaskScheduler(ctx, options = {}) {
  await ctx.plugin({ name: 'f-task-scheduler', inject: ['tools', 'systemPrompt'], apply(scope) {
    const scheduler = new TaskScheduler(options.directory, options); let running, closed = false;
    scope.provide('taskScheduler', scheduler);
    scope.effect(() => {
      const timer = setInterval(() => {
        if (running || closed) return;
        running = scheduler.tick().catch(error => { scope.logger?.warn?.(error.message); }).finally(() => { running = null; });
      }, 1000); timer.unref();
      return async () => { closed = true; clearInterval(timer); await scheduler.stop(); await running; };
    });
    scope.tools.register({ name: 'task_scheduler', label: '定时任务', capability: { name: 'task-scheduler', description: '保存、执行、查询和取消本机定时命令。应用关闭期间不执行。' },
      description: 'Schedule a user-requested local command with argv, an ISO at timestamp and optional everyMs. Tasks execute while F is running. A failed or interrupted command is never automatically replayed. list and cancel retain history.',
      parameters: objectSchema({ action: { type: 'string', enum: ['list', 'add', 'cancel'] }, title: stringSchema, at: stringSchema, everyMs: { type: 'integer', minimum: 1000 }, argv: { type: 'array', items: stringSchema }, id: stringSchema }, ['action']),
      async execute(_id, args, _signal, _update, context) {
        return result(args.action === 'list' ? await scheduler.list() : args.action === 'cancel' ? await scheduler.cancel(args.id) : await scheduler.add({ ...args, cwd: context.cwd }));
      } });
  } });
}
