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
import { mountGmail } from './gmail/index.mjs';
import { mountBrowser } from './browser/index.mjs';

export async function startHarness(pi, { adapters = [], root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..'), dataRoot, remoteFileSystem } = {}) {
  const ctx = createKernel(pi);
  const directory = dataRoot ?? path.join(process.env.F_CONVERSATION_DIR ?? process.env.F_BOARD_DIR ?? path.join(process.env.HOME, 'Library/Application Support/F'), 'harness/subagents');
  if (remoteFileSystem) ctx.provide('fs', remoteFileSystem);
  const disabled = new Set((process.env.F_DISABLED_PLUGINS ?? '').split(','));
  await mountSkills(ctx, { root, enabled: !disabled.has('skills') });
  if (!disabled.has('subagent')) await mountSubagents(ctx, { cli: path.join(root, 'pi/bin/pi'), dataRoot: directory, maxDepth: 2, maxConcurrentAgents: 4,
    sharedPlugins: () => (ctx.get('pluginHmr')?.status() ?? []).filter(p=>p.state==='active').map(({id,path,sha256})=>({id,path,sha256})),
    sharedCapabilities: () => (ctx.get('bus')?.catalog() ?? []).filter(c=>c.name!=='core' && c.tools.some(name=>ctx.get('bus').isActive(name))).map(c=>c.name),
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
  if (!disabled.has('datasets')) await mountDatasets(ctx, { root, directory:process.env.F_DATASET_DIRECTORY });
  if (!disabled.has('versions')) await mountVersions(ctx);
  if (!disabled.has('gmail')) await mountGmail(ctx);
  if (!disabled.has('browser')) await mountBrowser(ctx);
  await mountAIOS(ctx, { root, enabled: !disabled.has('aios'), dataRoot: dataRoot && path.join(dataRoot, '../bus') });
  await mountPluginHmr(ctx);
  if (Number(process.env.F_AGENT_DEPTH ?? 0)>0 && process.env.F_INHERITED_HMR) {
    const inherited=JSON.parse(process.env.F_INHERITED_HMR);
    if(!Array.isArray(inherited) || inherited.length>32)throw new Error('Invalid inherited mainline plugin catalog');
    ctx.host.on(ctx,'session_start',async(_event,context)=>{
      for(const plugin of inherited)await ctx.pluginHmr.load(plugin.id,plugin.path,plugin.sha256,{...context,cwd:process.env.F_SHARED_PROJECT,isIdle:()=>true});
    });
  }
  let sessionId;
  pi.getHarnessSessionId = () => sessionId;
  ctx.host.on(ctx, 'session_start', (_event, context) => { sessionId = context.sessionManager.getSessionId(); });
  let inheritedFor;
  ctx.host.on(ctx,'before_agent_start',async(_event,context)=>{
    if(Number(process.env.F_AGENT_DEPTH ?? 0)<=0 || !process.env.F_INHERITED_CAPABILITIES || inheritedFor===context.sessionManager.getSessionId())return;
    const names=JSON.parse(process.env.F_INHERITED_CAPABILITIES);
    if(!Array.isArray(names)||names.length>64||names.some(n=>typeof n!=='string'))throw new Error('Invalid inherited capability selection');
    if(names.length)await ctx.get('bus').choose(context,names,true);
    inheritedFor=context.sessionManager.getSessionId();
  });
  ctx.host.on(ctx, 'before_agent_start', async (event, context) => {
    sessionId = context.sessionManager.getSessionId();
    return { systemPrompt: await ctx.systemPrompt.assemble(event, context) };
  });
  ctx.host.on(ctx, 'session_shutdown', async () => { await ctx.fiber.dispose(); });
  return ctx;
}
