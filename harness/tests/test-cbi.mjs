/** Real paid-model integration. Uses temporary sessions, files and boards only. */
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm, readdir } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { ChildRPC } from '../src/subagent/rpc.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const reportPath=process.argv[process.argv.indexOf('--report')+1];
if(!process.argv.includes('--report'))throw new Error('--report is required');
const temporary=await mkdtemp(path.join(os.tmpdir(),'f-cbi-integration-'));
const project=path.join(temporary,'project'),board=path.join(temporary,'board');
await mkdir(project);await mkdir(board);
const report={provider:'cbi',model:'deepseek-v4.1-flash',startedAt:new Date().toISOString(),stages:[],passed:false};
const tools=['read','write','edit','bash','ls','find','grep','skill','subagent','list_agents','send_message','interrupt_agent','workflow','workflow_control','whiteboard_create','whiteboard_read','whiteboard_edit','hmr_hot_echo','resource_scope'];
let stage,child;
const events=[];
const timer=setTimeout(()=>{report.timeout=true;void child?.dispose()},480000);
function childResults() { return events.filter(e => e.type === 'message_start' && e.message?.customType === 'subagent-result').map(e => { const c=e.message.content; return JSON.parse(typeof c === 'string' ? c : c.map(v=>v.text??'').join('')); }); }
async function hmrCommand(message,{expectError=false}={}){
 const start=events.length;
 const accepted=await child.request('prompt',{message});
 assert.equal(accepted?.disposition,'handled','HMR commands must finish without starting a model run');
 const notices=events.slice(start).filter(e=>e.type==='extension_ui_request'&&e.method==='notify'&&e.message?.startsWith('Agent HMR'));
 (report.hmrCommands??=[]).push({message,notifications:notices.map(e=>({type:e.notifyType,message:e.message}))});
 assert.ok(notices.length,'HMR command must report its actual outcome');
 const errors=notices.filter(e=>e.notifyType==='error');
 if(expectError)assert.ok(errors.length,'Expected rejected HMR candidate');
 else assert.equal(errors.length,0,errors.map(e=>e.message).join('; '));
}
async function run(name,prompt,required=[],options={}){
 if(stage){stage.passed=true;console.log('PASS:',stage.name);}
 stage={name,tools:[],passed:false};report.stages.push(stage);
 const start=events.length;
 const value=await child.prompt(prompt+'\nThis is an isolated automated acceptance test. Follow the requested calls and reply briefly when done. Do not run unrelated commands.');
 assert.equal(value.stopReason,'completed',`${name}: ${value.stopReason}`);
 const calls=events.slice(start).filter(e=>e.type==='tool_execution_end');
 stage.childResults=childResults();
 stage.calls=events.slice(start).filter(e=>e.type==='tool_execution_start'&&['subagent','send_message'].includes(e.toolName)).map(e=>({name:e.toolName,args:e.args}));
 stage.tools=calls.map(e=>({name:e.toolName,isError:!!e.isError}));
 // Extra exploratory commands are tolerated only where the stage reads recorded evidence.
 if(!options.ignoreExtraErrors)assert.equal(calls.filter(e=>e.isError).length,0,`${name}: tool error`);
 for(const tool of required)assert.ok(calls.some(e=>e.toolName===tool&&!e.isError),`${name}: missing ${tool}`);
 return calls;
}
try{
 child=new ChildRPC(path.join(root,'pi/bin/pi'),['--session',path.join(temporary,'root.jsonl'),'--provider','cbi','--model',report.model,'--thinking','off','--tools',tools.join(',')],{
  cwd:project,env:{...process.env,F_BOARD_DIR:board,F_SOURCE_ROOT:root,F_DISABLED_PLUGINS:''},onEvent:event=>events.push(event)});
 const state=await child.request('get_state');assert.equal(state.model.provider,'cbi');assert.equal(state.model.id,report.model);
 await run('files-skills-board',`Perform these real tool calls in order:
1 skill(name="f-plugins").
2 write note.txt with exact text ALPHA_F_TEST.
3 read note.txt; edit ALPHA_F_TEST to BETA_F_TEST.
4 bash command "printf SHELL_F_TEST > shell.txt".
5 ls this directory, find pattern "note.txt", grep pattern BETA_F_TEST.
6 resource_scope action claim with rectangle {x:0,y:0,width:3000,height:3000} and purpose "acceptance diagram"; use its returned id as lease_id for both following whiteboard tools. whiteboard_create with mode replace, two nodes ids a,b labels START_F_TEST and END_F_TEST and edge a->b.
7 whiteboard_edit rename node b to FINAL_F_TEST (use its documented schema).
8 whiteboard_read, then reply FILES_OK.`,['skill','write','read','edit','bash','ls','find','grep','whiteboard_create','whiteboard_edit','whiteboard_read','resource_scope']);
 // A real model may keep or add one trailing newline when editing; the edit itself must replace the text.
 assert.equal((await readFile(path.join(project,'note.txt'),'utf8')).replace(/\r?\n$/,''),'BETA_F_TEST');
 assert.equal(await readFile(path.join(project,'shell.txt'),'utf8'),'SHELL_F_TEST');
 const scene=JSON.parse(await readFile(path.join(board,'scene.json'),'utf8'));assert.ok(scene.elements.some(e=>e.text==='FINAL_F_TEST'));
 // HMR runs only this candidate's own local acceptance; the paid model then
 // calls the actual newly registered tool through the frozen candidate Harness.
 const hmrDirectory=path.join(project,'.f/plugins/hot');await mkdir(hmrDirectory,{recursive:true});
 const hotCandidate=async(version,fail=false)=>{
  const source=`export default {apiVersion:1,id:'hot',apply(api){api.tools.register({name:'hmr_hot_echo',label:'Hot Echo',description:'Echo with the current HMR revision',parameters:{type:'object',properties:{message:{type:'string'}},required:['message'],additionalProperties:false},async execute(_id,args){return {content:[{type:'text',text:'${version}:'+args.message}],details:{version:'${version}'}};}});},async test(t){const result=await t.invoke('hmr_hot_echo',{message:'probe'});t.assert(result.content[0].text==='${version}:probe');${fail?"t.assert(false,'EXPECTED_HMR_REJECTION');":''}return [{name:'revision-echo',passed:true}];}};`;
  const file=path.join(hmrDirectory,version+'.mjs');await writeFile(file,source);
  return {file,sha:createHash('sha256').update(source).digest('hex')};
 };
 const hot1=await hotCandidate('v1');await hmrCommand(`/hmr load hot ${hot1.sha} ${hot1.file}`);
 const hot1Calls=await run('hmr-first-plugin','Call hmr_hot_echo exactly once with exact arguments {"message":"CBI_HMR"}, then reply briefly.',['hmr_hot_echo']);
 stage.hmrResult={sha256:hot1.sha,toolResult:hot1Calls.find(e=>e.toolName==='hmr_hot_echo').result};
 assert.equal(stage.hmrResult.toolResult.content[0].text,'v1:CBI_HMR');
 const hot2=await hotCandidate('v2');await hmrCommand(`/hmr load hot ${hot2.sha} ${hot2.file}`);
 const hot2Calls=await run('hmr-replacement-plugin','Call hmr_hot_echo exactly once with exact arguments {"message":"CBI_HMR"}, then reply briefly.',['hmr_hot_echo']);
 stage.hmrResult={sha256:hot2.sha,toolResult:hot2Calls.find(e=>e.toolName==='hmr_hot_echo').result};
 assert.equal(stage.hmrResult.toolResult.content[0].text,'v2:CBI_HMR');
 const badHot=await hotCandidate('rejected',true),hmrStart=events.length;
 await hmrCommand(`/hmr load hot ${badHot.sha} ${badHot.file}`,{expectError:true});
 const hmrRejected=events.slice(hmrStart).some(e=>e.type==='extension_ui_request'&&e.notifyType==='error'&&e.message?.includes('EXPECTED_HMR_REJECTION'));
 assert.ok(hmrRejected,'bad HMR candidate must explicitly report failed acceptance');
 const rollbackCalls=await run('hmr-rejected-plugin-rollback','Call hmr_hot_echo exactly once with exact arguments {"message":"CBI_HMR"}, then reply briefly.',['hmr_hot_echo']);
 stage.expectedHmrRejection=hmrRejected;
 stage.hmrResult={sha256:hot2.sha,toolResult:rollbackCalls.find(e=>e.toolName==='hmr_hot_echo').result};
 assert.equal(stage.hmrResult.toolResult.content[0].text,'v2:CBI_HMR');
 await hmrCommand('/hmr unload hot');
 const statusStart=events.length;await hmrCommand('/hmr status');
 assert.ok(events.slice(statusStart).some(e=>e.type==='extension_ui_request'&&e.message==='Agent HMR: []'),'HMR unload must leave no managed plugin');
 await run('spawn-parent-relay',`Use subagent provider spawn, label probe, with this exact task: "Use send_message with childId parent and message RELAY_F_TEST, then read note.txt in the inherited project and reply CHILD_F_TEST." Then list_agents. Allow its completion message to arrive before finishing.`,['subagent','list_agents']);
 assert.ok(childResults().some(r=>r.output.some(c=>c.text?.includes('CHILD_F_TEST'))),'spawn output missing');
 assert.ok(events.some(e=>e.type==='message_start' && e.message?.customType==='agent-message'),'child relay did not reach parent');
 const owners=await readdir(path.join(board,'harness/subagents'));
 const catalog=JSON.parse(await readFile(path.join(board,'harness/subagents',owners[0],'catalog.json'),'utf8'));
 const id=catalog.find(e=>e.label==='probe')?.childId;assert.ok(id);
 await run('cold-resume',`Call send_message with childId ${id} and message "Reply RESUMED_F_TEST without other actions." Wait for the completion.`,['send_message']);
 assert.ok(childResults().some(r=>r.output.some(c=>c.text?.includes('RESUMED_F_TEST'))),'resume output missing');
 await run('fork-completed-history',`Call subagent with provider fork and label fork-check. Task: "From the completed conversation history, identify the edited note.txt text. Reply FORK_F_TEST followed by that exact text. Do not call tools." Wait for its completion.`,['subagent']);
 assert.ok(childResults().some(r=>r.output.some(c=>c.text?.includes('FORK_F_TEST')&&c.text?.includes('BETA_F_TEST'))),'fork lost completed history');
 const workflowCalls=await run('foreground-workflow',`The user explicitly requests a workflow. Call workflow with meta {name:"acceptance",description:"two independent agents"}, args {tag:"WORKFLOW_F_TEST"}, script:
phase('parallel'); const outputs=await parallel([()=>agent('Reply LEFT_F_TEST only'),()=>agent('Reply RIGHT_F_TEST only')]); const numbers=await pipeline([1,2],n=>n+1,n=>n*2); return {tag:args.tag,outputs,numbers};`,['workflow']);
 const workflow=workflowCalls.find(e=>e.toolName==='workflow').result.details;
 assert.equal(workflow.result.tag,'WORKFLOW_F_TEST');assert.equal(workflow.agentsStarted,2);assert.deepEqual(workflow.result.numbers,[4,6]);
 const bgCalls=await run('background-workflow-cancel',`Call workflow with run_in_background true, meta {name:"cancel-test",description:"test cancellation"}, and script "phase('waiting'); await new Promise(()=>{}); return 'UNREACHABLE';". Immediately call workflow_control action status for its runId, then workflow_control action cancel for the same id.`,['workflow','workflow_control']);
 assert.ok(bgCalls.some(e=>e.toolName==='workflow_control'&&e.result.details.state==='cancelled'),'background run was not cancelled');
 await run('interrupt-owned-child',`Call subagent provider spawn label cancel-child with prompt "Run bash command sleep 600, then reply TOO_LATE." Immediately call interrupt_agent on the returned childId, then list_agents.`,['subagent','interrupt_agent','list_agents']);
 if (process.argv.includes('--native-report')) {
  const nativePath=path.resolve(process.argv[process.argv.indexOf('--native-report')+1]);
  const native=JSON.parse(await readFile(nativePath,'utf8'));assert.ok(native.suites.every(s=>s.passed));
  await run('native-regression-review',`Use read on ${nativePath} and nothing else: do not run bash, grep or any other tool. Verify every recorded native regression suite passed, then summarize the actual test evidence briefly; do not claim manual UI coverage.`,['read'],{ignoreExtraErrors:true});
 }
 stage.passed=true;console.log('PASS:',stage.name);report.passed=true;
}catch(error){if(stage)stage.passed=false;report.error=error.message;throw error;}
finally{
 clearTimeout(timer);await child?.dispose();report.completedAt=new Date().toISOString();
 await mkdir(path.dirname(path.resolve(reportPath)),{recursive:true});await writeFile(reportPath,JSON.stringify(report,null,2)+'\n');
 if (!report.passed && process.argv.includes('--keep-failed-fixture')) { report.fixture=temporary; await writeFile(reportPath,JSON.stringify(report,null,2)+'\n'); }
 else await rm(temporary,{recursive:true,force:true});
}
