import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, chmod, symlink } from 'node:fs/promises';
import { randomBytes, createDecipheriv } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import os from 'node:os';
import path from 'node:path';
import { browserRequest } from '../src/browser/transport.mjs';
import { mountBrowser } from '../src/browser/index.mjs';
import { createKernel } from '../src/core/kernel.mjs';
async function fixture(t) { const root=await mkdtemp(path.join(os.tmpdir(),'f-browser-test-'));t.after(()=>rm(root,{recursive:true,force:true}));await chmod(root,0o700);for(const n of ['requests','responses'])await mkdir(path.join(root,n),{mode:0o700});const key=randomBytes(32),nonce='fixture-instance';await writeFile(path.join(root,'endpoint.json'),JSON.stringify({version:1,pid:process.pid,key:key.toString('base64'),nonce}),{mode:0o600});return{root,key,nonce}; }
test('browser IPC encrypts site credentials, validates response and removes transient messages',async t=> {
 const {root,key,nonce}=await fixture(t);let seen=false,stopped=false;const processed=new Set();
 const polling=(async()=> { while(!stopped) {
  for(const file of await readdir(path.join(root,'requests'))) {
   if(!file.endsWith('.json')||processed.has(file))continue;processed.add(file);const text=await readFile(path.join(root,'requests',file),'utf8');assert(!text.includes('SECRET_FIXTURE'));
   const v=JSON.parse(text),bytes=Buffer.from(v.ciphertext,'base64');const d=createDecipheriv('aes-256-gcm',key,bytes.subarray(0,12));d.setAAD(Buffer.from(nonce));d.setAuthTag(bytes.subarray(-16));
   const input=JSON.parse(Buffer.concat([d.update(bytes.subarray(12,-16)),d.final()]));assert.equal(input.fixture,'SECRET_FIXTURE');seen=true;
   await writeFile(path.join(root,'responses',file),JSON.stringify({ok:true,value:{accepted:true}}),{mode:0o600});
  }
  await new Promise(resolve=>setTimeout(resolve,10));
 } })();
 // Observe responder failures immediately and drain its I/O before fixture cleanup.
 polling.catch(()=>{});
 try {
  assert.deepEqual(await Promise.race([browserRequest({action:'state',fixture:'SECRET_FIXTURE'},undefined,{root,timeout:1000}),polling]),{accepted:true});assert(seen);
  assert.deepEqual(await readdir(path.join(root,'requests')),[]);assert.deepEqual(await readdir(path.join(root,'responses')),[]);
 } finally { stopped=true;await polling; }
});
test('browser transport rejects unsafe endpoint permissions, missing F, cancellation and symlinks',async t=> {
 const {root}=await fixture(t);await chmod(path.join(root,'endpoint.json'),0o644);await assert.rejects(browserRequest({action:'state'},undefined,{root}),/连接信息/);await chmod(path.join(root,'endpoint.json'),0o600);
 await assert.rejects(browserRequest({action:'state'},AbortSignal.abort(),{root}),/abort/i);
 await assert.rejects(browserRequest({action:'state'},undefined,{root,timeout:10}),/可能已执行/);assert.deepEqual(await readdir(path.join(root,'requests')),[]);
 const alias=path.join(root,'alias');await symlink(root,alias);await assert.rejects(browserRequest({action:'state'},undefined,{root:alias}),/权限/);
});
test('browser Cordis capability has bounded explicit actions and unloads with its plugin',async()=> {
 const tools=new Map(),active=new Set();const ctx=createKernel({registerTool:t=>{tools.set(t.name,t);active.add(t.name);},getActiveTools:()=>[...active],setActiveTools:names=>{active.clear();names.forEach(n=>active.add(n));}});
 const calls=[];await mountBrowser(ctx,{request:async input=>{calls.push(input);return{title:'fixture'};}});
 const tool=tools.get('browser');assert.equal((await tool.execute('',{action:'read'})).details.title,'fixture');assert.deepEqual(calls,[{action:'read'}]);
 for(const action of ['tabs','newTab','selectTab','closeTab']) {
  const input={action,tabId:'fixture-tab'};
  assert.equal((await tool.execute('',input)).details.title,'fixture');assert.deepEqual(calls.at(-1),input);
 }
 await assert.rejects(tool.execute('',{action:'importSession'}),/不支持/);await assert.rejects(tool.execute('',{action:'evaluate'}),/不支持/);
 assert(!tool.parameters.properties.action.enum.includes('cookies'));await ctx.fiber.dispose();assert(!active.has('browser'));assert.throws(()=>tool.execute('',{action:'read'}),/unloaded/);
});
test('Chrome bridge installer pins one extension and requires per-site permissions without Chrome profile copying',async t=> {
 const {root}=await fixture(t),id='a'.repeat(32),dir=path.join(root,'bridge'),hosts=path.join(root,'hosts');
 const script=path.resolve('harness/src/browser/install-bridge.mjs');await promisify(execFile)(process.execPath,[script,'--node',process.execPath,'--extension-id',id],{env:{...process.env,F_BROWSER_BRIDGE_DIRECTORY:dir,F_CHROME_NATIVE_HOSTS:hosts}});
 const manifest=JSON.parse(await readFile(path.join(hosts,'local.f.browser.json')));assert.deepEqual(manifest.allowed_origins,[`chrome-extension://${id}/`]);
 const ext=JSON.parse(await readFile(path.join(dir,'extension/manifest.json')));assert(!ext.host_permissions);assert.deepEqual(ext.optional_host_permissions,['https://*/*']);assert(ext.permissions.includes('cookies')&&ext.permissions.includes('nativeMessaging'));
 const body=await readFile(path.join(dir,'extension/background.js'),'utf8');assert(!/Login Data|Cookies\.sqlite|Safe Storage/.test(body));assert.match(body,/permissions.contains/);
});
test('Chrome native host uses framed messages, verifies extension identity and only accepts session import',async t=> {
 const {root}=await fixture(t),id='b'.repeat(32);await writeFile(path.join(root,'native-config.json'),JSON.stringify({extensionID:id}),{mode:0o600});
 async function host(origin,input) {
  const child=spawn(process.execPath,[path.resolve('harness/src/browser/native-host.mjs'),origin],{env:{...process.env,F_BROWSER_BRIDGE_DIRECTORY:root,F_BROWSER_DIRECTORY:root},stdio:['pipe','pipe','pipe']});
  const bytes=Buffer.from(JSON.stringify(input)),head=Buffer.alloc(4);head.writeUInt32LE(bytes.length);const chunks=[];child.stdout.on('data',d=>chunks.push(d));child.stdin.end(Buffer.concat([head,bytes]));
  await new Promise((resolve,reject)=>{child.on('exit',resolve);child.on('error',reject);});const data=Buffer.concat(chunks);assert.equal(data.readUInt32LE(),data.length-4);return JSON.parse(data.subarray(4));
 }
 assert.match((await host('chrome-extension://'+'c'.repeat(32)+'/',{action:'importSession'})).error,/身份/);
 assert.match((await host(`chrome-extension://${id}/`,{action:'read'})).error,/仅允许/);
 assert.deepEqual(await readdir(path.join(root,'requests')),[]);
});
test('Chrome refresh has one active cycle and never accumulates native-host requests while F is slow',async()=> {
 const original=globalThis.chrome;let alarm,finish,calls=0;
 globalThis.chrome={permissions:{contains:async()=>true},cookies:{getAll:async()=>[]},tabs:{query:async()=>[]},storage:{local:{get:async()=>({sites:{'https://www.alphaxiv.org':true}})}},runtime:{onMessage:{addListener(){}},sendNativeMessage:async()=>{calls++;return new Promise(resolve=>{finish=()=>resolve({ok:true,value:{cookies:0}});});}},alarms:{onAlarm:{addListener:fn=>{alarm=fn;}}}};
 try {
  await import('../src/browser/chrome-extension/background.js?fixture=single-flight');
  const first=alarm({name:'refresh'});for(let i=0;i<30&&!finish;i++)await new Promise(resolve=>setTimeout(resolve,5));
  await alarm({name:'refresh'});assert.equal(calls,1);finish();await first;
 }finally{globalThis.chrome=original;}
});
