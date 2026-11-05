import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import os from 'node:os';import path from 'node:path';
import extension from '../../pi/agent/modules/fy-whiteboard.ts';
import {leasesFor} from '../../../packages/agent-bus/agent/leases.mjs';

test('corrupt or malformed board fails without replacing existing user data',async()=>{
 const dir=await mkdtemp(path.join(os.tmpdir(),'f-board-boundary-')),old=process.env.F_BOARD_DIR;
 process.env.F_BOARD_DIR=dir;const tools=new Map();extension({registerTool:t=>tools.set(t.name,t)});
 try{
  const ctx={cwd:dir,sessionManager:{getSessionId:()=> 'test-owner'}};
  const lease=await leasesFor(ctx).claim({owner:'test-owner',rectangle:{x:0,y:0,width:2000,height:2000}});
  const file=path.join(dir,'scene.json');await writeFile(file,'{corrupt');
  await assert.rejects(tools.get('whiteboard_read').execute('',{},undefined,undefined,{cwd:dir}));
  assert.equal(await readFile(file,'utf8'),'{corrupt');
  await writeFile(file,JSON.stringify({elements:'invalid'}));
  await assert.rejects(tools.get('whiteboard_create').execute('',{lease_id:lease.id,nodes:[{id:'a',label:'a'}]},undefined,undefined,ctx),/Invalid whiteboard scene/);
  assert.equal(JSON.parse(await readFile(file,'utf8')).elements,'invalid');
 }finally{if(old===undefined)delete process.env.F_BOARD_DIR;else process.env.F_BOARD_DIR=old;await rm(dir,{recursive:true,force:true});}
});
