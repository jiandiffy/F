import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { createAgentSession, ModelRuntime, DefaultResourceLoader, SettingsManager, SessionManager } from '../../pi/node_modules/@earendil-works/pi-coding-agent/dist/index.js';
import { getModel } from '../../pi/node_modules/@earendil-works/pi-ai/dist/compat.js';
import { createAssistantMessageEventStream } from '../../pi/node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js';
import { createKernel } from '../src/core/kernel.mjs';
import { mountPluginHmr } from '../src/core/plugin-hmr.mjs';
import { mountAIOS } from '../../../packages/agent-bus/agent/index.mjs';
import { digest, counterSource } from './hmr-fixture.mjs';

// The real installed Pi SDK executes commands and dynamic tools. Only the model
// stream is stubbed; this test makes no network/provider calls or app updates.
test('real SDK bus + HMR honors future wildcard authorization, rollback, and unload across model turns', async () => {
  const originalArgv = [...process.argv]; process.argv.push('--tools=read,bus,hmr_counter_*');
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'f-hmr-sdk-'));
  const agentDir = path.join(cwd, 'agent'); await mkdir(agentDir);
  let session, kernel, modelCalls = 0, requestTool = false;
  const candidate = async (version, extra) => {
    const source = counterSource(version, extra), sha = digest(source);
    const dir = path.join(cwd, '.f/plugins/counter'); await mkdir(dir, {recursive:true});
    const file = path.join(dir, sha + '.mjs'); await writeFile(file, source);
    return {sha, file};
  };
  try {
    const settings = SettingsManager.inMemory({compaction:{enabled:false},retry:{enabled:false},cacheWarming:'off'});
    const resources = new DefaultResourceLoader({cwd,agentDir,settingsManager:settings,
      noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,
      extensionFactories:[async pi => {kernel = createKernel(pi); await mountAIOS(kernel, {dataRoot:path.join(cwd,'bus'),enabled:false}); await mountPluginHmr(kernel);} ]});
    await resources.reload();
    const modelRuntime = await ModelRuntime.create({authPath:path.join(agentDir,'auth.json'),modelsPath:path.join(agentDir,'models.json')});
    await modelRuntime.setRuntimeApiKey('anthropic','local-test-not-a-real-key');
    const model = getModel('anthropic','claude-sonnet-4-5');
    ({session} = await createAgentSession({cwd,agentDir,model,modelRuntime,resourceLoader:resources,
      tools:['read','bus','hmr_counter_echo'],
      sessionManager:SessionManager.inMemory(cwd),settingsManager:settings}));
    await session.bindExtensions({});
    const localStream = () => {
      modelCalls++;
      const use = requestTool; requestTool = false;
      const message = {role:'assistant',api:model.api,provider:model.provider,model:model.id,
        content:use ? [{type:'toolCall',id:'sdk-hmr-' + modelCalls,name:'hmr_counter_echo',arguments:{message:'live'}}] : [{type:'text',text:'done'}],
        usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},
        stopReason:use ? 'toolUse' : 'stop',timestamp:Date.now()};
      const stream = createAssistantMessageEventStream();
      stream.push({type:'done',reason:message.stopReason,message}); stream.end(); return stream;
    };
    session.agent.streamFunction = localStream;
    modelRuntime.streamSimple = localStream;
    const v1 = await candidate('v1');
    await session.prompt(`/hmr load counter ${v1.sha} ${v1.file}`);
    assert.equal(modelCalls,0,'loading/tests must not ask an LLM');
    assert.ok(session.getActiveToolNames().includes('hmr_counter_echo'));
    requestTool = true; await session.prompt('Invoke the test tool.');
    const result = () => session.messages.filter(m=>m.role==='toolResult'&&m.toolName==='hmr_counter_echo').at(-1);
    assert.equal(result().content[0].text,'v1:live');
    const v2 = await candidate('v2');
    await session.prompt(`/hmr load counter ${v2.sha} ${v2.file}`);
    requestTool = true; await session.prompt('Invoke the replacement tool.');
    assert.equal(result().content[0].text,'v2:live');
    assert.equal(result().isError,false);
    const bad = await candidate('bad','test-failure');
    await session.prompt(`/hmr load counter ${bad.sha} ${bad.file}`);
    assert.equal(kernel.pluginHmr.status()[0].sha256,v2.sha);
    requestTool = true; await session.prompt('Invoke after rollback.');
    assert.equal(result().content[0].text,'v2:live');
    assert.equal(result().isError,false);
    await kernel.bus.choose(kernel.bus.context,['hmr_counter_echo'],false);
    await session.prompt(`/hmr load counter ${bad.sha} ${bad.file}`);
    assert.ok(!session.getActiveToolNames().includes('hmr_counter_echo'),'failed replacement preserves prior disabled bus state');
    await session.prompt('/hmr unload counter');
    assert.ok(!session.getActiveToolNames().includes('hmr_counter_echo'));
    const registered = session.getAllTools().find(tool=>tool.name==='hmr_counter_echo');
    assert.equal(registered.exposure,'hidden','unloaded tools must not remain nested-callable');
    const excludedSource=counterSource('excluded').replace("id: 'counter'", "id: 'other'").replaceAll('hmr_counter_echo','hmr_other_echo');
    const excludedDir=path.join(cwd,'.f/plugins/other');await mkdir(excludedDir,{recursive:true});
    const excludedFile=path.join(excludedDir,'v1.mjs');await writeFile(excludedFile,excludedSource);
    await session.prompt(`/hmr load other ${digest(excludedSource)} ${excludedFile}`);
    assert.equal(kernel.pluginHmr.status().length,0,'host-excluded tools must not be reported accepted');
    assert.ok(!session.getActiveToolNames().includes('hmr_other_echo'));
    assert.ok(session.sessionManager.getBranch().some(entry=>entry.type==='custom'&&entry.customType==='f-plugin-hmr'&&entry.data?.state==='rejected'&&entry.data.error.includes('allowlist')));
    assert.equal(modelCalls,6,'only the three explicit normal prompts should use the local model stub');
    assert.ok(session.sessionManager.getBranch().some(entry=>entry.type==='custom'&&entry.customType==='f-plugin-hmr'));
  } finally {
    process.argv.splice(0,process.argv.length,...originalArgv);
    session?.dispose();
    await kernel?.fiber.dispose();
    await rm(cwd,{recursive:true,force:true});
  }
});
