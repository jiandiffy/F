import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { realpathSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { result, objectSchema, stringSchema } from '../core/kernel.mjs';

const lockScript = fileURLToPath(new URL('./maintenance_lock.py', import.meta.url));
const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
const within = (p, root) => p === root || p.startsWith(root + path.sep);
const canonical = p => {
  try { return realpathSync(p); }
  catch (e) { if (e.code !== 'ENOENT') throw e; return path.join(canonical(path.dirname(p)), path.basename(p)); }
};

// Compatibility entry points only identify the source; edits still require canonical paths.
export function maintenanceSourceContext(root, cwd) {
  root = canonical(root); cwd = canonical(cwd);
  return within(cwd, root) || [['gui-mac','ui/desktop'], ['pi','runtime/pi'], ['F_MAINTENANCE.md','F_MAINTENANCE.md']].every(([old, name]) => canonical(path.join(cwd, old)) === canonical(path.join(root, name)));
}

// Private event identity plus the exact transformed command prevents a model input
// field (or an intervening command change) from pretending a shell is protected.
const guardedShells = new WeakMap();
export function maintenanceShellGuard(event) {
  const guard = guardedShells.get(event);
  return guard?.command === event.input.command ? guard : undefined;
}
export function extendMaintenanceShell(event, additionalRules) {
  const guard = maintenanceShellGuard(event);
  if (!guard) return false;
  if (guard.mode !== 'sandbox') return true; // Exact publisher or genuinely read-only fallback.
  guard.rules += additionalRules;
  event.input.command = guardedBash(guard.original, guard.root, { allowPublish: false, additionalRules: guard.rules });
  guard.command = event.input.command;
  return true;
}

export function coordinate(root, owner, action, args = {}) {
  try {
    return JSON.parse(execFileSync('/usr/bin/python3', ['-B', lockScript, root, owner, action, JSON.stringify(args)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
  } catch (error) { throw new Error(String(error.stderr || error.message).trim()); }
}

// Only a single literal prepare-update invocation may escape the read-only shell.
// No shell expansions, extra commands, environment assignments or interpreter flags.
export function publicationCommand(command, root) {
  const script = path.join(root, 'ui/desktop/scripts/prepare-update.py');
  const match = /^(?:python3|\/usr\/bin\/python3) (\S+) --announcement '([^'\n]*)'( --no-whiteboard)?$/.exec(command.trim());
  if (!match || path.resolve(root, match[1]) !== script) return undefined;
  return `/usr/bin/python3 -B ${quote(script)} --announcement ${quote(match[2])}${match[3] ?? ''}`;
}

let sandboxAvailable;
export function hasSandbox() {
  if (sandboxAvailable === undefined) {
    try {
      execFileSync('/usr/bin/sandbox-exec', ['-p', '(version 1)(allow default)', '/usr/bin/true'], { stdio: 'ignore' });
      sandboxAvailable = true;
    } catch { sandboxAvailable = false; }
  }
  return sandboxAvailable;
}

export function guardedBash(command, root, { sandbox = hasSandbox(), home = os.homedir(), allowPublish = true, additionalRules = '' } = {}) {
  const publish = allowPublish && publicationCommand(command, root);
  if (publish) return publish; // Python acquires publication lock + lease freeze before any build.
  if (!sandbox) {
    // Fail closed for arbitrary interpreters/scripts; retain genuinely read-only inspection.
    // Deliberately no shell operators/expansion, find -exec, rg --pre, git aliases, etc.
    const match = /^(pwd|ls|wc|stat)([ A-Za-z0-9_./,:=+@%~-]*)$/.exec(command.trim());
    if (!match) throw new Error('系统无法启用 sandbox-exec；仅允许 pwd/ls/wc/stat 简单只读命令，请使用 read、write/edit 和 maintenance_scope。');
    const binary = { pwd: '/bin/pwd', ls: '/bin/ls', wc: '/usr/bin/wc', stat: '/usr/bin/stat' }[match[1]];
    return binary + match[2];
  }
  const protectedPaths = [root, path.join(home, 'Library/Application Support/F/maintenance/coordination'),
    path.join(home, 'Library/Application Support/F/updates')].map(canonical);
  const profile = '(version 1)(allow default)' + protectedPaths.map(p => `(deny file-write* (subpath ${JSON.stringify(p)}))`).join('') + additionalRules;
  // -c, not -lc: no unsandboxed startup file is sourced by this inner shell.
  return `/usr/bin/sandbox-exec -p ${quote(profile)} /bin/bash --noprofile --norc -c ${quote(command)}`;
}

export async function mountMaintenance(ctx, { root, coordinator = coordinate }) {
  root = canonical(root);
  await ctx.plugin({ name: 'f-maintenance-coordination', inject: ['host', 'tools', 'systemPrompt'], apply(ctx) {
    const pins = new Map();
    const owners = new Set();
    let registered = false;
    const identity = context => Number(process.env.F_AGENT_DEPTH ?? 0) > 0 && process.env.F_AGENT_ID
      ? process.env.F_AGENT_ID : context.sessionManager.getSessionId();
    const inSource = context => !process.env.F_REMOTE_PROJECT && maintenanceSourceContext(root, context.cwd);
    const enroll = () => {
      if (registered) return;
      registered = true;
      ctx.tools.register({ name: 'maintenance_scope', label: 'Maintenance scope',
        description: 'F source maintenance: explicitly claim exclusive file/directory paths before write/edit, then re-read their latest contents before editing (never reuse pre-claim snapshots); disjoint plugin scopes may run in parallel. status, release, or delegate paths to an owned childId. No globs. Bash is source-read-only; publish runs only on the root session after all other leases release.',
        parameters: objectSchema({ action: { type: 'string', enum: ['claim', 'status', 'release', 'delegate'] },
          paths: { type: 'array', items: stringSchema }, childId: stringSchema }, ['action']),
        async execute(_id, args, _signal, _update, context) {
          if (!inSource(context)) throw new Error('maintenance_scope 仅用于本机 F 源码维护');
          const owner = identity(context);
          owners.add(owner);
          if (args.action === 'delegate') {
            if (!args.childId || !(await ctx.get('subagents')?.listChildren(context))?.some(child => child.childId === args.childId))
              throw new Error('只能转授给当前会话拥有的直接子代理');
          }
          const value = coordinator(root, owner, args.action, args);
          return result(value, JSON.stringify(value, null, 2) + (['claim', 'delegate'].includes(args.action)
            ? '\n获得范围后必须重新 read 最新源码，再编辑；禁止用拿锁前的缓存覆盖前一持有者的修改。' : ''));
        },
      });
    };
    ctx.host.on(ctx, 'before_agent_start', (_event, context) => { if (inSource(context)) enroll(); });
    ctx.systemPrompt.register('f-maintenance-scopes', (_event, context) => inSource(context)
      ? `\nF 源码规范路径为 ${root}；旧目录只用于定位，read/write/edit 必须使用规范路径，不能通过兼容符号链接编辑。\nF 源码编辑必须先用 maintenance_scope claim 明确文件/目录范围，并在获得租约后重新 read 最新文件，禁止用拿锁前缓存整文件覆盖前一持有者修改；不同插件范围可并行，同插件和相交范围拒绝。write/edit 实际调用受租约检查。bash 对源码强制只读（不支持沙箱时仅简单只读命令）；测试输出请放临时目录。向直属子代理 delegate 后父会话不能编辑转授范围，完成请 release。发布仅主会话使用单独 prepare-update.py 命令，需其他租约全部释放；不要删除他人租约或 pending。\n` : '');
    ctx.host.on(ctx, 'tool_call', (event, context) => {
      if (process.env.F_REMOTE_PROJECT) return;
      try {
        if (event.toolName === 'bash') {
          // Protect F even when a local session changes cwd or invokes an absolute path.
          const original = String(event.input.command ?? '');
          const allowPublish = inSource(context) && !process.env.F_UPDATE_DELEGATED && Number(process.env.F_AGENT_DEPTH ?? 0) === 0;
          event.input.command = guardedBash(original, root, { allowPublish });
          const mode = allowPublish && publicationCommand(original, root) ? 'publication' : hasSandbox() ? 'sandbox' : 'read-only';
          guardedShells.set(event, { root, original, command: event.input.command, mode, rules: '' });
          return;
        }
        if (!['write', 'edit'].includes(event.toolName)) return;
        const raw = event.input.path;
        if (typeof raw !== 'string') throw new Error('缺少编辑文件路径');
        const lexical = path.resolve(context.cwd, raw), resolved = canonical(lexical);
        const protectedPaths = ['maintenance/coordination', 'updates'].flatMap(p => {
          const original = path.join(os.homedir(), 'Library/Application Support/F', p);
          return [original, canonical(original)];
        });
        if (protectedPaths.some(p => within(resolved, p) || within(lexical, p)))
          throw new Error('禁止直接修改协调元数据或更新制品；请使用 maintenance_scope / prepare-update.py');
        // A hard link outside root can still alias protected source inodes.
        // Conservatively reject all local hard-linked regular-file mutations.
        const existing = statSync(resolved, { throwIfNoEntry: false });
        if (existing?.isFile() && existing.nlink > 1) throw new Error('维护工具不支持硬链接文件写入；请先确认文件归属');
        if (!within(lexical, root) && !within(resolved, root)) return;
        // Reject aliases rather than authorizing writes through a different tree.
        if (lexical !== resolved) throw new Error('维护编辑不支持符号链接路径');
        const owner = identity(context);
        owners.add(owner);
        const { token } = coordinator(root, owner, 'pin', { path: lexical, pid: process.pid });
        pins.set(event.toolCallId, { token, owner });
      } catch (error) { return { block: true, reason: error.message }; }
    });
    ctx.host.on(ctx, 'tool_execution_end', event => {
      const pin = pins.get(event.toolCallId);
      if (pin) { coordinator(root, pin.owner, 'unpin', pin); pins.delete(event.toolCallId); }
    });
    ctx.host.on(ctx, 'session_shutdown', () => {
      // Never steal child leases or erase an in-flight edit. A resumed session can release.
      for (const owner of owners) {
        try { coordinator(root, owner, 'release'); } catch { /* Persistent reservation is safer than forced cleanup. */ }
      }
    });
  }});
}
