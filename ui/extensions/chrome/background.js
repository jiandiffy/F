const blocked = host => /(^|\.)google\.[a-z.]+$/.test(host);
let refreshing = false;
const pattern = url => ['alphaxiv.org','www.alphaxiv.org'].includes(url.hostname) ? 'https://*.alphaxiv.org/*' : url.origin + '/*';
async function session(origin, tabId, openURL) {
  const url = new URL(origin); if(url.protocol!=='https:' || blocked(url.hostname))throw Error('Google 密码与通行密钥由 Chrome 管理；请在目标网站登录后同步该网站。');
  if(!await chrome.permissions.contains({origins:[pattern(url)]}))throw Error('尚未授权这个网站');
  const all = ['alphaxiv.org','www.alphaxiv.org'].includes(url.hostname) ? await chrome.cookies.getAll({domain:'alphaxiv.org'}) : await chrome.cookies.getAll({url:origin});
  const cookies = all.filter(c=>!c.partitionKey);
  let storage;
  if(tabId) {
    try {
      const result=await chrome.scripting.executeScript({target:{tabId},func:()=> {
        const entries=Object.entries(localStorage).filter(([key,value])=>/auth|session|token|supabase|clerk|firebase/i.test(key) && key.length<=512 && value.length<=65536).slice(0,50);
        return {origin:location.origin, values:Object.fromEntries(entries)};
      }});
      if(result[0]?.result?.origin===origin)storage=result[0].result.values;
    }catch{} // Cookie-only sessions remain usable when this tab is no longer open.
  }
  const response=await chrome.runtime.sendNativeMessage('local.f.browser',{action:'importSession',origin,cookies, ...(storage ? {storage} : {}), ...(openURL ? {openURL} : {})});
  if(!response?.ok)throw Error(response?.error??'F 登录同步未完成');
  return response.value;
}
chrome.runtime.onMessage.addListener((message,_sender,reply)=> {
  if(message.action!=='sync'&&message.action!=='stop')return;
  (async()=> {
    const sites=(await chrome.storage.local.get('sites')).sites??{};
    if(message.action==='stop') {delete sites[message.origin];await chrome.storage.local.set({sites});return {stopped:true};}
    const tab=await chrome.tabs.get(message.tabId), url=new URL(tab?.url??'');
    if(url.origin!==message.origin)throw Error('标签页已跳转，请重新打开扩展后同步');
    if(!sites[url.origin]&&Object.keys(sites).length>=16)throw Error('最多自动同步16个网站，请先停止不常用网站。');
    sites[url.origin]=true;await chrome.storage.local.set({sites});await chrome.alarms.create('refresh',{periodInMinutes:1});
    return session(url.origin,tab.id,tab.url);
  })().then(value=>reply({ok:true,value}),error=>reply({ok:false,error:error.message}));return true;
});
chrome.alarms.onAlarm.addListener(async alarm=> {
  if(alarm.name!=='refresh'||refreshing)return;
  refreshing=true;
  try {
    const sites=(await chrome.storage.local.get('sites')).sites??{};
    for(const origin of Object.keys(sites).slice(0,16)) {
      try {
        const tabs=await chrome.tabs.query({url:origin+'/*'});await session(origin,tabs[0]?.id);
      }catch{} // F can be closed. Retry next minute; never log session material.
    }
  }finally{refreshing=false;}
});
