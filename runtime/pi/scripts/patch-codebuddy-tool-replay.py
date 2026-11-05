"""Keep streamed tool calls idempotent when the SDK replays its final message."""
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f'Pinned CodeBuddy source changed; cannot apply tool replay fix: {path}')
    path.write_text(text.replace(old, new, 1))


def patch_replay(source: Path) -> None:
    current = (source/"index.ts").read_text()
    if "completedToolCallIds" in current and "const toolBlocks" in current:
        return
    replace_once(source/'query-state.ts',
        '\tturnToolCallIds: string[] = [];',
        '\tturnToolCallIds: string[] = [];\n'
        '\t// Query-scoped: a final SDK assistant frame can arrive after tool-result reset.\n'
        '\tcompletedToolCallIds = new Set<string>();')
    index = source/'index.ts'
    replace_once(index,
        '\t\t// pi delivers the tool result via the next streamSimple call.\n\t\tc.turnOutput.stopReason = "toolUse";\n\t\tconst stream = c.currentPiStream;',
        '\t\t// pi delivers the tool result via the next streamSimple call.\n'
        '\t\tfor (const id of c.turnToolCallIds) c.completedToolCallIds.add(id);\n'
        '\t\tc.turnOutput.stopReason = "toolUse";\n\t\tconst stream = c.currentPiStream;')
    replace_once(index,
        '\tif (!assistantMsg?.content) return;\n\tc.turnToolCallIds = [];',
        '\tif (!assistantMsg?.content) return;\n'
        '\t// Pi may finish a fast tool and reset turnSawStreamEvent before the SDK\n'
        '\t// delivers the final assistant frame for that SAME message. Do not replay\n'
        '\t// its tools or reset the MCP handler cursor / pending result association.\n'
        '\tconst toolBlocks = assistantMsg.content.filter((b: any) => b.type === "tool_use");\n'
        '\tif (toolBlocks.length > 0 && toolBlocks.every((b: any) => c.completedToolCallIds.has(b.id))) return;\n'
        '\tc.turnToolCallIds = [];')
    replace_once(index,
        '\tif (c.turnSawToolCall && c.currentPiStream && c.turnOutput) {\n\t\tc.turnOutput.stopReason = "toolUse";',
        '\tif (c.turnSawToolCall && c.currentPiStream && c.turnOutput) {\n'
        '\t\tfor (const id of c.turnToolCallIds) c.completedToolCallIds.add(id);\n'
        '\t\tc.turnOutput.stopReason = "toolUse";')
    replace_once(index,
        '\tsyncSharedSession,\n\tpromptAndWait,',
        '\tsyncSharedSession,\n\tpromptAndWait,\n'
        '\tQueryContext, processStreamEvent, processAssistantMessage, streamCodebuddySdk, buildMcpServers,\n'
        '\ttrackQuery(c: QueryContext) {\n'
        '\t\tactiveQueryContexts.add(c);\n'
        '\t\treturn () => activeQueryContexts.delete(c);\n'
        '\t},')
    replace_once(index,
        '// Note: resetTurnState clears turnSawStreamEvent while the generator may still\n'
        '// have queued messages from the previous turn. This is safe because step 3 nulls\n'
        '// currentPiStream, so any leftover messages hit the `!ctx().currentPiStream` guard\n'
        '// in consumeQuery and are skipped before resetTurnState runs.',
        '// A fast tool can deliver its result and reopen currentPiStream before the SDK\n'
        '// emits its queued final assistant frame. Query-scoped completedToolCallIds\n'
        '// prevents that frame from replaying tools or resetting their MCP handler cursor.')


def patch_bridge(source: Path) -> None:
    (source/'tool-result-bridge.ts').write_text(Path(__file__).with_name('tool-result-bridge.ts').read_text())
    replace_once(source/'query-state.ts',
        'import type { McpResult } from "./extract-tool-results.js";',
        'import type { McpResult } from "./extract-tool-results.js";\nimport type { ToolResultBridge } from "./tool-result-bridge.js";')
    replace_once(source/'query-state.ts',
        '\tcompletedToolCallIds = new Set<string>();',
        '\tcompletedToolCallIds = new Set<string>();\n\ttoolBridge?: ToolResultBridge;')
    index = source/'index.ts'
    replace_once(index,
        'import { QueryContext, ctx } from "./query-state.js";',
        'import { QueryContext, ctx } from "./query-state.js";\nimport { ToolResultBridge } from "./tool-result-bridge.js";')
    replace_once(index,
        'queryCtx.turnToolCallIds.includes(id))',
        'queryCtx.turnToolCallIds.includes(id) || queryCtx.toolBridge?.hasCall(id))')
    replace_once(index,
        '// Handlers are assigned toolCallIds from turnToolCallIds (populated when the SDK\n'
        '// emits tool_use blocks). Results are matched by ID, not position.',
        '// MCP handlers and streamed declarations can arrive in either order. The\n'
        '// query-scoped bridge binds normalized name/arguments to a durable call ID;\n'
        '// a late message_start cannot erase the association or shift parallel results.')
    text = index.read_text()
    start = text.find('\t\thandler: async () => {')
    if start >= 0:
        end = text.index('\n\t\t},\n\t}));',start) + len('\n\t\t},')
        old = text[start:end]
        replace_once(index, old, '\t\thandler: async (args: Record<string, unknown>, extra: unknown) => {\n'
            '\t\t\treturn getToolBridge(queryCtx).waitFor(tool.name, mapToolArgs(tool.name, args), extra);\n\t\t},')
    replace_once(index,
        'function buildMcpServers(tools: Tool[], queryCtx: QueryContext)',
        'function getToolBridge(c: QueryContext): ToolResultBridge {\n'
        '\treturn c.toolBridge ??= new ToolResultBridge(c.pendingToolCalls, c.pendingResults);\n}\n\n'
        'function buildMcpServers(tools: Tool[], queryCtx: QueryContext)')
    text = index.read_text()
    old = '\t\tfor (const id of c.turnToolCallIds) c.completedToolCallIds.add(id);'
    replacement = ('\t\tfor (const block of c.turnBlocks) {\n'
        '\t\t\tif (block.type === "toolCall") {\n'
        '\t\t\t\tgetToolBridge(c).declare(block.id, block.name, block.arguments);\n'
        '\t\t\t\tc.completedToolCallIds.add(block.id);\n'
        '\t\t\t}\n\t\t}')
    if old in text:
        if text.count(old) != 2:
            raise RuntimeError('Expected both streamed and fallback completion paths')
        index.write_text(text.replace(old, replacement))
    text = index.read_text()
    start = text.find('\t\tfor (const result of allResults) {')
    if start >= 0 and 'getToolBridge(resultCtx).deliver(result)' not in text:
        end = text.index('\n\t\tif (resultCtx.pendingToolCalls.size > 0)',start)
        replace_once(index,text[start:end],
            '\t\tfor (const result of allResults) getToolBridge(resultCtx).deliver(result);')
    replace_once(index,
        '\t\twasAborted = true;\n\t\tabortCtx.deferredUserMessages = [];',
        '\t\twasAborted = true;\n\t\tabortCtx.toolBridge?.cancel();\n\t\tabortCtx.deferredUserMessages = [];')
    replace_once(index,
        '\tclaimCurrentPiStream(stream, "fresh-query", queryCtx);\n\tqueryCtx.pendingToolCalls.clear();',
        '\tclaimCurrentPiStream(stream, "fresh-query", queryCtx);\n'
        '\tqueryCtx.toolBridge?.cancel("Query replaced");\n'
        '\tqueryCtx.toolBridge = undefined;\n'
        '\tqueryCtx.completedToolCallIds.clear();\n'
        '\tqueryCtx.pendingToolCalls.clear();')
    # Also settle requests that arrived before their streamed declarations on teardown.
    text = index.read_text()
    old = 'for (const pending of queryCtx.pendingToolCalls.values()) { pending.resolve({ content: [{ type: "text", text: "Query ended" }] }); }'
    new = 'queryCtx.toolBridge?.cancel("Query ended");\n\t\t\t\t'+old
    if new not in text:
        index.write_text(text.replace(old,new))



def patch_history(source: Path) -> None:
    # CodeBuddy resumes the leaf's parent chain, not every JSONL row. Every user
    # record must link to its preceding assistant/user record during cold import.
    replace_once(source/'cb-session-io.ts',
        'id, timestamp: ts, type: "message", role: "user",',
        'id, parentId, timestamp: ts, type: "message", role: "user",')
    replace_once(source/'cb-session-io.ts',
        'b.type === "tool_result" ? `[tool_result:${b.tool_use_id}]`',
        'b.type === "tool_result" ? `[tool_result:${b.tool_use_id}${b.is_error ? ":error" : ""}]\\n${typeof b.content === "string" ? b.content : JSON.stringify(b.content)}`')
    replace_once(source/'cb-session-io.ts',
        'b.type === "tool_use" ? `[tool:${b.name}]`',
        'b.type === "tool_use" ? `[tool:${b.name} id=${b.id}]\\n${JSON.stringify(b.input)}`')


def patch(source: Path) -> None:
    patch_replay(source)
    patch_bridge(source)
    patch_history(source)


if __name__ == '__main__':
    import sys
    for directory in sys.argv[1:]:
        patch(Path(directory))
