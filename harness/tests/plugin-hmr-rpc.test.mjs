import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,chmod,rm} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {ChildRPC} from '../src/subagent/rpc.mjs';
import {counterSource,digest} from './hmr-fixture.mjs';

// Real CLI/RPC (no model calls): --tools is a strict host allowlist, not merely
// an initial active set. Commands return handled and must not await settlement.
test('real CLI/RPC explicitly authorizes dynamic tools and rejects a host-excluded candidate', {timeout:30000}, async () => {
 const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
 const cwd=await mkdtemp(path.join(os.tmpdir(),'f-hmr-rpc-'));
 let child;
 const events=[];
 try {
  const agent=path.join(cwd,'agent');await mkdir(agent);
  const cli=path.join(cwd,'pi');
  const node=path.join(root,'pi/runtime/node/bin/node'),entry=path.join(root,'pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js');
  await writeFile(cli,`#!/bin/sh\nexec '${node}' '${entry}' "$@"\n`);await chmod(cli,0o755);
  const extension=path.join(cwd,'hmr.ts');
  await writeFile(extension,`import {createKernel} from ${JSON.stringify(path.join(root,'harness/src/core/kernel.mjs'))};
import {mountPluginHmr} from ${JSON.stringify(path.join(root,'harness/src/core/plugin-hmr.mjs'))};
export default async function(pi){await mountPluginHmr(createKernel(pi));pi.registerCommand('hmr-probe',{description:'Test-only read-only tool visibility',handler:async(_,ctx)=>ctx.ui.notify('PROBE:'+JSON.stringify(pi.getActiveTools()),'info')});}`);
  child=new ChildRPC(cli,['--session',path.join(cwd,'session.jsonl'),'--provider','anthropic','--model','claude-sonnet-4-5','--tools','read,hmr_counter_echo','--extension',extension],{
   cwd,env:{...process.env,PI_CODING_AGENT_DIR:agent},onEvent:event=>events.push(event)});
  await child.request('get_state');
  const command=async message=>{
   const start=events.length;
   assert.equal((await child.request('prompt',{message})).disposition,'handled');
   return events.slice(start).filter(e=>e.type==='extension_ui_request'&&e.method==='notify');
  };
  const candidate=async(id,source)=>{
   const dir=path.join(cwd,'.f/plugins',id);await mkdir(dir,{recursive:true});
   const file=path.join(dir,'v1.mjs');await writeFile(file,source);
   return `/hmr load ${id} ${digest(source)} ${file}`;
  };
  const success=await command(await candidate('counter',counterSource('rpc')));
  assert.ok(success.some(e=>e.notifyType==='info'&&e.message.includes('"state":"accepted"')));
  const visible=await command('/hmr-probe');
  assert.ok(visible.some(e=>JSON.parse(e.message.slice(6)).includes('hmr_counter_echo')));
  const excluded=counterSource('excluded').replace("id: 'counter'","id: 'other'").replaceAll('hmr_counter_echo','hmr_other_echo');
  const failure=await command(await candidate('other',excluded));
  assert.ok(failure.some(e=>e.notifyType==='error'&&e.message.includes('allowlist')));
  const status=await command('/hmr status');
  const records=JSON.parse(status.find(e=>e.message.startsWith('Agent HMR: ')).message.slice(11));
  assert.deepEqual(records.map(r=>r.id),['counter']);
  await command('/hmr unload counter');
  assert.ok((await command('/hmr-probe')).some(e=>!JSON.parse(e.message.slice(6)).includes('hmr_counter_echo')));
  assert.equal(events.filter(e=>e.type==='agent_start').length,0,'HMR commands must not call any model');
 } finally {await child?.dispose();await rm(cwd,{recursive:true,force:true});}
});
