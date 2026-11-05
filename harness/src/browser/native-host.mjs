import { readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { browserRequest } from './transport.mjs';
const directory = process.env.F_BROWSER_BRIDGE_DIRECTORY ?? path.join(os.homedir(),'Library/Application Support/F/browser-bridge');
function output(value) { const bytes=Buffer.from(JSON.stringify(value));const header=Buffer.alloc(4);header.writeUInt32LE(bytes.length);process.stdout.write(header);process.stdout.write(bytes); }
let data=Buffer.alloc(0), length;
try {
  const config=JSON.parse(await readFile(path.join(directory,'native-config.json'),'utf8'));
  if (!/^[a-p]{32}$/.test(config.extensionID) || process.argv[2]!==`chrome-extension://${config.extensionID}/`) throw Error('Chrome 扩展身份不匹配');
  for await(const chunk of process.stdin) {
    data=Buffer.concat([data,chunk]);if(data.length>1_000_004)throw Error('会话消息过大');
    if(length===undefined&&data.length>=4) {length=data.readUInt32LE();if(length>1_000_000)throw Error('会话消息过大');}
    if(length!==undefined&&data.length>=length+4)break;
  }
  if(length===undefined||data.length!==length+4)throw Error('会话消息不完整');
  const input=JSON.parse(data.subarray(4).toString('utf8'));
  if(input.action!=='importSession')throw Error('Chrome 桥接仅允许同步所选网站登录');
  output({ok:true,value:await browserRequest(input)});
}catch(e){output({ok:false,error:e.message});process.exitCode=1;}
