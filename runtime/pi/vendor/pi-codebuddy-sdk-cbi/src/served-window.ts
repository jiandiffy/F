export interface ServedWindow {
	contextWindow?: number;
	maxOutputTokens?: number;
}

export interface WindowTarget {
	contextWindow?: number;
	maxTokens?: number;
}

export interface WindowSyncChange {
	id: string;
	field: "contextWindow" | "maxTokens";
	from: number | undefined;
	to: number;
}

export function syncServedWindow(
	usage: Record<string, ServedWindow> | undefined,
	targetsFor: (id: string) => WindowTarget[],
): WindowSyncChange[] {
	if (!usage) return [];
	const changes: WindowSyncChange[] = [];
	for (const [id, served] of Object.entries(usage)) {
		for (const target of targetsFor(id)) {
			if (served.contextWindow && served.contextWindow > 0 && target.contextWindow !== served.contextWindow) {
				changes.push({ id, field: "contextWindow", from: target.contextWindow, to: served.contextWindow });
				target.contextWindow = served.contextWindow;
			}
			if (served.maxOutputTokens && served.maxOutputTokens > 0 && target.maxTokens !== served.maxOutputTokens) {
				changes.push({ id, field: "maxTokens", from: target.maxTokens, to: served.maxOutputTokens });
				target.maxTokens = served.maxOutputTokens;
			}
		}
	}
	return changes;
}
