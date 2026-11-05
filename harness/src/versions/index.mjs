import { result, objectSchema, stringSchema } from '../core/kernel.mjs';
import { VersionProject } from './project.mjs';
import { command } from '../datasets/providers.mjs';
import { workflowAccess } from '../workflow/ownership.mjs';
import { WorkflowProject } from './workflow.mjs';

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
        const access=await workflowAccess();
        if(access && input.action!=='status' && !access.canWrite)throw new Error('This workflow branch is closed or read-only; it cannot be changed outside an authorized experiment or simplification');
        if(access && input.action==='commit' && input.node!==access.candidate.node?.id)throw new Error('Commit only the assigned experimental node');
        if (process.env.F_WORKFLOW_ROLE && !['status','commit','merge'].includes(input.action)) throw new Error('Workflow branches are created only by the reviewed workflow; use workflow split for the one optional decomposition');
        if (['proposal','tester'].includes(process.env.F_WORKFLOW_ROLE) && input.action!=='status') throw new Error('Proposal and test agents cannot modify or commit version state');
        if (!['status','branch','commit','merge','complete'].includes(input.action)) throw new Error('Agent cannot enable projects or publish to GitHub; use the Versions UI');
        if (process.env.F_REMOTE_PROJECT) throw new Error('Version plugin currently operates local folders; use the authenticated remote Git tools for this SSH project');
        if (signal?.aborted) throw new Error('Version operation cancelled');
        const Project=access?WorkflowProject:VersionProject;
        const project = new Project(context.cwd, { signal, runner: (file, args, options) => command(file, args, { ...options, signal }) });
        if(access && input.action==='merge') {
          const child=access.candidate.children.find(c=>c.node?.id===input.node && c.phase==='candidate');
          if(process.env.F_WORKFLOW_ROLE!=='experiment' || !child || await project.git(['rev-parse','HEAD'],child.node.worktree)!==child.version.commit)throw new Error('Merge only an independently accepted direct grandchild at its fixed candidate commit');
        }
        return result(await project[input.action]({ ...input, signal }));
      },
    });
    ctx.systemPrompt.register('versions', () => 'Version policy: projects are disabled until the user first opens Versions; never enable one yourself. For enabled simple tasks use complete with explicit owned paths and a real test argv to record one immutable linear major. Complex tasks use scoped isolated child worktrees, commit only owned paths, and test both child and merged results; their fixed agent derivations remain visible. goal_flow independent passed code tests also record a major automatically. Failures/cancellation must not record success or discard pending changes. GitHub publication requires a separate explicit user authorization in Versions and exports only private major snapshots, never development ancestry.');
  }});
}
