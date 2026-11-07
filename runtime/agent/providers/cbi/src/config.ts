import network from "../../../scripts/network.cjs";
import profiles from "../../../scripts/codebuddy-profile.cjs";
import { fileURLToPath } from "node:url";
import type { SettingSource } from "./index-types.js";
import type { ModelOverrides } from "./models.js";
import { CONFIG_DIR_NAME } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

function redactPath(path: string): string {
	const home = homedir();
	return home && path.startsWith(home) ? "~" + path.slice(home.length) : path;
}

export const CONFIG_BASENAME = "codebuddy-sdk.json";

export interface Config {
	askCodebuddy?: {
		enabled?: boolean;
		name?: string;
		label?: string;
		description?: string;
		defaultMode?: "full" | "read" | "none";
		defaultIsolated?: boolean;
		allowFullMode?: boolean;
		appendSkills?: boolean;
	};
	provider?: {
		appendSystemPrompt?: boolean;
		settingSources?: SettingSource[];
		strictMcpConfig?: boolean;
		pathToCodebuddyCode?: string;
		/**
		 * Runtime used to spawn the CodeBuddy CLI (e.g. `"node"`). Defaults to the
		 * host runtime; set this when a Bun-compiled host has no `bun` on `PATH`.
		 */
		executable?: string;
		/** Run the CLI against a private CodeBuddy config dir and disable its memory. */
		isolatedEnv?: boolean;
		/** Config dir used when `isolatedEnv` is on. Defaults to `~/.codebuddy-cli-isolated`. */
		codebuddyConfigDir?: string;
		/** Override the estimated context window (tokens) for ALL models. */
		contextWindow?: number;
		/** Override the estimated max output tokens for ALL models. */
		maxTokens?: number;
		/** Per-model overrides keyed by model id (or id substring). */
		modelOverrides?: Record<string, ModelOverrides>;
	};
}

export function resolveCodebuddyConfigDir(provider?: Config["provider"]): string | undefined {
	if (provider?.isolatedEnv !== true) return undefined;
	return provider.codebuddyConfigDir ?? join(homedir(), ".codebuddy-cli-isolated");
}

export function buildCodebuddyEnv(
	provider?: Config["provider"],
	base: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
	const env = { ...network.networkEnv("cbi", base), DISABLE_AUTO_COMPACT: "1", DISABLE_AUTOUPDATER: "1", CODEBUDDY_INTERNET_ENVIRONMENT: "public", ACC_PRODUCT_CONFIG_PATH: join(configDirectory, "product.json") };
 delete (env as any).CODEBUDDY_API_KEY;
 delete (env as any).CODEBUDDY_BASE_URL;
	const dir = resolveCodebuddyConfigDir(provider);
	if (!dir) return env;
	return {
		...env,
		CODEBUDDY_CONFIG_DIR: dir,
		CODEBUDDY_MEMORY_ENABLED: "0",
		CODEBUDDY_DISABLE_AUTO_MEMORY: "1",
		CODEBUDDY_TEAM_MEMORY_ENABLED: "0",
	};
}

export function tryParseJson(path: string): Partial<Config> {
	if (!existsSync(path)) return {};
	try {
		return JSON.parse(readFileSync(path, "utf-8"));
	} catch (e) {
		console.error(`codebuddy-sdk: failed to parse ${redactPath(path)}: ${e}`);
		return {};
	}
}

export function loadConfig(cwd: string): Config {
 return {
  askCodebuddy: { enabled: false },
  provider: {
   appendSystemPrompt: true, strictMcpConfig: true,
   executable: join(runtimeRoot, '../node/bin/node'),
   pathToCodebuddyCode: join(runtimeRoot, 'node_modules/@tencent-ai/codebuddy-code/bin/codebuddy'),
   isolatedEnv: true,
   codebuddyConfigDir: configDirectory,
  }
 };
}

const runtimeRoot = fileURLToPath(new URL("../../..", import.meta.url));
const configDirectory = profiles.ensureProfile("cbi");
