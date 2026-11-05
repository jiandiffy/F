const status=document.querySelector('#status');
let currentTab;
document.querySelector('#sync').disabled=true;
chrome.tabs.query({active:true,currentWindow:true}).then(([tab])=>{currentTab=tab;document.querySelector('#sync').disabled=false;});
document.querySelector('#sync').onclick=async()=> {
  try {
    const tab=currentTab,url=new URL(tab.url);
    if(url.protocol!=='https:'||/(^|\.)google\.[a-z.]+$/.test(url.hostname))throw Error('请先在目标网站完成登录；Google 密码和通行密钥不导出。');
    const origin=['alphaxiv.org','www.alphaxiv.org'].includes(url.hostname)?'https://*.alphaxiv.org/*':url.origin+'/*';
    const granted=await chrome.permissions.request({origins:[origin]});if(!granted)throw Error('未授权，未同步任何登录会话');
    status.textContent='正在连接 F…';const response=await chrome.runtime.sendMessage({action:'sync',tabId:tab.id,origin:url.origin});
    if(!response.ok)throw Error(response.error);status.textContent='已同步到 F；F 打开时每分钟刷新此网站的登录。';
  }catch(e){status.textContent=e.message;}
};
document.querySelector('#stop').onclick=async()=> {
  const [tab]=await chrome.tabs.query({active:true,currentWindow:true}),url=new URL(tab.url);
  await chrome.runtime.sendMessage({action:'stop',origin:url.origin});status.textContent='已停止自动同步；F 中已有的网站登录由网站管理。';
};
