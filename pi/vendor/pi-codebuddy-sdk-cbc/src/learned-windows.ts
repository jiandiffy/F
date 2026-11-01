/**
 * Served context windows, remembered across processes.
 *
 * This backend reports no window metadata, so every model is registered from a
 * name estimate. The served value only arrives per turn, inside `modelUsage`;
 * `syncServedWindow` applies it to the catalog entry and the live model, but
 * only in memory. Without persistence that knowledge dies with the process:
 * the next `discoverModels` re-registers the estimate and rewrites the model
 * cache, so each restart shows the guess again for every model the user has not
 * overridden by hand.
 *
 * Keep the last served value per model id on disk and re-apply it after
 * `buildModels()`. Precedence: user `modelOverrides` > learned > SDK metadata >
 * name estimate.
 */
import { homedir } from "os";
import { dirname, join } from "path";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "fs";
import type { WindowSyncChange } from "./served-window.js";

export interface LearnedWindow {
	contextWindow?: number;
	maxTokens?: number;
}

export type LearnedWindows = Record<string, LearnedWindow>;

/** In-process cache so repeated reads in one session do not touch the disk. */
export const LEARNED_WINDOWS_KEY = Symbol.for("codebuddy-sdk-cbc:learnedWindows");

const defaultStoreFile = () => join(process.env.PI_CODING_AGENT_DIR!, "codebuddy-sdk-cbc-learned-windows.json");

// Injectable for tests.
const storeFile = () => process.env.CODEBUDDY_SDK_LEARNED_WINDOWS_PATH || defaultStoreFile();

function sanitize(value: unknown): LearnedWindow | undefined {
	if (!value || typeof value !== "object") return undefined;
	const raw = value as LearnedWindow;
	const entry: LearnedWindow = {};
	if (Number.isSafeInteger(raw.contextWindow) && (raw.contextWindow as number) > 0) entry.contextWindow = raw.contextWindow;
	if (Number.isSafeInteger(raw.maxTokens) && (raw.maxTokens as number) > 0) entry.maxTokens = raw.maxTokens;
	return Object.keys(entry).length ? entry : undefined;
}

export function readLearnedWindows(): LearnedWindows {
	const inProcess = (globalThis as Record<symbol, unknown>)[LEARNED_WINDOWS_KEY] as LearnedWindows | undefined;
	if (inProcess) return inProcess;
	try {
		const parsed: unknown = JSON.parse(readFileSync(storeFile(), "utf8"));
		if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
			const map: LearnedWindows = {};
			for (const [id, value] of Object.entries(parsed as Record<string, unknown>)) {
				const entry = sanitize(value);
				if (entry) map[id] = entry;
			}
			return map;
		}
	} catch {
		// No store yet, or unreadable — the caller falls back to estimates.
	}
	return {};
}

export function writeLearnedWindows(map: LearnedWindows): void {
	(globalThis as Record<symbol, unknown>)[LEARNED_WINDOWS_KEY] = map;
	try {
		const path = storeFile();
		mkdirSync(dirname(path), { recursive: true });
		const tmp = `${path}.tmp`;
		const sorted = Object.fromEntries(Object.entries(map).sort(([a], [b]) => a.localeCompare(b)));
		writeFileSync(tmp, JSON.stringify(sorted));
		renameSync(tmp, path);
	} catch {
		// Store is best-effort; the next turn re-learns the value.
	}
}

/** Fold served-window changes into `map`. Returns true when something moved. */
export function recordServedWindows(map: LearnedWindows, changes: readonly WindowSyncChange[]): boolean {
	let touched = false;
	for (const change of changes) {
		if (!Number.isSafeInteger(change.to) || change.to <= 0) continue;
		const entry = (map[change.id] ??= {});
		if (entry[change.field] === change.to) continue;
		entry[change.field] = change.to;
		touched = true;
	}
	return touched;
}

/** Drop ids the backend no longer serves. */
export function pruneLearnedWindows(map: LearnedWindows, ids: Iterable<string>): LearnedWindows {
	const keep = new Set(ids);
	const out: LearnedWindows = {};
	for (const [id, value] of Object.entries(map)) {
		if (keep.has(id)) out[id] = value;
	}
	return out;
}

/**
 * Overwrite estimated windows with learned ones. Matching is by exact id on
 * purpose — override keys use substring matching, learned ids must not leak into
 * neighbouring models. `skip` keeps user overrides authoritative.
 */
export function applyLearnedWindows<T extends { id: string; contextWindow: number; maxTokens: number }>(
	models: readonly T[],
	learned: LearnedWindows,
	skip?: (id: string) => boolean,
): T[] {
	return models.map((model) => {
		const entry = learned[model.id];
		if (!entry || skip?.(model.id)) return model;
		return {
			...model,
			contextWindow: entry.contextWindow ?? model.contextWindow,
			maxTokens: entry.maxTokens ?? model.maxTokens,
		};
	});
}
