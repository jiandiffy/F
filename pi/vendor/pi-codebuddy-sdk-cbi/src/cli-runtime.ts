/**
 * Pick a runtime the host can actually spawn for the CodeBuddy CLI subprocess.
 *
 * The Agent SDK resolves the child runtime from the *host* runtime
 * (`@tencent-ai/agent-sdk/lib/transport/process-transport.js`, `resolveRuntime()`):
 * when `process.versions.bun` is set it always spawns `bun`, and `node` is only
 * the final default. Bun-compiled hosts — `omp`, or any single-file Bun binary —
 * ship no `bun` executable on `PATH`, so every spawn fails with
 * `Executable not found in $PATH: "bun"` and neither model discovery nor a turn
 * can run.
 *
 * When the host is Bun and `bun` is not resolvable, hand the SDK an explicit
 * `executable` (its branch 2) pointing at `node`. `provider.executable` in
 * `codebuddy-sdk.json` overrides the automatic choice.
 */
import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";

export interface RuntimeHost {
	/** `process.versions` */
	versions?: Record<string, string | undefined>;
	/** `process.env.PATH` */
	path?: string;
}

function currentHost(): RuntimeHost {
	return { versions: process.versions as Record<string, string | undefined>, path: process.env.PATH };
}

/** True when `name` is a runnable file in one of the `PATH` entries. */
export function isOnPath(name: string, pathValue: string | undefined): boolean {
	if (!name || !pathValue) return false;
	for (const dir of pathValue.split(delimiter)) {
		if (!dir) continue;
		try {
			accessSync(join(dir, name), constants.X_OK);
			return true;
		} catch {
			// Not here — keep looking.
		}
	}
	return false;
}

/**
 * The runtime the CLI subprocess needs, or `undefined` when the SDK's own choice
 * works (a node/deno host, or a Bun host that has a `bun` on `PATH`).
 */
export function resolveCliRuntime(host: RuntimeHost = currentHost()): string | undefined {
	if (!host.versions?.bun) return undefined;
	if (isOnPath("bun", host.path)) return undefined;
	return isOnPath("node", host.path) ? "node" : undefined;
}

/**
 * Return `args` with `options.executable` filled in when the host cannot spawn
 * the SDK's default runtime. An explicit `executable` — on the call or in the
 * config — always wins.
 */
export function withCliRuntime<T extends { options?: { executable?: string } }>(
	args: T,
	configuredExecutable?: string,
	host: RuntimeHost = currentHost(),
): T {
	const options = args?.options;
	if (options?.executable) return args;
	const executable = configuredExecutable?.trim() || resolveCliRuntime(host);
	if (!executable) return args;
	return { ...args, options: { ...options, executable } };
}
