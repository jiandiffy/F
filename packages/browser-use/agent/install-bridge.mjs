import { mkdir, readFile, writeFile, cp, chmod, lstat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const args=process.argv.slice(2), option=name=>{const i=args.indexOf(name);return i<0?undefined:args[i+1];};
try {
  const root=process.env.F_BROWSER_BRIDGE_DIRECTORY??path.join(os.homedir(),'Library/Application Support/F/browser-bridge');
  const id=option('--extension-id')??'', node=option('--node'), hostRoot=args.includes('--host-root') ? option('--host-root') : here;
  if(id&&!/^[a-p]{32}$/.test(id))throw Error('扩展 ID 应为 Chrome 显示的 32 位字母');
  if(!node||!path.isAbsolute(node))throw Error('缺少 F 的 Node 运行路径');
  await mkdir(root,{recursive:true,mode:0o700});if((await lstat(root)).isSymbolicLink())throw Error('连接目录不能为符号链接');await chmod(root,0o700);
  const extension=path.join(root,'extension');try{if((await lstat(extension)).isSymbolicLink())throw Error('扩展目录不能为符号链接');}catch(e){if(e.code!=='ENOENT')throw e;}
  await cp(path.join(here,'chrome-extension'),extension,{recursive:true});
  if(id) {
    const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
    const launcher=path.join(root,'native-host');
    await writeFile(launcher,`#!/bin/sh\nexec ${quote(node)} ${quote(path.join(hostRoot,'native-host.mjs'))} "$@"\n`,{mode:0o700});await chmod(launcher,0o700);
    await writeFile(path.join(root,'native-config.json'),JSON.stringify({extensionID:id}),{mode:0o600});
    const hosts=process.env.F_CHROME_NATIVE_HOSTS??path.join(os.homedir(),'Library/Application Support/Google/Chrome/NativeMessagingHosts');
    await mkdir(hosts,{recursive:true});
    await writeFile(path.join(hosts,'local.f.browser.json'),JSON.stringify({name:'local.f.browser',description:'F selected-site login bridge',path:launcher,type:'stdio',allowed_origins:[`chrome-extension://${id}/`]}),{mode:0o600});
  }
  console.log(root);
}catch(e){console.error(e.message);process.exitCode=1;}
