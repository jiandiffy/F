import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createKernel } from './core/kernel.mjs';
import { mountPluginHmr } from './core/plugin-hmr.mjs';
import { mountSkills } from './skills/index.mjs';
import { mountSubagents } from './subagent/index.mjs';
import { mountWorkflow } from './workflow/index.mjs';
import { mountAIOS } from './aios/index.mjs';
import { mountDatasets } from './datasets/index.mjs';
import { mountVersions } from './versions/index.mjs';

export async function startHarness(pi, { adapters = [], root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..'), dataRoot, remoteFileSystem } = {}) {
  const ctx = createKernel(pi);
  const directory = dataRoot ?? path.join(process.env.F_CONVERSATION_DIR ?? process.env.F_BOARD_DIR ?? path.join(process.env.HOME, 'Library/Application Support/F'), 'harness/subagents');
  if (remoteFileSystem) ctx.provide('fs', remoteFileSystem);
  const disabled = new Set((process.env.F_DISABLED_PLUGINS ?? '').split(','));
  await mountSkills(ctx, { root, enabled: !disabled.has('skills') });
  if (!disabled.has('subagent')) await mountSubagents(ctx, { cli: path.join(root, 'pi/bin/pi'), dataRoot: directory, maxDepth: 1, maxConcurrentAgents: 4,
    deliverMessage(parent, childId, text) {
      if (pi.getHarnessSessionId() !== parent.sessionManager.getSessionId()) return;
      pi.sendMessage({ customType: 'agent-message', display: true, content: text, details: { senderSessionId: childId, source: 'agent-message' } }, { triggerTurn: true, deliverAs: 'steer' });
    },
    deliver(parent, childId, value) {
      // The exact spawning session owns completion; no callback can write into a switched session.
      if (pi.getHarnessSessionId() !== parent.sessionManager.getSessionId()) return;
      pi.sendMessage({ customType: 'subagent-result', display: true,
        content: JSON.stringify({ childId, ...value }), details: { childId, source: 'subagent-settled' } }, { triggerTurn: true, deliverAs: 'followUp' });
    },
  });
  if (!disabled.has('workflow') && !disabled.has('subagent')) await mountWorkflow(ctx);
  for (const [name, apply] of adapters) await ctx.plugin({ name, inject: ['host','tools'], apply(ctx) { return apply(ctx.host.adapter(ctx)); } });
  if (!disabled.has('datasets')) await mountDatasets(ctx, { root });
  if (!disabled.has('versions')) await mountVersions(ctx);
  await mountAIOS(ctx, { root, enabled: !disabled.has('aios'), dataRoot: dataRoot && path.join(dataRoot, '../bus') });
  await mountPluginHmr(ctx);
  let sessionId;
  pi.getHarnessSessionId = () => sessionId;
  ctx.host.on(ctx, 'session_start', (_event, context) => { sessionId = context.sessionManager.getSessionId(); });
  ctx.host.on(ctx, 'before_agent_start', async (event, context) => {
    sessionId = context.sessionManager.getSessionId();
    return { systemPrompt: await ctx.systemPrompt.assemble(event, context) };
  });
  ctx.host.on(ctx, 'session_shutdown', async () => { await ctx.fiber.dispose(); });
  return ctx;
}
