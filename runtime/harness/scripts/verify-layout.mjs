import { readdir, readFile, stat, realpath } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const root = path.resolve(import.meta.dirname, '../../..');
const directories = ['packages', 'skills', 'workflows', 'ui', 'vendor', 'auth', 'mcp', 'runtime', 'profiles', 'F_data'];
assert.deepEqual((await readdir(root, { withFileTypes: true })).filter(entry => entry.isDirectory() && !entry.name.startsWith('.')).map(entry => entry.name).sort(), directories.sort());
for (const id of ['shell', 'folder', 'browser-use', 'computer-use', 'excalidraw', 'agent-bus', 'browser', 'daily-papers', 'task-scheduler', 'gmail', 'versions', 'ssh', 'side-agent', 'data-base']) {
  const manifest = JSON.parse(await readFile(path.join(root, 'packages', id, 'package.json'), 'utf8'));
  assert.equal(manifest.f.id, id);
  for (const entry of Object.values(manifest.f.entries)) assert.ok((await stat(path.join(root, entry))).isDirectory());
}
const skills = ['translate','code-simplify','self-improve','app-development','unslop','code-test','agent-experience','cordis-styling-nitpicking','dsh-archive-agent-notes','dsh-ci-test-reliability','dsh-client-ui-ux','dsh-code-review','dsh-create-upgrade-guide','dsh-cua-macos-signing','dsh-doc','dsh-error-handling','dsh-find-simplifications','dsh-merging-stacked-prs','dsh-official-plugin-artwork','dsh-pr-description','dsh-pre-push-checks','dsh-prose-standard','dsh-responsive-ui','dsh-session-projection','dsh-speed-up-perf','dsh-translate-docs','dsh-trim-cot-leakage','cordis-plugin-development','editing-cordis-compositions','cordis-composition-reference','office','office-docx','office-pptx','office-xlsx','office-render','office-recalculate','office-export-pdf'];
for (const name of skills) {
  const body = await readFile(path.join(root, 'skills', name, 'SKILL.md'), 'utf8');
  assert.match(body, /^---\n/); assert.match(body, /description:/);
}
for (const name of ['main-agent', 'research-review', 'multi-agent-debate', 'code-development']) assert.equal(JSON.parse(await readFile(path.join(root, 'workflows', name, 'plan.json'), 'utf8')).id, name);
assert.equal(await realpath(path.join(root, 'ui/web')), path.join(root, 'packages/excalidraw/web'));
assert.equal(await realpath(path.join(root, 'ui/desktop/Plugins/Whiteboard')), path.join(root, 'packages/excalidraw/desktop'));
for (const removed of ['vendor/deepseek-harness', 'vendor/cursor-plugins', 'runtime/harness/upstream']) {
  await assert.rejects(stat(path.join(root, removed)), { code: 'ENOENT' });
}
for (const entry of ['runtime/agent/bin/f', 'runtime/node/bin/node', 'vendor/cordis/SOURCE.json']) assert.ok((await stat(path.join(root, entry))).isFile());
console.log(`PASS: ten software directories, fourteen required packages, ${skills.length} requested skills, workflows and canonical UI mappings`);
