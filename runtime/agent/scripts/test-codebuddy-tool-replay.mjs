import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createJiti } from '../node_modules/jiti/lib/jiti.mjs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

process.env.PI_CODING_AGENT_DIR ??= new URL('../state', import.meta.url).pathname;
const jiti = createJiti(import.meta.url);
const model = { api: 'test', provider: 'test', id: 'test', cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const names = new Map([['mcp__custom_tools__write', 'write']]);
const tools = [{ name: 'write', description: 'test', parameters: { type: 'object', properties: {path:{type:'string'},content:{type:'string'}}, required:['path','content'] } }];
const tick = () => new Promise(resolve => setImmediate(resolve));

for (const region of ['cbi', 'cbc']) {
  const path = process.env.CODEBUDDY_TEST_VENDOR_ROOT
    ? `${process.env.CODEBUDDY_TEST_VENDOR_ROOT}/pi-codebuddy-sdk-${region}/src/index.ts`
    : `../providers/${region}/src/index.ts`;
  const { __test: t } = await jiti.import(path);
  function setup() {
    const c = new t.QueryContext();
    c.activeQuery = {};
    c.resetTurnState(model);
    const events = [];
    c.currentPiStream = { push(e) { events.push(e); }, end() {} };
    const untrack = t.trackQuery(c);
    const server = t.buildMcpServers(tools, c).custom_tools.instance;
    const handler = server._registeredTools.write.handler;
    const write = id => handler({path: `${id}.txt`, content: id});
    return { c, events, write, handler, untrack, server };
  }
  function streamed(c, ids) {
    const send = event => t.processStreamEvent({ type: 'stream_event', event }, names, model, c);
    send({ type: 'message_start', message: {} });
    ids.forEach((id, index) => {
      send({ type: 'content_block_start', index, content_block: { type: 'tool_use', id, name: 'mcp__custom_tools__write', input: { path: `${id}.txt`, content: id } } });
      send({ type: 'content_block_stop', index });
    });
    send({ type: 'message_stop' });
  }
  function assistant(c, ids) {
    t.processAssistantMessage({ type: 'assistant', message: { content: [
      { type: 'thinking', thinking: 'Write the file' },
      ...ids.map(id => ({ type: 'tool_use', id, name: 'mcp__custom_tools__write', input: { path: `${id}.txt`, content: id } })),
    ] } }, model, names, c);
  }
  function result(c, ids) {
    return t.streamCodebuddySdk(model, { messages: [
      { role: 'assistant', content: ids.map(id => ({ type: 'toolCall', id, name: 'write', arguments: {} })) },
      ...ids.map(id => ({ role: 'toolResult', toolCallId: id, toolName: 'write', content: [{ type: 'text', text: `written ${id}` }], timestamp: 1 })),
    ] });
  }

  test(`${region}: fast write result before final assistant and MCP handler`, { timeout: 5000 }, async () => {
    const s = setup();
    try {
      streamed(s.c, ['one']);
      const waitingStream = result(s.c, ['one']);
      assistant(s.c, ['one']); // The exact order seen in the stuck conversation.
      assert.equal(s.c.currentPiStream, waitingStream, 'late final frame must leave the continuation stream open');
      assert.deepEqual(s.c.turnOutput.content, [], 'must not emit another file write or its old thinking');
      assert.deepEqual(s.c.turnToolCallIds, ['one']);
      assert.equal(s.c.nextHandlerIdx, 0);
      assert.equal((await s.write('one')).content[0].text, 'written one');
      assert.equal(s.c.pendingToolCalls.size, 0);
      assert.equal(s.c.pendingResults.size, 0);
    } finally { s.untrack(); }
  });

  test(`${region}: handler before result, late replay cannot rewind parallel handler cursor`, { timeout: 5000 }, async () => {
    const s = setup();
    try {
      streamed(s.c, ['one', 'two']);
      const first = s.write('one');
      s.c.nextHandlerIdx = 900;
      const waitingStream = result(s.c, ['one', 'two']);
      assistant(s.c, ['one', 'two']);
      assert.equal(s.c.currentPiStream, waitingStream);
      assert.equal(s.c.nextHandlerIdx, 900, 'late replay must not reset state; matching must not use the cursor');
      const second = s.write('two');
      assert.equal((await first).content[0].text, 'written one');
      assert.equal((await second).content[0].text, 'written two');
      assert.equal(s.c.pendingToolCalls.size, 0);
      assert.equal(s.c.pendingResults.size, 0);
    } finally { s.untrack(); }
  });

  test(`${region}: final frame before result remains safe and next streamed turn proceeds`, { timeout: 5000 }, async () => {
    const s = setup();
    try {
      streamed(s.c, ['one']);
      assistant(s.c, ['one']);
      result(s.c, ['one']);
      await s.write('one');
      streamed(s.c, ['two']);
      const waitingStream = result(s.c, ['two']);
      assistant(s.c, ['two']);
      assert.equal(s.c.currentPiStream, waitingStream);
      assert.equal((await s.write('two')).content[0].text, 'written two');
      assert.equal(s.c.completedToolCallIds.size, 2);
    } finally { s.untrack(); }
  });

  test(`${region}: assistant-only SDK fallback still delivers new tools exactly once`, { timeout: 5000 }, async () => {
    const s = setup();
    try {
      assistant(s.c, ['fallback']);
      assert.equal(s.events.filter(e => e.type === 'toolcall_end').length, 1);
      const waitingStream = result(s.c, ['fallback']);
      assistant(s.c, ['fallback']);
      assert.equal(s.c.currentPiStream, waitingStream);
      assert.equal((await s.write('fallback')).content[0].text, 'written fallback');
      t.processAssistantMessage({ type: 'assistant', message: { content: [{ type: 'text', text: 'Done' }] } }, model, names, s.c);
      assert.equal(s.c.turnOutput.content[0].text, 'Done');
      await tick();
    } finally { s.untrack(); }
  });

  test(`${region}: late message_start clears turn IDs but cannot orphan a completed edit`, { timeout: 5000 }, async () => {
    const s = setup();
    try {
      streamed(s.c, ['one']);
      const next = result(s.c, ['one']);
      t.processStreamEvent({type:'stream_event',event:{type:'message_start',message:{}}}, names, model, s.c);
      assert.deepEqual(s.c.turnToolCallIds, []);
      assert.equal((await s.write('one')).content[0].text, 'written one');
      assert.equal(s.c.currentPiStream, next);
      assert.equal(s.c.pendingToolCalls.size, 0);
    } finally { s.untrack(); }
  });

  test(`${region}: parallel same-name handlers arriving out of order receive their own result`, { timeout: 5000 }, async () => {
    const s = setup();
    try {
      const second = s.write('two'); // Handler can arrive before streamed declarations.
      streamed(s.c, ['one', 'two']);
      const first = s.write('one');
      s.c.turnToolCallIds = []; s.c.nextHandlerIdx = 999;
      result(s.c, ['one', 'two']);
      assert.equal((await first).content[0].text, 'written one');
      assert.equal((await second).content[0].text, 'written two');
      assert.equal(s.c.pendingToolCalls.size, 0);
    } finally { s.untrack(); }
  });

  test(`${region}: 600 tool turns with varied result/handler/frame order`, { timeout: 15000 }, async () => {
    const s = setup();
    try {
      for(let i=0;i<600;i++) {
        const id = 'stress-'+i;
        if(!s.c.currentPiStream) { s.c.resetTurnState(model); s.c.currentPiStream={push(){},end(){}}; }
        const before = i%3===0 ? s.write(id) : null;
        streamed(s.c,[id]);
        if(i%2===0) assistant(s.c,[id]);
        const next=result(s.c,[id]);
        if(i%4===0) t.processStreamEvent({type:'stream_event',event:{type:'message_start',message:{}}}, names, model, s.c);
        assistant(s.c,[id]);
        const value=await (before ?? s.write(id));
        assert.equal(value.content[0].text,'written '+id);
        assert.equal(s.c.currentPiStream,next);
        assert.equal(s.c.pendingToolCalls.size,0);
        assert.equal(s.c.pendingResults.size,0);
      }
    } finally { s.c.toolBridge?.cancel(); s.untrack(); }
  });

  test(`${region}: real MCP transport, schema validation and reversed parallel requests`, { timeout: 5000 }, async () => {
    const s=setup(); const client=new Client({name:'bridge-regression',version:'1.0.0'});
    const [left,right]=InMemoryTransport.createLinkedPair();
    try {
      await Promise.all([client.connect(left),s.server.connect(right)]);
      const two=client.callTool({name:'write',arguments:{content:'two',path:'two.txt'}});
      const one=client.callTool({name:'write',arguments:{path:'one.txt',content:'one'}});
      await tick();
      streamed(s.c,['one','two']);
      result(s.c,['one','two']);
      assert.equal((await one).content[0].text,'written one');
      assert.equal((await two).content[0].text,'written two');
      assert.equal(s.c.pendingToolCalls.size,0);
      assert.equal(s.c.pendingResults.size,0);
    } finally { await client.close(); await s.server.close(); s.c.toolBridge?.cancel(); s.untrack(); }
  });

  test(`${region}: cancellation settles both unmatched and bound handlers`, { timeout: 5000 }, async () => {
    const s=setup();
    try {
      const unmatched=s.write('not-declared');
      streamed(s.c,['one']);
      const bound=s.write('one');
      s.c.toolBridge.cancel();
      assert.equal((await unmatched).isError,true);
      assert.equal((await bound).isError,true);
      assert.equal(s.c.pendingToolCalls.size,0);
    } finally { s.untrack(); }
  });

  test(`${region}: duplicate MCP request IDs join the same pending result`, { timeout: 5000 }, async () => {
    const s=setup();
    try {
      streamed(s.c,['one']);
      const args={path:'one.txt',content:'one'}, extra={_meta:{tool_use_id:'one'}};
      const first=s.handler(args,extra), duplicate=s.handler(args,extra);
      result(s.c,['one']);
      assert.equal((await first).content[0].text,'written one');
      assert.equal((await duplicate).content[0].text,'written one');
      result(s.c,['one']);
      assert.equal(s.c.pendingToolCalls.size,0);
      assert.equal(s.c.pendingResults.size,0);
    } finally { s.c.toolBridge?.cancel(); s.untrack(); }
  });

  test(`${region}: identical arguments with a fresh ID and separate queries remain independent`, { timeout: 5000 }, async () => {
    const a = setup(), b = setup();
    try {
      streamed(a.c, ['shared']);
      result(a.c, ['shared']);
      await a.write('shared');
      assistant(a.c, ['fresh']);
      assert.equal(a.c.turnOutput.content.at(-1).id, 'fresh');
      assistant(b.c, ['shared']);
      assert.equal(b.events.filter(e => e.type === 'toolcall_end').length, 1);
    } finally { a.untrack(); b.untrack(); }
  });
}

for (const region of ['cbi','cbc']) {
  test(`${region}: cold import preserves one multi-turn parent chain and tool contents`, async () => {
    const {mkdtemp,readFile,rm}=await import('node:fs/promises');
    const {tmpdir}=await import('node:os');const path=await import('node:path');
    const root=await mkdtemp(path.join(tmpdir(),'f-provider-history-'));
    try {
      const {createSession}=await jiti.import(`../providers/${region}/src/cb-session-io.ts`);
      const session=createSession({projectPath:root,codebuddyDir:root});
      session.importPiMessages([
        {role:'user',content:'FIRST_TURN_FACT',timestamp:1},
        {role:'assistant',content:[{type:'toolCall',id:'read-1',name:'read',arguments:{path:'evidence.txt'}}],provider:region,api:`codebuddy-sdk-${region}`,timestamp:2},
        {role:'toolResult',toolCallId:'read-1',toolName:'read',content:[{type:'text',text:'SECRET_TOOL_FACT'}],timestamp:3},
        {role:'assistant',content:[{type:'text',text:'FIRST_DONE'}],provider:region,api:`codebuddy-sdk-${region}`,timestamp:4},
        {role:'user',content:'SECOND_TURN_FACT',timestamp:5},
        {role:'assistant',content:[{type:'text',text:'SECOND_DONE'}],provider:region,api:`codebuddy-sdk-${region}`,timestamp:6},
      ]);
      session.save();
      const rows=(await readFile(session.jsonlPath,'utf8')).trim().split('\n').map(JSON.parse);
      const byId=new Map(rows.map(r=>[r.id,r]));const chain=[];let current=rows.at(-1);
      while(current){chain.unshift(current);current=byId.get(current.parentId);}
      assert.equal(chain.length,rows.length,'resuming the latest leaf must include every imported turn');
      const rendered=chain.map(r=>r.content.map(c=>c.text??'').join('')).join('\n');
      assert.match(rendered,/FIRST_TURN_FACT/);assert.match(rendered,/SECOND_TURN_FACT/);
      assert.match(rendered,/SECRET_TOOL_FACT/);assert.match(rendered,/evidence\.txt/);
    } finally {await rm(root,{recursive:true,force:true});}
  });
}
