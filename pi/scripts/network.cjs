// Shared routing for Pi's CodeBuddy children and standalone login commands.
const { execFileSync } = require('node:child_process');
const bypass = 'localhost,127.0.0.1,::1,api.deepseek.com,.deepseek.com,copilot.tencent.com,.copilot.tencent.com,www.codebuddy.cn,.codebuddy.cn,copilot.qq.com,.copilot.qq.com';
let systemProxy;
function proxyFromSystem() {
  if (systemProxy !== undefined) return systemProxy;
  systemProxy = '';
  try {
    const state = execFileSync('/usr/sbin/scutil', ['--proxy'], { encoding: 'utf8', timeout: 2000 });
    const host = state.match(/HTTPSProxy\s*:\s*(\S+)/)?.[1];
    const port = state.match(/HTTPSPort\s*:\s*(\d+)/)?.[1];
    if (/HTTPSEnable\s*:\s*1/.test(state) && host && port) systemProxy = `http://${host}:${port}`;
  } catch {}
  return systemProxy;
}
function networkEnv(source, base = process.env) {
  const env = { ...base };
  const keys = ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'];
  if (source === 'cbc') {
    const proxy = base.HTTPS_PROXY || base.https_proxy || base.HTTP_PROXY || base.http_proxy || proxyFromSystem();
    for (const key of keys) env[key] = '';
    // Keep an explicit proxy source so CodeBuddy does not replace our bypass
    // rules with macOS's own bypass list during automatic proxy detection.
    if (proxy) env.HTTP_PROXY = env.HTTPS_PROXY = env.http_proxy = env.https_proxy = proxy;
    env.NO_PROXY = env.no_proxy = '*';
  } else {
    const proxy = base.HTTPS_PROXY || base.https_proxy || base.HTTP_PROXY || base.http_proxy || proxyFromSystem();
    if (proxy) {
      env.HTTP_PROXY = env.HTTPS_PROXY = env.http_proxy = env.https_proxy = proxy;
      env.ALL_PROXY = env.all_proxy = '';
    }
    const extra = base.NO_PROXY || base.no_proxy || '';
    env.NO_PROXY = env.no_proxy = [...new Set((bypass + ',' + extra).split(',').filter(Boolean))].join(',');
  }
  return env;
}
module.exports = { networkEnv };
