import type { McpResult } from "./extract-tool-results.js";

type Pending = { toolName: string; resolve: (result: McpResult) => void };
type Call = { id: string; name: string; key: string; claimed: boolean; result?: McpResult };
type Waiting = { name: string; key: string; resolve: (result: McpResult) => void; timer: ReturnType<typeof setTimeout> };

function stableKey(value: unknown): string {
    if (Array.isArray(value)) return "[" + value.map(stableKey).join(",") + "]";
    if (value && typeof value === "object") {
        const object = value as Record<string, unknown>;
        return "{" + Object.keys(object).sort().filter(k => object[k] !== undefined)
            .map(k => JSON.stringify(k) + ":" + stableKey(object[k])).join(",") + "}";
    }
    return JSON.stringify(value) ?? "null";
}

/** Query-scoped rendezvous. Neither a new message nor a fast result resets it. */
export class ToolResultBridge {
    private calls = new Map<string, Call>();
    private waiting: Waiting[] = [];
    constructor(private pending: Map<string, Pending>, private results: Map<string, McpResult>) {}

    hasCall(id: string): boolean { return this.calls.has(id); }

    declare(id: string, name: string, args: Record<string, unknown>): void {
        if (this.calls.has(id)) return;
        const call: Call = { id, name, key: stableKey(args), claimed: false };
        this.calls.set(id, call);
        const index = this.waiting.findIndex(w => w.name === name && w.key === call.key);
        if (index >= 0) {
            const [waiting] = this.waiting.splice(index, 1);
            clearTimeout(waiting.timer);
            this.bind(call, waiting.resolve);
        }
    }

    waitFor(name: string, args: Record<string, unknown>, extra?: any): Promise<McpResult> {
        const meta = extra?._meta ?? {};
        const id = meta.tool_use_id ?? meta.toolCallId ?? meta.tool_call_id;
        const key = stableKey(args);
        const call = typeof id === "string" ? this.calls.get(id)
            : [...this.calls.values()].find(c => !c.claimed && c.name === name && c.key === key);
        return new Promise(resolve => {
            if (call && call.name === name && call.key === key) { this.bind(call, resolve); return; }
            // Bound calls may legitimately run for minutes (builds, SSH). Only an
            // MCP request with NO matching model call has a short handshake limit.
            const waiting: Waiting = { name, key, resolve, timer: setTimeout(() => {
                this.waiting = this.waiting.filter(w => w !== waiting);
                resolve({ isError: true, content: [{ type: "text", text: "Tool bridge could not match the SDK request to a model call within 10 seconds. Inspect existing outputs before retrying." }] });
            }, 10000) };
            this.waiting.push(waiting);
        });
    }

    private bind(call: Call, resolve: (result: McpResult) => void): void {
        call.claimed = true;
        const result = call.result ?? this.results.get(call.id);
        if (result) {
            call.result = result;
            this.results.delete(call.id);
            resolve(result);
        } else {
            const previous = this.pending.get(call.id);
            if (previous) {
                const original = previous.resolve;
                previous.resolve = result => { original(result); resolve(result); };
            } else this.pending.set(call.id, { toolName: call.name, resolve });
        }
    }

    deliver(result: McpResult): void {
        const id = result.toolCallId;
        if (!id) throw new Error("Tool result is missing its call ID");
        const call = this.calls.get(id);
        if (call) call.result = result;
        const pending = this.pending.get(id);
        if (pending) { this.pending.delete(id); pending.resolve(result); }
        else if (!call?.claimed) this.results.set(id, result);
    }

    cancel(text = "Operation aborted"): void {
        const result = { isError: true, content: [{ type: "text" as const, text }] };
        for (const waiting of this.waiting) { clearTimeout(waiting.timer); waiting.resolve(result); }
        this.waiting = [];
        for (const pending of this.pending.values()) pending.resolve(result);
        this.pending.clear();
        this.results.clear();
    }
}
