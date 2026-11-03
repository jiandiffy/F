import { result, objectSchema, stringSchema } from '../core/kernel.mjs';
import { VersionProject } from './project.mjs';
import { command } from '../datasets/providers.mjs';

export async function mountVersions(ctx) {
  await ctx.plugin({ name: 'f-versions', inject: ['host','tools','systemPrompt'], apply(ctx) {
    ctx.tools.register({ name: 'project_version', label: 'Project versions',
      capability: { name: 'versions', description: 'Task branches and isolated worktrees, scoped commits, tested merges and explicit GitHub publication.' },
      description: 'Inspect project versions (disabled until the user opens Versions), create scoped child worktrees, commit only assigned paths, merge after real tests, or complete a task after an actual validation command. complete records a fixed tested major; simple tasks stay linear, complex tasks retain fixed agent derivations. Never enables projects. GitHub publication is exclusively a separate explicit user action in the Versions UI.',
      parameters: objectSchema({ action: { type: 'string', enum: ['status','branch','commit','merge','complete'] },
        node: stringSchema, parent: stringSchema, label: stringSchema, message: stringSchema, summary: stringSchema,
        complexity: { type: 'string', enum: ['simple','complex'] },
        paths: { type: 'array', items: stringSchema }, test: { type: 'array', items: stringSchema },
      }, ['action']),
      async execute(_id, input, signal, _update, context) {
        if (!['status','branch','commit','merge','complete'].includes(input.action)) throw new Error('Agent cannot enable projects or publish to GitHub; use the Versions UI');
        if (process.env.F_REMOTE_PROJECT) throw new Error('Version plugin currently operates local folders; use the authenticated remote Git tools for this SSH project');
        if (signal?.aborted) throw new Error('Version operation cancelled');
        const project = new VersionProject(context.cwd, { runner: (file, args, options) => command(file, args, { ...options, signal }) });
        return result(await project[input.action]({ ...input, signal }));
      },
    });
    ctx.systemPrompt.register('versions', () => 'Version policy: projects are disabled until the user first opens Versions; never enable one yourself. For enabled simple tasks use complete with explicit owned paths and a real test argv to record one immutable linear major. Complex tasks use scoped isolated child worktrees, commit only owned paths, and test both child and merged results; their fixed agent derivations remain visible. goal_flow independent passed code tests also record a major automatically. Failures/cancellation must not record success or discard pending changes. GitHub publication requires a separate explicit user authorization in Versions and exports only private major snapshots, never development ancestry.');
  }});
}
