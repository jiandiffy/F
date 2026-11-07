const fs = require('node:fs');
const path = require('node:path');
const { paths } = require('./runtime-paths.cjs');

function merge(base, overlay) {
  for (const [key, value] of Object.entries(overlay)) {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      base[key] = merge(base[key] && typeof base[key] === 'object' ? base[key] : {}, value);
    } else base[key] = value;
  }
  return base;
}
function ensureProfile(source, options = {}) {
  if (!['cbc', 'cbi'].includes(source)) throw Error('Unknown model source');
  const resolved = options.paths || paths();
  const directory = path.join(resolved.codebuddy, source), file = path.join(directory, 'product.json');
  if (fs.existsSync(file)) return directory;
  const vendor = path.join(resolved.runtimeRoot, 'node_modules/@tencent-ai/codebuddy-code');
  const product = JSON.parse(fs.readFileSync(path.join(vendor, 'product.json'), 'utf8'));
  if (source === 'cbc') merge(product, JSON.parse(fs.readFileSync(path.join(vendor, 'product.internal.json'), 'utf8')));
  product.authentication.id = 'fy-pi-' + source;
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  // Public provider configuration only. Never copy a developer's account state.
  try { fs.writeFileSync(file, JSON.stringify(product, null, 2) + '\n', { flag: 'wx', mode: 0o600 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  return directory;
}
module.exports = { ensureProfile };
