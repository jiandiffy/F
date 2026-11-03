import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink, realpath } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { VersionProject } from '../src/versions/project.mjs';
import { command } from '../src/datasets/providers.mjs';

async function setup() {
  const base = await mkdtemp(path.join(os.tmpdir(), 'f-version-')), root = path.join(base, 'parent'), folder = path.join(root, 'project');
  await mkdir(folder, { recursive: true });
  await command('git', ['init', '--initial-branch=main', root]);
  return { base, root, folder, project: new VersionProject(folder, { dataRoot: path.join(base, 'data') }), cleanup: () => rm(base, { recursive: true, force: true }) };
}

test('enable creates own repository; scoped branches and tested merges form a real tree', async () => {
  const env = await setup();
  try {
    const { project, folder } = env;
    assert.deepEqual((await project.status()).versions, []);
    assert.equal((await project.status()).enabled, false);
    const initial = await project.enable(); assert.equal(initial.nodes[0].id, 'root');
    assert.equal(await project.git(['rev-parse', '--show-toplevel']), await realpath(folder));
    await mkdir(path.join(folder, 'src')); await writeFile(path.join(folder, 'src/main.txt'), 'one');
    await writeFile(path.join(folder, 'notes.txt'), 'keep uncommitted');
    await project.commit({ paths: ['src'], message: 'Initial code' });
    assert.equal(await project.git(['show', 'HEAD:src/main.txt']), 'one');
    assert((await project.git(['status', '--porcelain'])).includes('notes.txt'));
    const node = await project.branch({ label: 'algorithm', paths: ['src'] });
    await writeFile(path.join(node.worktree, 'src/main.txt'), 'two');
    await assert.rejects(project.commit({ node: node.id, paths: ['notes.txt'], message: 'bad' }), /outside/);
    await project.commit({ node: node.id, paths: ['src'], message: 'Improve algorithm' });
    await assert.rejects(project.merge({ node: node.id, test: [process.execPath, '-e', 'process.exit(0)'] }), /Commit or resolve/);
    await project.commit({ paths: ['notes.txt'], message: 'Save notes' });
    const merged = await project.merge({ node: node.id, test: [process.execPath, '-e', "require('assert').equal(require('fs').readFileSync('src/main.txt','utf8'),'two')"] });
    assert.equal(merged.validation.passed, true); assert.equal(await readFile(path.join(folder, 'src/main.txt'), 'utf8'), 'two');
    assert.equal((await project.status()).nodes.length, 2);
    await assert.rejects(project.publish({}), /explicit user/);
  } finally { await env.cleanup(); }
});

test('scope validation rejects path escape, symlink escape and credentials without staging', async () => {
  const env = await setup();
  try {
    const { project, folder, base } = env; await project.enable();
    await assert.rejects(project.branch({ label: 'bad', paths: ['../parent'] }), /project-relative/);
    await writeFile(path.join(folder, 'auth.json'), 'secret');
    await assert.rejects(project.commit({ paths: ['auth.json'], message: 'bad' }), /credentials/);
    await writeFile(path.join(base, 'outside'), 'outside'); await symlink(path.join(base, 'outside'), path.join(folder, 'link'));
    await assert.rejects(project.commit({ paths: ['link'], message: 'bad' }), /symlink/);
    assert.equal(await project.git(['diff', '--cached', '--name-only']), '');
  } finally { await env.cleanup(); }
});

test('failed child validation leaves parent unchanged', async () => {
  const env = await setup();
  try {
    const { project, folder } = env; await project.enable();
    await writeFile(path.join(folder, 'a'), 'one'); await project.commit({ paths: ['a'], message: 'a' });
    const before = await project.git(['rev-parse', 'HEAD']);
    const node = await project.branch({ label: 'failure', paths: ['a'] });
    await writeFile(path.join(node.worktree, 'a'), 'two'); await project.commit({ node: node.id, paths: ['a'], message: 'two' });
    await assert.rejects(project.merge({ node: node.id, test: [process.execPath, '-e', 'process.exit(3)'] }));
    assert.equal(await project.git(['rev-parse', 'HEAD']), before);
    assert.equal(await readFile(path.join(folder, 'a'), 'utf8'), 'one');
  } finally { await env.cleanup(); }
});

test('concurrent tree changes serialize across independent plugin instances', async () => {
  const env = await setup();
  try {
    await env.project.enable();
    const peers = Array.from({ length: 5 }, () => new VersionProject(env.folder, { dataRoot: path.join(env.base, 'data') }));
    const nodes = await Promise.all(peers.map((project, i) => project.branch({ label: 'task-' + i, paths: ['src'] })));
    const saved = await env.project.status();
    assert.equal(saved.nodes.length, 6); assert.equal(new Set(nodes.map(n => n.worktree)).size, 5);
    await assert.rejects(env.project.branch({ parent: nodes[0].id, label: 'escape', paths: ['docs'] }), /exceeds/);
  } finally { await env.cleanup(); }
});

test('post-merge validation failure keeps pending changes for explicit repair', async () => {
  const env = await setup();
  try {
    const { project, folder } = env; await project.enable();
    await writeFile(path.join(folder, 'a'), 'one'); await project.commit({ paths: ['a'], message: 'a' });
    const node = await project.branch({ label: 'integration', paths: ['a'] });
    await writeFile(path.join(node.worktree, 'a'), 'two'); await project.commit({ node: node.id, paths: ['a'], message: 'two' });
    await writeFile(path.join(folder, 'parent-only'), 'fixture'); await project.commit({ paths: ['parent-only'], message: 'parent fixture' });
    const before = await project.git(['rev-parse', 'HEAD']);
    await assert.rejects(project.merge({ node: node.id, test: [process.execPath, '-e', "process.exit(require('fs').existsSync('parent-only')?2:0)"] }), /pending changes remain/);
    assert.equal(await project.git(['rev-parse', 'HEAD']), before);
    assert.equal(await readFile(path.join(folder, 'a'), 'utf8'), 'two');
    assert((await project.git(['status', '--porcelain'])).includes('a'));
  } finally { await env.cleanup(); }
});

test('an origin lookup failure cannot trigger repository creation', async () => {
  const env = await setup();
  try {
    await env.project.enable();
    await env.project.complete({ paths: ['.'], test: [process.execPath, '-e', 'process.exit(0)'] });
    await env.project.git(['remote', 'add', 'origin', 'https://github.com/example/project.git']);
    let creations = 0;
    const project = new VersionProject(env.folder, { dataRoot: path.join(env.base, 'data'), runner: (file, args, options) => {
      if (file === 'gh') { creations++; throw new Error('Unexpected repository creation'); }
      if (args.slice(-3).join(' ') === 'remote get-url origin') throw new Error('Git configuration unreadable');
      return command(file, args, options);
    } });
    await assert.rejects(project.publish({ authorized: true, repository: 'example/project' }), /Git configuration unreadable/);
    assert.equal(creations, 0);
  } finally { await env.cleanup(); }
});
