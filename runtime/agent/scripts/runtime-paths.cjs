const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');

const runtimeRoot = path.resolve(__dirname, '..');
const root = path.resolve(runtimeRoot, '../..');
function paths(env = process.env, home = os.homedir()) {
  const bundled = env.F_DISTRIBUTION === 'dmg' || fs.existsSync(path.join(root, 'F-distribution.json'));
  const data = env.F_USER_DATA_DIRECTORY || path.join(home, 'Library/Application Support/F');
  // Centralized existing data remains authoritative for both distributions.
  const agent = env.PI_CODING_AGENT_DIR || path.join(data, 'agent');
  const cache = env.F_CACHE_DIRECTORY || (bundled
    ? path.join(home, 'Library/Caches/F') : path.join(agent, 'cache'));
  return { root, runtimeRoot, bundled, data, agent, cache,
    auth: path.join(agent, 'auth.json'), codebuddy: path.join(data, 'auth/codebuddy') };
}
module.exports = { paths };
if (require.main === module) {
  const key = process.argv[2];
  if (!['agent', 'cache', 'data', 'codebuddy'].includes(key)) process.exit(2);
  process.stdout.write(paths()[key]);
}
