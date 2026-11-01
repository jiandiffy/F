import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { SkillRegistry, filesystemSkills, renderSkillContent } from '../../dist/upstream.mjs';
import { result, objectSchema, stringSchema } from '../core/kernel.mjs';
import { mountMaintenance } from './maintenance.mjs';

export async function mountSkills(ctx, { root, enabled = true }) {
  await mountMaintenance(ctx, { root });
  await ctx.plugin(SkillRegistry);
  const remote = process.env.F_REMOTE_PROJECT && JSON.parse(process.env.F_REMOTE_PROJECT);
  const cwdOf = context => remote?.cwd ?? context.cwd;
  await ctx.plugin(filesystemSkills, { bundledSkillDir: path.join(root, 'skills'), watch: !remote,
    ...(remote ? { dshHome: path.posix.join(remote.home ?? remote.cwd, '.dsh'), agentsHome: path.posix.join(remote.home ?? remote.cwd, '.agents') } : {}) });
  await ctx.plugin({ name: 'f-skill-refresh', inject: ['skills'], apply(ctx) {
    ctx.skills.registerProvider(control => {
      ctx.provide('refreshSkills', control.invalidate);
      return { name: 'f-invalidation', list: async () => [], get: async () => undefined };
    });
  }});
  await ctx.plugin({ name: 'f-tool-skill', inject: ['skills', 'tools', 'systemPrompt', 'host'], apply(ctx) {
    if (enabled) ctx.tools.register({ name: 'skill', label: 'Skill',
      description: 'Load a named skill from the current catalog before performing a matching task.',
      parameters: objectSchema({ name: stringSchema }),
      async execute(_id, { name }, signal, _update, context) {
        const skill = await ctx.skills.get(name, { cwd: cwdOf(context), signal });
        if (!skill || !skill.invocation.modelInvocable) throw new Error(`Skill is unavailable for model invocation: ${name}`);
        return result(skill, renderSkillContent(skill));
      },
    });
    if (enabled) ctx.host.on(ctx, 'before_agent_start', async (_event, context) => {
      if (!ctx.host.pi.getActiveTools().includes('skill')) return;
      ctx.refreshSkills();
      const snapshot = await ctx.skills.snapshot({ cwd: cwdOf(context) });
      const entries = snapshot.skills.filter(s => s.invocation.modelInvocable).map(s => ({ name: s.name, description: s.description.replace(/\s+/g,' ').slice(0,500) }));
      const prior = context.sessionManager.getBranch().findLast(e => e.type === 'custom_message' && e.customType === 'skill-catalog');
      if (prior && JSON.stringify(prior.details?.entries) === JSON.stringify(entries) && !prior.details?.incomplete && snapshot.complete) return;
      const escape = s => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
      return { message: { customType: 'skill-catalog', display: false, details: { entries, update: !!prior, incomplete: !snapshot.complete },
        content: 'Call skill before acting on a task that names or matches a listed skill.\n<available_skills>\n' + entries.map(s => `${s.name}: ${escape(s.description)}`).join('\n') + '\n</available_skills>' } };
    });
    if (enabled) ctx.host.on(ctx, 'input', async (event, context) => {
      if (event.source !== 'interactive' && event.source !== 'rpc') return;
      const match = /^\/([a-z0-9]+(?:-[a-z0-9]+)*)(?:\s|$)/.exec(event.text);
      if (!match) return;
      const skill = await ctx.skills.get(match[1], { cwd: cwdOf(context) });
      if (!skill?.invocation.userInvocable) return;
      return { action: 'transform', text: event.text + '\n\n' + renderSkillContent(skill) };
    });
    ctx.host.on(ctx, 'tool_result', event => {
      if (['write','edit','bash'].includes(event.toolName)) ctx.refreshSkills();
    });
    ctx.systemPrompt.register('f-maintenance', async (_event, context) => {
      if (process.env.F_REMOTE_PROJECT || !(context.cwd === root || context.cwd.startsWith(root + path.sep))) return '';
      // Essential self-update rules must be present even before the model chooses a skill.
      const skill = await ctx.skills.get('f-maintenance', { cwd: cwdOf(context) });
      return renderSkillContent(skill) + '\n\n' + await readFile(path.join(root, 'F_MAINTENANCE.md'), 'utf8');
    });
    ctx.host.on(ctx, 'tool_call', (event, context) => {
      if (!(context.cwd === root || context.cwd.startsWith(root + path.sep))) return;
      if (event.toolName !== 'bash' || process.env.F_REMOTE_PROJECT) return;
      const command = String(event.input.command ?? '');
      const pid = process.env.F_APP_PID;
      if (/build\.sh[^\n]*(--fresh|--relaunch)/.test(command) || /(?:killall|pkill)\s+(?:-\w+\s+)*(?:F|pi|node)(?:\s|$)/.test(command) ||
          (pid && new RegExp('\\bkill\\s+(?:-\\w+\\s+)*' + pid + '(?:\\s|$)').test(command)))
        return { block: true, reason: '使用 prepare-update.py 隔离构建、测试和延迟重启，不能终止 F 或当前 Agent。' };
    });
  }});
}
