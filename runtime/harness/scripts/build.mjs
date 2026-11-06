import { build } from 'esbuild';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const upstream = path.resolve(root, '../../vendor/cordis');
execFileSync('/usr/bin/python3', [path.join(root, 'scripts/verify-upstream.py')], { stdio: 'inherit' });
const aliases = {
  '@deepseek-ai/cordis': 'vendor/cordis/src/index.ts',
  '@deepseek-ai/cosmokit': 'vendor/cosmokit/src/index.ts',
  '@deepseek-ai/schemastery': 'vendor/schemastery/src/index.ts',
  '@deepseek-ai/dsh-scope': 'packages/core/scope/src/index.ts',
  '@deepseek-ai/dsh-skill': 'packages/skill/skill/src/index.ts',
  '@deepseek-ai/dsh-home-paths': 'packages/util/home-paths/src/index.ts',
  '@deepseek-ai/dsh-util-values': 'packages/util/values/src/index.ts',
  '@deepseek-ai/dsh-brand': 'packages/util/brand/src/index.ts',
  '@deepseek-ai/dsh-tools': 'packages/core/tools/src/json-schema.ts',
  '@deepseek-ai/dsh-workflow': 'packages/workflow/workflow/src/index.ts',
  // These consumers need the error vocabulary, not the DSH model runtime.
  '@deepseek-ai/dsh-llm': 'packages/llm/llm/src/error.ts',
};
const built = await build({
  entryPoints: [path.join(root, 'src/upstream.ts')], outfile: path.join(root, 'dist/upstream.mjs'),
  bundle: true, format: 'esm', platform: 'node', target: 'node24', sourcemap: true,
  nodePaths: [path.join(root, 'node_modules')],
  alias: Object.fromEntries(Object.entries(aliases).map(([k,v]) => [k,path.join(upstream,v)])),
  banner: { js: "import { createRequire as __fCreateRequire } from 'node:module'; const require = __fCreateRequire(import.meta.url);" },
  metafile: true,
});

const { writeFile, readFile } = await import('node:fs/promises');
await writeFile(path.join(root, 'dist/inputs.json'), JSON.stringify(Object.keys(built.metafile.inputs).filter(p=>path.resolve(p).startsWith(upstream + path.sep)), null, 2));

const licenses = ['../../vendor/cordis/LICENSE', '../../vendor/cordis/vendor/cordis/LICENSE', '../../vendor/cordis/vendor/cosmokit/LICENSE',
  '../../vendor/cordis/vendor/schemastery/LICENSE', 'node_modules/chokidar/LICENSE', 'node_modules/readdirp/LICENSE', 'node_modules/yaml/LICENSE'];
const notices = await Promise.all(licenses.map(async file => `${file}\n${await readFile(path.join(root,file),'utf8')}`));
await writeFile(path.join(root,'dist/THIRD_PARTY_NOTICES.txt'), notices.join('\n\n'));
