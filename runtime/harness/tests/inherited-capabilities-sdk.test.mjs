import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { mkdtemp,mkdir,rm,writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createAgentSession,ModelRuntime,DefaultResourceLoader,SettingsManager,SessionManager } from '../../pi/node_modules/@earendil-works/pi-coding-agent/dist/index.js';
import { getModel } from '../../pi/node_modules/@earendil-works/pi-ai/dist/compat.js';
import { createAssistantMessageEventStream } from '../../pi/node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js';
import { getCurrentTools } from '../../pi/node_modules/@earendil-works/pi-ai/dist/utils/transcript.js';
import { fileURLToPath } from 'node:url';
import { startHarness } from '../src/index.mjs';

test('managed child receives mainline active capability schemas before its first SDK model request',async()=>{
 const cwd=await mkdtemp(path.join(os.tmpdir(),'f-capability-inheritance-')),agentDir=path.join(cwd,'agent');await mkdir(agentDir);
 const pluginPath=path.join(cwd,'.f/plugins/hot/v1.mjs');await mkdir(path.dirname(pluginPath),{recursive:true});
 const plugin="export default {apiVersion:1,id:'hot',apply(api){api.tools.register({name:'hmr_hot_echo',description:'Inherited fixture tool',parameters:{type:'object',properties:{},additionalProperties:false},async execute(){return {content:[{type:'text',text:'INHERITED_HOT'}]};}});},async test(t){t.assert((await t.invoke('hmr_hot_echo',{})).content[0].text==='INHERITED_HOT');return [{name:'inherited echo',passed:true}];}};";await writeFile(pluginPath,plugin);
 const environment={F_AGENT_DEPTH:'1',F_AGENT_ID:'fixture-child',F_SHARED_PROJECT:cwd,F_BOARD_DIR:path.join(cwd,'board'),F_CONVERSATION_DIR:path.join(cwd,'conversation'),F_INHERITED_CAPABILITIES:JSON.stringify(['versions','datasets']),F_INHERITED_HMR:JSON.stringify([{id:'hot',path:pluginPath,sha256:createHash('sha256').update(plugin).digest('hex')}]),F_DISABLED_PLUGINS:''};
 const saved=Object.fromEntries(Object.keys(environment).map(key=>[key,process.env[key]]));Object.assign(process.env,environment);
 let session,kernel;const declarations=[],errors=[];
 try{
  const settings=SettingsManager.inMemory({compaction:{enabled:false},retry:{enabled:false},cacheWarming:'off'});
  const resources=new DefaultResourceLoader({cwd,agentDir,settingsManager:settings,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,extensionFactories:[async pi=>{kernel=await startHarness(pi,{root:fileURLToPath(new URL('../../..',import.meta.url)),dataRoot:path.join(cwd,'children')});}]});await resources.reload();
  const runtime=await ModelRuntime.create({authPath:path.join(agentDir,'auth.json'),modelsPath:path.join(agentDir,'models.json')});await runtime.setRuntimeApiKey('anthropic','local-test-not-a-real-key');const model=getModel('anthropic','claude-sonnet-4-5');
  ({session}=await createAgentSession({cwd,agentDir,model,modelRuntime:runtime,resourceLoader:resources,sessionManager:SessionManager.inMemory(cwd),settingsManager:settings}));await session.bindExtensions({onError:error=>errors.push(error)});assert.deepEqual(errors,[]);
  const stream=(_model,context)=>{
   declarations.push(getCurrentTools(context.messages).map(t=>t.name));
   const message={role:'assistant',api:model.api,provider:model.provider,model:model.id,content:[{type:'text',text:'done'}],usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:Date.now()};const output=createAssistantMessageEventStream();output.push({type:'done',reason:'stop',message});output.end();return output;
  };session.agent.streamFunction=stream;runtime.streamSimple=stream;
  await session.prompt('Read-only schema inheritance check; no tools needed.');
  assert.ok(declarations[0].includes('project_version'));assert.ok(declarations[0].includes('dataset'));assert.ok(declarations[0].includes('hmr_hot_echo'));assert.equal(kernel.pluginHmr.status()[0].state,'active');assert.ok(!declarations[0].includes('goal_flow'));
 }finally{session?.dispose();await kernel?.fiber.dispose();for(const[k,v]of Object.entries(saved)){if(v===undefined)delete process.env[k];else process.env[k]=v;}await rm(cwd,{recursive:true,force:true});}
});
