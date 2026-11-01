/** F's remote project tools. Model/session/whiteboard stay in F; file and shell tools use SSH only. */
import { spawn } from 'node:child_process';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import {
  createReadToolDefinition, createWriteToolDefinition, createEditToolDefinition,
  createBashToolDefinition, createLsToolDefinition, createFindToolDefinition,
  createGrepToolDefinition, type ExtensionAPI,
} from '@earendil-works/pi-coding-agent';

export interface RemoteDescriptor { arguments: string[]; cwd: string; endpoint: string; socket: string; home?: string }
export const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";

export function remoteTools(remote: RemoteDescriptor) {
  if (!path.posix.isAbsolute(remote.cwd) || !Array.isArray(remote.arguments) || remote.arguments.some(v => typeof v !== 'string')) throw new Error('Invalid F remote project');
  const absolute = (value = '.') => value === '~' ? (remote.home || remote.cwd) : value.startsWith('~/') ? path.posix.join(remote.home || remote.cwd, value.slice(2)) : path.posix.resolve(remote.cwd, value);
  const execute = (command: string, options: { input?: Buffer; signal?: AbortSignal; timeout?: number; onData?: (chunk: Buffer) => void; allowFailure?: boolean } = {}): Promise<{ data: Buffer; code: number }> => new Promise((resolve, reject) => {
    if (options.signal?.aborted) return reject(new Error('aborted'));
    const child = spawn('/usr/bin/ssh', [...remote.arguments, '/bin/sh -c ' + quote(command)], { stdio: ['pipe', 'pipe', 'pipe'] });
    const output: Buffer[] = [], errors: Buffer[] = [];
    let size = 0, timedOut = false;
    const stop = () => { child.kill('SIGTERM'); const kill = setTimeout(() => child.kill('SIGKILL'), 600); kill.unref(); };
    const timeout = setTimeout(() => { timedOut = true; stop(); }, (options.timeout || 30) * 1000);
    timeout.unref();
    const abort = () => stop();
    options.signal?.addEventListener('abort', abort, { once: true });
    child.stdout.on('data', (chunk: Buffer) => {
      options.onData?.(chunk);
      if (!options.onData) { size += chunk.length; if (size > 64 * 1024 * 1024) { stop(); } else output.push(chunk); }
    });
    child.stderr.on('data', (chunk: Buffer) => { options.onData?.(chunk); if (Buffer.concat(errors).length < 64000) errors.push(chunk); });
    child.stdin.on('error', () => {});
    child.stdin.end(options.input);
    child.on('error', error => { clearTimeout(timeout); options.signal?.removeEventListener('abort', abort); reject(error); });
    child.on('close', (code) => {
      clearTimeout(timeout); options.signal?.removeEventListener('abort', abort);
      if (options.signal?.aborted) reject(new Error('aborted'));
      else if (timedOut) reject(new Error('Remote command timed out'));
      else if (size > 64 * 1024 * 1024) reject(new Error('Remote output exceeds 64 MB'));
      else if (code !== 0 && !options.allowFailure) reject(new Error(Buffer.concat(errors).toString() || `SSH operation failed (${code})`));
      else resolve({ data: Buffer.concat(output), code: code ?? 255 });
    });
  });
  const run = async (command: string, signal?: AbortSignal, input?: Buffer) => (await execute(command, { signal, input })).data;
  const readFile = (file: string, signal?: AbortSignal) => run(`cat < ${quote(absolute(file))}`, signal);
  const writeFile = async (file: string, content: string, signal?: AbortSignal) => {
    const target = absolute(file);
    await run(`set -e; p=${quote(target)}; dir=\${p%/*}; [ -n "$dir" ] || dir=/; [ ! -L "$p" ] || { echo 'Edit the symlink target through its real path' >&2; exit 1; }; tmp=$(mktemp "$dir/.f-write.XXXXXX"); trap 'rm -f "$tmp"' EXIT HUP INT TERM; if [ -e "$p" ]; then cp -p "$p" "$tmp"; fi; cat > "$tmp"; mv -f "$tmp" "$p"; trap - EXIT HUP INT TERM`, signal, Buffer.from(content));
  };
  const shell = {
    exec: async (command: string, cwd: string, options: any) => {
      const pidFile = `/tmp/f-agent-${randomUUID()}.pid`;
      const body = `cd ${quote(absolute(cwd))} || exit; ${command}`;
      const childScript = `if command -v setsid >/dev/null 2>&1; then setsid /bin/sh -c ${quote(body)} & else /bin/sh -c ${quote(body)} & fi; p=$!; printf '%s' "$p" > ${quote(pidFile)}; trap 'kill -TERM -- -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; rm -f ${quote(pidFile)}' HUP INT TERM; wait "$p"; rc=$?; rm -f ${quote(pidFile)}; exit "$rc"`;
      let cancellation: Promise<unknown> | undefined;
      const cancel = () => {
        // Kill a dedicated process group when available; otherwise walk descendants, never the SSH master.
        const killScript = `p=$(cat ${quote(pidFile)} 2>/dev/null) || exit 0; case "$p" in ''|*[!0-9]*) exit 0;; esac; g=$(ps -o pgid= -p "$p" | tr -d ' '); if [ "$g" = "$p" ]; then kill -TERM -- -"$p" 2>/dev/null || :; else tree() { for c in $(ps -eo pid=,ppid= | awk -v p="$1" '$2 == p {print $1}'); do tree "$c"; done; kill -TERM "$1" 2>/dev/null || :; }; tree "$p"; fi; rm -f ${quote(pidFile)}`;
        cancellation ??= execute(killScript, { timeout: 5, allowFailure: true }).catch(error => { console.error('F: remote process cleanup failed:', error.message); });
        return cancellation;
      };
      const onAbort = () => { void cancel(); };
      options.signal?.addEventListener('abort', onAbort, { once: true });
      try {
        const result = await execute(childScript, { signal: options.signal, timeout: options.timeout || 120, onData: options.onData, allowFailure: true });
        return { exitCode: result.code };
      } catch (error) { await cancel(); throw error; }
      finally { options.signal?.removeEventListener('abort', onAbort); }
    },
  };
  const context = (ctx: any) => Object.defineProperty(Object.create(ctx || null), "cwd", { value: remote.cwd, enumerable: true });
  const wrap = (factory: (signal?: AbortSignal) => any) => {
    const definition = factory();
    return { ...definition, execute: (id: string, params: any, signal: AbortSignal, update: any, ctx: any) => {
      const input = params.path ? { ...params, path: absolute(params.path) } : params;
      return factory(signal).execute(id, input, signal, update, context(ctx));
    } };
  };
  const read = wrap(signal => createReadToolDefinition(remote.cwd, { operations: {
    readFile: p => readFile(p, signal), access: async p => { await run(`test -r ${quote(absolute(p))}`, signal); },
    detectImageMimeType: async p => {
      const bytes = await run(`head -c 16 ${quote(absolute(p))}`, signal);
      if (bytes[0] === 0x89 && bytes.subarray(1,4).toString() === 'PNG') return 'image/png';
      if (bytes[0] === 0xff && bytes[1] === 0xd8) return 'image/jpeg';
      if (bytes.subarray(0,3).toString() === 'GIF') return 'image/gif';
      if (bytes.subarray(0,4).toString() === 'RIFF' && bytes.subarray(8,12).toString() === 'WEBP') return 'image/webp';
      return null;
    },
  } }));
  const write = wrap(signal => createWriteToolDefinition(remote.cwd, { operations: {
    mkdir: async p => { await run(`mkdir -p ${quote(absolute(p))}`, signal); },
    writeFile: (p, content) => writeFile(p, content, signal),
  } }));
  const edit = wrap(signal => createEditToolDefinition(remote.cwd, { operations: {
    readFile: p => readFile(p, signal), writeFile: (p, content) => writeFile(p, content, signal),
    access: async p => { await run(`test -r ${quote(absolute(p))} && test -w ${quote(absolute(p))}`, signal); },
  } }));
  const bash = wrap(() => createBashToolDefinition(remote.cwd, { operations: shell, exposeSessionEnvironment: false }));
  const ls = wrap(signal => createLsToolDefinition(remote.cwd, { operations: {
    exists: async p => (await execute(`test -e ${quote(absolute(p))}`, { signal, allowFailure: true })).code === 0,
    stat: async p => { const data = await run(`if [ -d ${quote(absolute(p))} ]; then printf d; elif [ -e ${quote(absolute(p))} ]; then printf f; else exit 1; fi`, signal); return { isDirectory: () => data.toString() === 'd' }; },
    readdir: async p => {
      const data = await run(`cd ${quote(absolute(p))} || exit; for p in .[!.]* ..?* *; do [ -e "$p" ] || [ -L "$p" ] || continue; printf '%s\\0' "$p"; done`, signal);
      return data.toString().split('\0').filter(Boolean);
    },
  } }));
  const find = wrap(signal => createFindToolDefinition(remote.cwd, { operations: {
    exists: async p => (await execute(`test -d ${quote(absolute(p))}`, { signal, allowFailure: true })).code === 0,
    glob: async (pattern, cwd, options) => {
      const data = await run(`cd ${quote(absolute(cwd))} && if command -v rg >/dev/null 2>&1; then rg --files --hidden -0 -g '!.git' -g '!node_modules'; else find . -type d \\( -name .git -o -name node_modules \\) -prune -o -type f -print0; fi`, signal);
      return data.toString().split('\0').filter(Boolean).map(p => p.replace(/^\.\//, '')).filter(p => !options.ignore.some(ignore => path.matchesGlob(p, ignore))).filter(p => path.matchesGlob(p, pattern) || (!pattern.includes('/') && path.matchesGlob(path.posix.basename(p), pattern))).slice(0, options.limit);
    },
  } }));
  const grepDefinition = createGrepToolDefinition(remote.cwd);
  const grep = { ...grepDefinition, async execute(_id: string, params: any, signal: AbortSignal) {
    const target = absolute(params.path || '.');
    const flags = ['-n', '-H', ...(params.ignoreCase ? ['-i'] : []), ...(params.literal ? ['-F'] : []), ...(params.context ? ['-C', String(Math.max(0, Math.floor(params.context)))] : [])];
    const rg = ['rg', '--color', 'never', ...flags, ...(params.glob ? ['-g', params.glob] : []), '--', params.pattern, target].map(quote).join(' ');
    const fallback = ['grep', '-r', ...flags, ...(params.glob ? ['--include=' + params.glob] : []), '-e', params.pattern, target].map(quote).join(' ');
    const result = await execute(`cd ${quote(remote.cwd)} || exit; if command -v rg >/dev/null 2>&1; then ${rg}; else ${fallback}; fi`, { signal, allowFailure: true });
    if (result.code > 1) throw new Error(`Remote grep failed (${result.code})`);
    const text = result.data.toString().split('\n').slice(0, params.limit || 100).join('\n').slice(0, 50000);
    return { content: [{ type: 'text' as const, text: text || '(no matches)' }], details: {} };
  } };
  return { tools: [read, write, edit, bash, ls, find, grep], shell, run };
}

export default function (pi: ExtensionAPI) {
  if (!process.env.F_REMOTE_PROJECT) return;
  if (process.env.F_DISABLED_PLUGINS?.split(',').includes('ssh')) throw new Error('SSH plugin is disabled');
  const remote = JSON.parse(process.env.F_REMOTE_PROJECT) as RemoteDescriptor;
  const { tools, shell, run } = remoteTools(remote);
  for (const tool of tools) pi.registerTool(tool);
  pi.on('user_bash', () => ({ operations: shell }));
  pi.on('before_agent_start', async (event) => {
    const instructions = (await run(`if [ -r ${quote(path.posix.join(remote.cwd, 'AGENTS.md'))} ]; then head -c 24000 ${quote(path.posix.join(remote.cwd, 'AGENTS.md'))}; fi`)).toString();
    return { systemPrompt: event.systemPrompt.replaceAll(process.cwd(), remote.cwd) + `\n\nF remote project: ${remote.endpoint}:${remote.cwd}. All read/write/edit/bash/ls/find/grep operations execute on this remote computer. ${process.env.F_DISABLED_PLUGINS?.split(',').includes('whiteboard') ? 'The whiteboard plugin is disabled.' : "The whiteboard_* tools continue to manage this project's centralized F board. Use those tools for board data."}\n${instructions ? 'Remote project AGENTS.md:\n' + instructions : ''}` };
  });
}
