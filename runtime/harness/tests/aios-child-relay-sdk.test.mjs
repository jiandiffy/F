import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { mkdtemp, mkdir, readFile, readdir, rm } from 'node:fs/promises';
import { createAgentSession, ModelRuntime, DefaultResourceLoader, SettingsManager, SessionManager } from '../../pi/node_modules/@earendil-works/pi-coding-agent/dist/index.js';
import { getModel } from '../../pi/node_modules/@earendil-works/pi-ai/dist/compat.js';
import { createAssistantMessageEventStream } from '../../pi/node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js';
import { getCurrentTools } from '../../pi/node_modules/@earendil-works/pi-ai/dist/utils/transcript.js';
import { createKernel } from '../src/core/kernel.mjs';
import { mountSubagents } from '../../../packages/side-agent/agent/index.mjs';
import { mountAIOS } from '../../../packages/agent-bus/agent/index.mjs';

// Actual installed SDK/tool execution; only the model stream is deterministic.
// The test never writes a relay file itself and never asks a shell to simulate it.
test('managed child declares and actually calls parent send_message without activating recursive delegation',async()=>{
 const cwd=await mkdtemp(path.join(os.tmpdir(),'f-child-relay-')),agentDir=path.join(cwd,'agent'),relay=path.join(cwd,'relay');
 await Promise.all([mkdir(agentDir),mkdir(relay)]);
 const environment={F_AGENT_DEPTH:'1',F_AGENT_ID:'child',F_PARENT_AGENT_ID:'parent',F_AGENT_RELAY_DIR:relay};
 const saved=Object.fromEntries(Object.keys(environment).map(key=>[key,process.env[key]]));Object.assign(process.env,environment);
 let session,kernel,calls=0;const declarations=[];
 try{
  const settings=SettingsManager.inMemory({compaction:{enabled:false},retry:{enabled:false},cacheWarming:'off'});
  const resources=new DefaultResourceLoader({cwd,agentDir,settingsManager:settings,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,
   extensionFactories:[async pi=>{
    kernel=createKernel(pi);
    await mountSubagents(kernel,{cli:process.execPath,dataRoot:path.join(cwd,'children'),maxDepth:1,maxConcurrentAgents:4,deliver(){}});
    await mountAIOS(kernel,{dataRoot:path.join(cwd,'bus')});
   }]});
  await resources.reload();
  const runtime=await ModelRuntime.create({authPath:path.join(agentDir,'auth.json'),modelsPath:path.join(agentDir,'models.json')});await runtime.setRuntimeApiKey('anthropic','local-test-not-a-real-key');
  const model=getModel('anthropic','claude-sonnet-4-5');
  ({session}=await createAgentSession({cwd,agentDir,model,modelRuntime:runtime,resourceLoader:resources,sessionManager:SessionManager.inMemory(cwd),settingsManager:settings}));await session.bindExtensions({});
  const stream=(_model,context)=>{
   declarations.push(getCurrentTools(context.messages).map(tool=>tool.name));
   const use=calls++===0;
   const message={role:'assistant',api:model.api,provider:model.provider,model:model.id,content:use?[{type:'toolCall',id:'real-parent-relay',name:'send_message',arguments:{childId:'parent',message:'REAL_TOOL_RELAY'}}]:[{type:'text',text:'done'}],usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:use?'toolUse':'stop',timestamp:Date.now()};
   const output=createAssistantMessageEventStream();output.push({type:'done',reason:message.stopReason,message});output.end();return output;
  };
  session.agent.streamFunction=stream;runtime.streamSimple=stream;
  await session.prompt('Use send_message to report to your parent.');
  assert.ok(declarations[0].includes('send_message'),'parent messaging must be declared before the first child model call');
  for(const tool of ['subagent','list_agents','interrupt_agent','workflow','goal_flow'])assert.ok(!declarations[0].includes(tool),tool+' must remain hidden');
  const results=session.messages.filter(message=>message.role==='toolResult');assert.equal(results.length,1);assert.equal(results[0].toolName,'send_message');assert.equal(results[0].isError,false);assert.equal(results[0].details.recipient,'parent');
  const files=await readdir(relay);assert.equal(files.length,1);assert.deepEqual(JSON.parse(await readFile(path.join(relay,files[0]),'utf8')),{text:'REAL_TOOL_RELAY'});
  assert.equal(kernel.bus.catalog().find(group=>group.name==='core').tools.includes('send_message'),true);
 }finally{session?.dispose();await kernel?.fiber.dispose();for(const[key,value]of Object.entries(saved)){if(value===undefined)delete process.env[key];else process.env[key]=value;}await rm(cwd,{recursive:true,force:true});}
});
