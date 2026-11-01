import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, mkdir, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { ResourceLeases } from '../src/aios/leases.mjs';
async function fixture(t) { const root=await mkdtemp(path.join(os.tmpdir(),'f-leases-'));t.after(()=>rm(root,{recursive:true,force:true}));const project=path.join(root,'project');await mkdir(project);const options={directory:path.join(root,'leases'),project};return{root,project,options,a:new ResourceLeases(options),b:new ResourceLeases(options)}; }

test('parallel reservations permit exactly one conflicting writer and allow disjoint rectangles',async t=>{
 const {a,b}=await fixture(t);const rectangle={x:0,y:0,width:300,height:200};
 const claims=await Promise.allSettled(Array.from({length:24},(_,i)=>(i%2?a:b).claim({owner:'agent'+i,rectangle})));
 assert.equal(claims.filter(x=>x.status==='fulfilled').length,1);
 const lease=claims.find(x=>x.status==='fulfilled').value;
 const other=await b.claim({owner:'other',rectangle:{x:300,y:0,width:10,height:10}});
 await assert.rejects(b.assertBoard({owner:'other',leaseId:lease.id,rectangle}),/Claim/);
 await assert.rejects(b.assertBoard({owner:'other',leaseId:other.id,rectangle}),/exceeds/);
 await b.assertBoard({owner:'other',leaseId:other.id,rectangle:{x:302,y:2,width:2,height:2}});
});

test('file ranges conflict by ancestry, require ownership, pin releases, and transfer excludes parent',async t=>{
 const {a,b}=await fixture(t);const lease=await a.claim({owner:'parent',paths:['src']});
 await assert.rejects(b.claim({owner:'child',paths:['src/x.js']}),/conflict/);
 await assert.rejects(b.pinFile({owner:'other',file:'src/x.js'}),/another/);
 const token=await a.pinFile({owner:'parent',file:'src/x.js'});
 await assert.rejects(a.release({owner:'parent',leaseId:lease.id}),/in-flight/);
 await assert.rejects(a.transfer({owner:'parent',leaseId:lease.id,childId:'child'}),/in-flight/);
 await a.unpin(token);await a.transfer({owner:'parent',leaseId:lease.id,childId:'child'});
 await assert.rejects(a.pinFile({owner:'parent',file:'src/x.js'}),/another/);
 await b.withFileLease({owner:'child',file:'src/x.js'},async()=>{});
 await b.release({owner:'child',leaseId:lease.id});assert.equal((await a.status()).leases.length,0);
});

test('rectangle writes serialize read/patch/save; path escapes and aliases cannot acquire leases',async t=>{
 const {a,b,root,project}=await fixture(t);let revision=0; const left=await a.claim({owner:'a',rectangle:{x:0,y:0,width:5,height:5}}),right=await b.claim({owner:'b',rectangle:{x:5,y:0,width:5,height:5}});
 await Promise.all(Array.from({length:30},(_,i)=>(i%2?a:b).withBoardLease({owner:i%2?'a':'b',leaseId:i%2?left.id:right.id},async()=>{const old=revision;await new Promise(r=>setTimeout(r,1));revision=old+1;})));
 assert.equal(revision,30);
 await assert.rejects(a.claim({owner:'a',paths:['../outside']}),/escapes/);
 await writeFile(path.join(root,'outside'),'private');await symlink(path.join(root,'outside'),path.join(project,'alias'));
 await assert.rejects(a.claim({owner:'a',paths:['alias']}),/links/);
 await assert.rejects(a.claim({owner:'a',rectangle:{x:0,y:0,width:NaN,height:1}}),/finite/);
});
