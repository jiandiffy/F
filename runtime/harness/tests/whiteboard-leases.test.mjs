import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import extension from '../../pi/agent/modules/fy-whiteboard.ts';
import {leasesFor} from '../../../packages/agent-bus/agent/leases.mjs';

test('concurrent diagrams preserve each other; out-of-scope deletes and stale writes are atomic', async () => {
  const dir=await mkdtemp(path.join(os.tmpdir(),'f-board-leases-')), previous=process.env.F_BOARD_DIR;
  process.env.F_BOARD_DIR=dir;
  const registered=new Map(); extension({registerTool: tool=>registered.set(tool.name,tool)});
  const context=id=>({cwd:dir,sessionManager:{getSessionId:()=>id}});
  const call=(name,params,ctx)=>registered.get(name).execute('',params,undefined,undefined,ctx);
  const a=context('writer-a'),b=context('writer-b');
  try {
    const left=await leasesFor(a).claim({owner:'writer-a',rectangle:{x:0,y:0,width:1000,height:1000}});
    const right=await leasesFor(b).claim({owner:'writer-b',rectangle:{x:1100,y:0,width:1000,height:1000}});
    await Promise.all([
      call('whiteboard_create',{lease_id:left.id,nodes:[{id:'left',label:'LEFT'}]},a),
      call('whiteboard_create',{lease_id:right.id,nodes:[{id:'right',label:'RIGHT'}]},b),
    ]);
    const file=path.join(dir,'scene.json'), original=await readFile(file,'utf8');
    assert.match(original,/LEFT/); assert.match(original,/RIGHT/);
    await assert.rejects(call('whiteboard_edit',{lease_id:left.id,operations:[{op:'delete',id:'right'}]},a),/reserved rectangle/);
    assert.equal(await readFile(file,'utf8'),original);
    await assert.rejects(call('whiteboard_edit',{lease_id:left.id,expected_revision:0,operations:[{op:'update_node',id:'left',label:'STALE'}]},a),/revision changed/);
    assert.equal(await readFile(file,'utf8'),original);
    await assert.rejects(call('whiteboard_create',{lease_id:left.id,mode:'replace',nodes:[{label:'ERASE'}]},a),/reserved rectangle/);
    assert.equal(await readFile(file,'utf8'),original);
    await assert.rejects(call('whiteboard_edit',{lease_id:right.id,operations:[{op:'clear'}]},a),/Claim a board rectangle/);
    await call('whiteboard_edit',{lease_id:left.id,operations:[{op:'update_node',id:'left',label:'UPDATED'}]},a);
    const after=JSON.parse(await readFile(file,'utf8'));
    assert.ok(after.elements.some(e=>e.text==='UPDATED'));
    assert.ok(after.elements.some(e=>e.text==='RIGHT'));
  } finally {
    if(previous===undefined) delete process.env.F_BOARD_DIR; else process.env.F_BOARD_DIR=previous;
    await rm(dir,{recursive:true,force:true});
  }
});
