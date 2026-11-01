import { result, objectSchema, stringSchema } from '../core/kernel.mjs';
import { VersionProject } from './project.mjs';
import { command } from '../datasets/providers.mjs';

export async function mountVersions(ctx) {
  await ctx.plugin({ name: 'f-versions', inject: ['host','tools','systemPrompt'], apply(ctx) {
    ctx.tools.register({ name: 'project_version', label: 'Project versions',
      capability: { name: 'versions', description: 'Task branches and isolated worktrees, scoped commits, tested merges and explicit GitHub publication.' },
      description: 'Enable an independent Git repository in this project folder, inspect its version tree, create a scoped child worktree, commit only assigned paths, or merge after a real test command. Never uses a parent repository. GitHub publish is only available through the user-facing Versions plugin. For SSH projects use remote Git tools instead.',
      parameters: objectSchema({ action: { type: 'string', enum: ['enable','status','branch','commit','merge'] },
        node: stringSchema, parent: stringSchema, label: stringSchema, message: stringSchema,
        paths: { type: 'array', items: stringSchema }, test: { type: 'array', items: stringSchema },
      }, ['action']),
      async execute(_id, input, signal, _update, context) {
        if (process.env.F_REMOTE_PROJECT) throw new Error('Version plugin currently operates local folders; use the authenticated remote Git tools for this SSH project');
        if (signal?.aborted) throw new Error('Version operation cancelled');
        const project = new VersionProject(context.cwd, { runner: (file, args, options) => command(file, args, { ...options, signal }) });
        return result(await project[input.action](input));
      },
    });
    ctx.systemPrompt.register('versions', () => 'Version plugin: when the user enables project version management, give agents isolated child worktrees and explicit file scopes. Commit only owned paths. Merge into the parent only after running a real validation command on both the child and merged result. Failed merges stay pending for repair; never discard changes. Publication is a user action in the Versions plugin.');
  }});
}
