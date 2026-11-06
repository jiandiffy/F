// Process-wide stream owner for the shared-registry case (CLI subagents).
// A fresh ModelRuntime (pi-web per chat) does not see the first registration,
// so each runtime still needs its own provider entry.
export const ACTIVE_STREAM_SIMPLE_KEY = Symbol.for("codebuddy-sdk-cbc:activeStreamSimple");

export interface ProviderRegistration {
	streamFn: unknown;
	claimStream: boolean;
}

interface ActiveStream {
	runtime: object | undefined;
	streamFn: unknown;
}

export function providerRegistration(
	globals: Record<symbol, unknown>,
	ownStream: unknown,
	runtime: object | undefined,
): ProviderRegistration {
	const active = globals[ACTIVE_STREAM_SIMPLE_KEY] as ActiveStream | undefined;
	if (!active) {
		globals[ACTIVE_STREAM_SIMPLE_KEY] = { runtime, streamFn: ownStream };
		return { streamFn: ownStream, claimStream: true };
	}
	if (runtime !== undefined && active.runtime === runtime) {
		return { streamFn: active.streamFn, claimStream: false };
	}
	if (runtime === undefined || active.runtime === undefined) {
		return { streamFn: active.streamFn, claimStream: false };
	}
	return { streamFn: ownStream, claimStream: false };
}

export function clearOwnedStream(globals: Record<symbol, unknown>, ownStream: unknown): boolean {
	const active = globals[ACTIVE_STREAM_SIMPLE_KEY] as ActiveStream | undefined;
	if (!active || active.streamFn !== ownStream) return false;
	globals[ACTIVE_STREAM_SIMPLE_KEY] = undefined;
	return true;
}
