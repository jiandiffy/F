import { readFile, writeFile, rename } from 'node:fs/promises';
import { SubagentManager, spawnProvider } from './manager.mjs';
import { ChildRPC } from './rpc.mjs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { result, objectSchema, stringSchema } from '../core/kernel.mjs';

export function snapshotParent(context) {
  const id = context.sessionManager.getSessionId(), file = context.sessionManager.getSessionFile();
  const branch = context.sessionManager.getBranch(), header = context.sessionManager.getHeader();
  return { cwd: context.cwd, executionCwd: process.env.F_REMOTE_PROJECT ? (process.env.F_LOCAL_PROJECT ?? process.cwd()) : context.cwd, model: context.model && { provider: context.model.provider, id: context.model.id }, thinkingLevel: context.thinkingLevel,
    sessionManager: { getSessionId: () => id, getSessionFile: () => file, getBranch: () => branch, getHeader: () => header } };
}

export async function mountSubagents(ctx, options) {
  await ctx.plugin({ name: 'f-subagents', inject: ['host', 'tools', 'systemPrompt'], apply(ctx) {
    const manager = new SubagentManager(ctx, options);
    manager.registerProvider(spawnProvider);
    manager.registerProvider({ ...spawnProvider, name: 'fork', inheritsParentContext: true,
      async start({ cli, entry, cwd, env, parent, onEvent }) {
        // Preserve the exact Pi completed-turn branch, including tool results and compactions.
        const exists = await readFile(entry.sessionFile).then(() => true, error => { if (error.code !== 'ENOENT') throw error; return false; });
        if (!exists) {
          const branch = parent.sessionManager.getBranch();
          const currentUser = branch.findLastIndex(e => e.type === 'message' && e.message.role === 'user');
          const prefix = currentUser < 0 ? branch : branch.slice(0, currentUser);
          await writeFile(entry.sessionFile, [JSON.stringify({ ...parent.sessionManager.getHeader(), id: entry.childId, cwd: env.F_REMOTE_PROJECT ? cwd : entry.cwd }),
            ...prefix.map(e => JSON.stringify(e))].join('\n') + '\n', { mode: 0o600, flag: 'wx' });
        }
        return new ChildRPC(cli, ['--session', entry.sessionFile], { cwd, env, onEvent });
      },
    });
    ctx.effect(() => () => manager.dispose());
    ctx.tools.register({ name: 'subagent', label: 'Subagent',
      description: 'Start an independent managed child and return its id. spawn starts fresh; fork inherits completed turns. Completion returns to this conversation. Use for focused delegation.',
      parameters: objectSchema({ prompt: stringSchema, label: stringSchema, provider: { type: 'string', enum: ['spawn','fork'] },
        cwd: stringSchema, model: stringSchema, model_provider: stringSchema, reasoning_effort: stringSchema,
        maxDepth: { type: 'integer', minimum: 0 }, outputSchema: { type: 'object', additionalProperties: true } }, ['prompt','label']),
      async execute(_id, args, signal, _update, context) {
        const parent = snapshotParent(context);
        const activation = await manager.startActivation({ provider: args.provider ?? 'spawn', label: args.label,
          request: { parent, prompt: [{ type: 'text', text: args.prompt }], cwd: args.cwd, outputSchema: args.outputSchema,
            maxDepth: args.maxDepth, agentOptions: { ...(args.model ? { model: args.model } : {}),
              ...(args.model_provider ? { provider: args.model_provider } : {}), ...(args.reasoning_effort ? { reasoningEffort: args.reasoning_effort } : {}) } }, signal, delivery: 'parent' });
        return result({ childId: activation.childId });
      },
    });
    ctx.tools.register({ name: 'list_agents', label: 'List agents', description: 'List this conversation’s durable direct children and their running/inactive state.',
      parameters: objectSchema({}), async execute(_id, _args, _signal, _update, context) { return result(await manager.listChildren(snapshotParent(context))); } });
    ctx.tools.register({ name: 'send_message', label: 'Message agent', description: 'Send guidance to an owned direct child, or resume its persisted session after completion.',
      parameters: objectSchema({ childId: stringSchema, message: stringSchema }),
      async execute(_id, args, signal, _update, context) {
        if (args.childId === 'parent' && process.env.F_AGENT_RELAY_DIR) {
          if (args.message.length > 64000) throw new Error('Agent message exceeds 64000 characters');
          const file = path.join(process.env.F_AGENT_RELAY_DIR, randomUUID());
          await writeFile(file + '.tmp', JSON.stringify({ text: args.message }), { mode: 0o600 });
          await rename(file + '.tmp', file + '.json');
          return result({ accepted: true, recipient: 'parent' });
        }
        const activation = await manager.sendMessage(snapshotParent(context), args.childId, args.message, signal);
        return result({ accepted: true, childId: activation?.childId ?? args.childId });
      } });
    ctx.tools.register({ name: 'interrupt_agent', label: 'Interrupt agent', description: 'Cancel this owned child activation and wait for its process and descendants to stop.',
      parameters: objectSchema({ childId: stringSchema }), async execute(_id, args, _signal, _update, context) {
        await manager.interrupt(snapshotParent(context), args.childId); return result({ interrupted: true });
      } });
    ctx.host.on(ctx, 'agent_before_settle', async (event, context) => {
      if (event.outcome === 'aborted') await manager.dispose();
      await manager.drain(snapshotParent(context), context.signal);
    });
    ctx.host.on(ctx, 'session_before_switch', async () => { await manager.dispose(); });
    ctx.systemPrompt.register('subagent', () => 'Use subagent for focused independent delegation. Results arrive as attributed completion messages. Use list_agents, send_message and interrupt_agent to manage your direct children. Children inherit the current model and execution world; default delegation depth is one. When your own work is done, end your response: the runtime waits for children before final settlement and delivers completion automatically; do not poll list_agents or sleep to wait. A child can send_message with childId=parent to relay an attributed message to its direct parent.');
  }});
}
