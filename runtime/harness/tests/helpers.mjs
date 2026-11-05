import { mkdtemp, writeFile, chmod, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { Context } from '../dist/upstream.mjs';
import { SubagentManager, spawnProvider } from '../../../packages/side-agent/agent/manager.mjs';

export async function setup() {
  const root=await mkdtemp(path.join(os.tmpdir(),'f-activation-'));
  const cli=path.join(root,'fake-pi');
  await writeFile(cli,`#!${process.execPath}\n` + `
import { createInterface } from 'node:readline';
const send=value=>process.stdout.write(JSON.stringify(value)+'\\n');
const input=createInterface({input:process.stdin});
input.on('line',line=>{
 const r=JSON.parse(line);
 if(r.type==='prompt') {
  send({id:r.id,type:'response',success:true,data:{disposition:'started'}});
  if(r.message.startsWith('hang')) return;
  setTimeout(()=>{
   const text=r.message.startsWith('ambiguous')?'Summary\\n\u0060\u0060\u0060json\\n{"count":2}\\n\u0060\u0060\u0060\\n\u0060\u0060\u0060json\\n{"count":3}\\n\u0060\u0060\u0060':r.message.startsWith('fenced')?'Summary\\n\u0060\u0060\u0060json\\n{"count":2}\\n\u0060\u0060\u0060':r.message.includes('Return ONLY')?' {"count":2} ':r.message;
   send({type:'message_end',message:{role:'assistant',stopReason:r.message==='fail'?'error':'stop',content:[{type:'text',text}]}});
   send({type:'agent_end'});
   send({type:'agent_settled',aborted:false});
  },r.message.startsWith('delay')?100:5);
 } else send({id:r.id,type:'response',success:true,data:r.type==='get_state'?{model:{provider:'cbi',id:'deepseek-v4.1-flash'},thinkingLevel:'medium'}:{}});
});
input.on('close',()=>process.exit(0));
`);
  await chmod(cli,0o755);
  const ctx=new Context(), delivered=[];
  const fiber=await ctx.plugin({name:'test-subagents',apply(ctx){
    const manager=new SubagentManager(ctx,{cli,dataRoot:path.join(root,'data'),maxDepth:1,maxConcurrentAgents:4,deliver:(...args)=>delivered.push(args)});
    manager.registerProvider(spawnProvider);
    ctx.effect(()=>()=>manager.dispose());
  }});
  const parent=id=>({cwd:root,model:{provider:'test',id:'model'},thinkingLevel:'high',sessionManager:{getSessionId:()=>id}});
  return {root,ctx,delivered,parent,async cleanup(){await ctx.fiber.dispose();await rm(root,{recursive:true,force:true});}};
}
