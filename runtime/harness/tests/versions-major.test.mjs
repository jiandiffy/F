import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, lstat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { VersionProject } from '../../../packages/versions/agent/project.mjs';
import { mountVersions } from '../../../packages/versions/agent/index.mjs';
import { mountAIOS } from '../../../packages/agent-bus/agent/index.mjs';
import { createKernel } from '../src/core/kernel.mjs';
import { command } from '../../../packages/data-base/agent/providers.mjs';

const succeeds = [process.execPath, '-e', "require('assert').equal(require('fs').readFileSync('code.txt','utf8').length > 0,true)"];
async function fixture(t, enabled = true) {
  const base = await mkdtemp(path.join(os.tmpdir(), 'f-version-major-')), folder = path.join(base, 'project');
  await mkdir(folder);
  const project = new VersionProject(folder, { dataRoot: path.join(base, 'data') });
  t.after(() => rm(base, { recursive: true, force: true }));
  if (enabled) await project.enable();
  return { base, folder, project };
}
async function major(project, folder, text = 'one', options = {}) {
  await writeFile(path.join(folder, 'code.txt'), text);
  return project.complete({ paths: ['code.txt'], summary: text, test: succeeds, ...options });
}
function host() {
  const tools = new Map(), events = new Map(); let active = [];
  return { tools, appendEntry() {}, registerTool(t) { tools.set(t.name, t); active.push(t.name); },
    getAllTools: () => [...tools.values()], getActiveTools: () => active, setActiveTools(v) { active = v; },
    on(name, fn) { const list = events.get(name) ?? new Set(); list.add(fn); events.set(name, list); return () => list.delete(fn); },
    async emit(name, event, context) { for (const fn of events.get(name) ?? []) await fn(event, context); } };
}
async function cli(request) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [fileURLToPath(new URL('../../../packages/versions/agent/cli.mjs', import.meta.url))]);
    let output = '', stderr = '';
    child.stdout.on('data', data => { output += data; }); child.stderr.on('data', data => { stderr += data; });
    child.on('error', reject); child.on('close', code => resolve({ code, ...JSON.parse(output), stderr }));
    child.stdin.end(JSON.stringify(request));
  });
}

test('never-clicked projects are read-only disabled; Agent cannot bypass enable enum; UI activation persists', async t => {
  const { folder, project, base } = await fixture(t, false);
  await command('git', ['init', '--initial-branch=main', base]);
  assert.equal((await project.status()).enabled, false);
  assert.equal(await project.goalCheckpoint(), null);
  for (const [method, input] of [['branch', { label: 'bad', paths: ['.'] }], ['commit', { paths: ['.'], message: 'bad' }], ['complete', { paths: ['.'], test: succeeds }]]) await assert.rejects(project[method](input));
  await assert.rejects(lstat(path.join(folder, '.git')), { code: 'ENOENT' });
  const pi = host(), kernel = createKernel(pi); await mountVersions(kernel);
  t.after(() => kernel.fiber.dispose());
  const tool = pi.tools.get('project_version');
  assert.equal(tool.parameters.properties.action.enum.includes('enable'), false);
  for (const action of ['enable', 'publish', 'constructor']) await assert.rejects(tool.execute('', { action }, null, null, { cwd: folder }), /Agent cannot/);
  assert.equal((await cli({ project: folder, action: 'enable' })).code, 1);
  const activated = await cli({ project: folder, action: 'enable', authorized: true });
  assert.equal(activated.code, 0); assert.equal(activated.value.enabled, true); assert.deepEqual(activated.value.versions, []);
  assert.equal((await new VersionProject(folder).status()).enabled, true);
  const metadata = JSON.parse(await readFile(path.join(folder, '.git/f-tree.json'), 'utf8'));
  assert.equal(metadata.enabled, true);
});

test('an existing Git repo and legacy unconsented metadata do not opt a project in', async t => {
  const { folder, project } = await fixture(t, false);
  await command('git', ['init', '--initial-branch=main', folder]);
  assert.equal((await project.status()).enabled, false);
  await assert.rejects(project.branch({ label: 'no consent', paths: ['.'] }), /disabled/);
  await writeFile(path.join(folder, '.git/f-tree.json'), JSON.stringify({ version: 1, nodes: [] }));
  assert.equal((await project.status()).enabled, false);
  await assert.rejects(project.complete({ paths: ['.'], test: succeeds }), /disabled/);
});

test('ordinary Git without F metadata imports fixed history only after authorized enable, with idempotent retry', async t => {
  for (const metadataMode of ['missing', 'old-empty']) await t.test(metadataMode, async t => {
    const { folder, project } = await fixture(t, false);
    await project.git(['init', '--initial-branch=main']);
    const commits = [];
    for (let index = 0; index < 3; index++) {
      await writeFile(path.join(folder, 'code.txt'), 'old ' + index);
      await project.git(['add', '--', 'code.txt']);
      await project.git(['-c', 'user.name=Legacy', '-c', 'user.email=legacy@localhost', 'commit', '-m', 'Old ' + index]);
      commits.push(await project.git(['rev-parse', 'HEAD']));
    }
    const metadata = path.join(folder, '.git/f-tree.json');
    if (metadataMode === 'old-empty') await writeFile(metadata, JSON.stringify({ version: 1, nodes: [] }));
    const refs = await project.git(['for-each-ref', '--format=%(refname) %(objectname)']);
    const indexBefore = await readFile(path.join(folder, '.git/index'));
    await writeFile(path.join(folder, 'draft.txt'), 'preserve draft');
    assert.equal((await project.status()).enabled, false);
    assert.equal(await project.goalCheckpoint(), null);
    assert.equal((await cli({ project: folder, action: 'enable' })).code, 1);
    if (metadataMode === 'missing') await assert.rejects(lstat(metadata), { code: 'ENOENT' });
    const activated = await cli({ project: folder, action: 'enable', authorized: true });
    assert.equal(activated.code, 0);
    const versions = activated.value.versions;
    assert.deepEqual(versions.map(v => v.commit), commits);
    for (const [i, version] of versions.entries()) {
      assert.equal(version.id, 'legacy-' + commits[i]);
      assert.equal(version.head, commits[i]);
      assert.deepEqual(version.parents, i ? ['legacy-' + commits[i - 1]] : []);
      assert.equal(version.legacy, true); assert.equal(version.major, false);
      assert.equal(version.validation, null); assert.equal(version.publishCommit, undefined);
    }
    assert.equal(await project.git(['for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads']), refs);
    assert.deepEqual(await readFile(path.join(folder, '.git/index')), indexBefore);
    assert.equal(await readFile(path.join(folder, 'draft.txt'), 'utf8'), 'preserve draft');
    assert.deepEqual((await project.enable()).versions, versions);
    assert.equal(await project.git(['rev-parse', 'HEAD']), commits.at(-1));
    await assert.rejects(project.publish({ version: versions.at(-1).id, authorized: true }), /tested major/);
    const firstMajor = await project.complete({ paths: ['code.txt', 'draft.txt'], test: succeeds, summary: 'First verified task' });
    assert.equal(firstMajor.label, 'v1');
    assert.deepEqual(firstMajor.parents, ['legacy-' + commits.at(-1)]);
    assert.equal(await project.git(['rev-list', '--count', firstMajor.publishCommit]), '1');
  });
});

test('authorized activation migrates real legacy multi-parent history without inventing majors or passing tests', async t => {
  const { folder, project, base } = await fixture(t, false);
  await project.git(['init', '--initial-branch=main']);
  const commit = async (cwd, file, contents, message) => {
    await writeFile(path.join(cwd, file), contents);
    await project.git(['add', '--', file], cwd);
    await project.git(['-c', 'user.name=Legacy', '-c', 'user.email=legacy@localhost', 'commit', '-m', message], cwd);
    return project.git(['rev-parse', 'HEAD'], cwd);
  };
  const initial = await commit(folder, 'code.txt', 'old code', 'Legacy root');
  const left = path.join(base, 'left'), right = path.join(base, 'right');
  await project.git(['worktree', 'add', '-b', 'old/left', left]);
  await project.git(['worktree', 'add', '-b', 'old/right', right]);
  const leftCommit = await commit(left, 'left.txt', 'left', 'Legacy left');
  const rightCommit = await commit(right, 'right.txt', 'right', 'Legacy right');
  const rootUpdate = await commit(folder, 'code.txt', 'old root update', 'Legacy root update');
  await project.git(['-c', 'user.name=Legacy', '-c', 'user.email=legacy@localhost', 'merge', '--no-ff', '-m', 'Legacy left integration', 'old/left']);
  const firstMerge = await project.git(['rev-parse', 'HEAD']);
  await project.git(['-c', 'user.name=Legacy', '-c', 'user.email=legacy@localhost', 'merge', '--no-ff', '-m', 'Legacy right integration', 'old/right']);
  const secondMerge = await project.git(['rev-parse', 'HEAD']);
  const nodes = [
    { id: 'root', label: 'Existing project', branch: 'main', parent: null, worktree: folder, paths: ['.'], createdAt: '2025-01-01T00:00:00Z' },
    { id: 'old-left', label: 'Existing left', branch: 'old/left', parent: 'root', worktree: left, paths: ['left.txt'], base: initial, validation: { passed: true, command: ['old-test'] } },
    { id: 'old-right', label: 'Existing right', branch: 'old/right', parent: 'root', worktree: right, paths: ['right.txt'], base: initial },
  ];
  const metadata = path.join(folder, '.git/f-tree.json'), original = JSON.stringify({ version: 1, nodes, custom: { preserve: true } }, null, 2);
  await writeFile(metadata, original);
  await writeFile(path.join(folder, 'uncommitted.txt'), 'preserve working data');
  const heads = await project.git(['for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads']);
  const history = (await project.git(['rev-list', '--all'])).split('\n').sort();
  for (let index = 0; index < 2; index++) {
    assert.equal((await project.status()).enabled, false);
    assert.equal(await project.goalCheckpoint(), null);
    assert.equal(await readFile(metadata, 'utf8'), original, 'Read-only discovery must not migrate or authorize legacy metadata');
    assert.equal(await project.git(['for-each-ref', 'refs/f']), '');
  }
  assert.equal((await cli({ project: folder, action: 'enable' })).code, 1);
  assert.equal(await readFile(metadata, 'utf8'), original);
  const activated = await cli({ project: folder, action: 'enable', authorized: true });
  assert.equal(activated.code, 0); assert.equal(activated.value.enabled, true);
  const migrated = JSON.parse(await readFile(metadata, 'utf8'));
  assert.deepEqual(migrated.nodes, nodes); assert.deepEqual(migrated.custom, { preserve: true });
  const versions = activated.value.versions;
  assert.deepEqual(versions.map(v => v.commit).sort(), history);
  for (const version of versions) {
    assert.equal(version.id, 'legacy-' + version.commit); assert.equal(version.head, version.commit);
    assert.equal(version.kind, 'agent'); assert.equal(version.legacy, true); assert.equal(version.major, false);
    assert.equal(version.validation, null); assert.equal(version.publishCommit, undefined);
  }
  const byCommit = new Map(versions.map(v => [v.commit, v]));
  assert.deepEqual(byCommit.get(firstMerge).parents, ['legacy-' + rootUpdate, 'legacy-' + leftCommit]);
  assert.deepEqual(byCommit.get(secondMerge).parents, ['legacy-' + firstMerge, 'legacy-' + rightCommit]);
  assert.deepEqual(byCommit.get(initial).parents, []);
  assert.equal(byCommit.get(secondMerge).sourceNode, 'root');
  assert.equal(await project.git(['for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads']), heads);
  assert.equal(await project.git(['rev-parse', 'HEAD']), secondMerge);
  assert.equal(await readFile(path.join(folder, 'uncommitted.txt'), 'utf8'), 'preserve working data');
  await assert.rejects(project.publish({ version: versions.at(-1).id, authorized: true }), /tested major/);
  await commit(left, 'left.txt', 'later development', 'Move legacy branch after import');
  assert.deepEqual((await project.enable()).versions, versions, 'Repeated activation must not expand or rewrite fixed imported snapshots');
  const rootVersion = await project.complete({ paths: ['code.txt', 'uncommitted.txt'], test: succeeds, summary: 'First tested task' });
  assert.equal(rootVersion.label, 'v1'); assert.deepEqual(rootVersion.parents, ['legacy-' + secondMerge]);
  assert.equal(await project.git(['rev-list', '--count', rootVersion.publishCommit]), '1', 'Publication ancestry must still exclude every imported development commit');
});

test('a legacy Git read failure leaves consent, original metadata and branches unchanged', async t => {
  const { folder, project } = await fixture(t);
  const originalNodes = (await project.state()).nodes;
  const original = JSON.stringify({ version: 1, nodes: originalNodes });
  const metadata = path.join(folder, '.git/f-tree.json'); await writeFile(metadata, original);
  const before = await project.git(['rev-parse', 'HEAD']), runner = project.run;
  project.run = (file, args, options) => args.includes('log') ? Promise.reject(new Error('Legacy object database unavailable')) : runner(file, args, options);
  await assert.rejects(project.enable(), /Legacy object database unavailable/);
  assert.equal(await readFile(metadata, 'utf8'), original);
  assert.equal((await project.status()).enabled, false);
  assert.equal(await project.git(['rev-parse', 'HEAD']), before);
  assert.equal(await project.git(['for-each-ref', 'refs/f']), '');
});

test('simple real validations create only immutable linear majors, with independent snapshot ancestry and trees', async t => {
  const { folder, project } = await fixture(t);
  const first = await major(project, folder), firstHash = first.commit;
  await writeFile(path.join(folder, 'code.txt'), 'development');
  await project.commit({ paths: ['code.txt'], message: 'Internal iteration' });
  const second = await major(project, folder, 'two', { summary: '中'.repeat(250) });
  const versions = (await project.status()).versions;
  assert.deepEqual(versions.map(v => v.label), ['v1', 'v2']);
  assert.deepEqual(second.parents, [first.id]); assert.equal(second.parent, first.id);
  assert.equal(first.head, firstHash); assert.equal(versions[0].commit, firstHash);
  assert.equal(second.summary.length, 200); assert.equal(second.kind, 'major'); assert.equal(second.validation.exitCode, 0);
  assert.equal(await project.git(['rev-list', '--count', second.publishCommit]), '2');
  for (const version of versions) assert.equal(await project.git(['rev-parse', `${version.commit}^{tree}`]), await project.git(['rev-parse', `${version.publishCommit}^{tree}`]));
  assert.deepEqual((await project.git(['rev-list', second.publishCommit])).split('\n'), [second.publishCommit, first.publishCommit]);
});

test('complex fixed agent commits retain fork/join edges and real pre/post-merge validation', async t => {
  const { folder, project } = await fixture(t);
  const initial = await major(project, folder);
  const a = await project.branch({ label: 'agent A', paths: ['a'] });
  const b = await project.branch({ label: 'agent B', paths: ['b'] });
  for (const [node, file] of [[a, 'a'], [b, 'b']]) {
    await writeFile(path.join(node.worktree, file), file);
    await project.commit({ node: node.id, paths: [file], message: `Implement ${file}` });
    await project.merge({ node: node.id, test: [process.execPath, '-e', `require('assert').equal(require('fs').readFileSync('${file}','utf8'),'${file}')`] });
  }
  const completed = await project.complete({ paths: ['.'], complexity: 'complex', summary: 'Integrated', test: succeeds });
  const versions = (await project.status()).versions, agents = versions.filter(v => v.kind === 'agent');
  assert.equal(agents.length, 4);
  const aCommit = agents.find(v => v.sourceNode === a.id), bCommit = agents.find(v => v.sourceNode === b.id);
  assert.deepEqual(aCommit.parents, [initial.id]); assert.deepEqual(bCommit.parents, [initial.id]);
  const joins = agents.filter(v => v.sourceNode === 'root');
  assert.deepEqual(joins[0].parents, [initial.id, aCommit.id]);
  assert.deepEqual(joins[1].parents, [joins[0].id, bCommit.id]);
  assert.ok(completed.parents.includes(joins[1].id));
  assert.ok(joins.every(v => v.validation.passed && v.validation.exitCode === 0));
  assert.equal(await project.git(['rev-list', '--count', completed.publishCommit]), '2');
});

test('merge validation keeps repair context, while persistence failures retain their original diagnostics', async t => {
  for (const mode of ['validation', 'commit', 'update-ref']) await t.test(mode, async t => {
    const { folder, project } = await fixture(t);
    await major(project, folder);
    const child = await project.branch({ label: 'child', paths: ['child.txt'] });
    await writeFile(path.join(child.worktree, 'child.txt'), 'preserve merged data');
    await project.commit({ node: child.id, paths: ['child.txt'], message: 'Implement child' });
    const metadata = path.join(folder, '.git/f-tree.json'), before = await readFile(metadata, 'utf8');
    const failure = Object.assign(new Error(`${mode} unavailable`), { code: mode === 'validation' ? 7 : 'EACCES', stderr: 'original diagnostics' });
    const runner = project.run;
    project.run = (file, args, options) => {
      if (mode === 'validation' ? file === process.execPath && options.cwd === folder : file === 'git' && args.includes(mode)) return Promise.reject(failure);
      return runner(file, args, options);
    };
    try {
      await assert.rejects(project.merge({ node: child.id, test: succeeds }), error => {
        if (mode === 'validation') {
          assert.match(error.message, /pending changes remain/);
          assert.equal(error.cause, failure);
        } else assert.equal(error, failure, 'Persistence errors must not be relabelled as failed validation');
        return true;
      });
    } finally { project.run = runner; }
    assert.equal(await readFile(metadata, 'utf8'), before, 'No successful merge metadata is written on failure');
    assert.equal(await readFile(path.join(folder, 'child.txt'), 'utf8'), 'preserve merged data');
    assert.equal(await readFile(path.join(child.worktree, 'child.txt'), 'utf8'), 'preserve merged data');
    if (mode !== 'update-ref') assert.ok(await project.git(['rev-parse', '--verify', 'MERGE_HEAD']), 'Uncommitted merges remain pending for explicit repair');
    else await assert.rejects(project.git(['rev-parse', '--verify', '--quiet', 'MERGE_HEAD']), { code: 1 });
  });
});

test('failed, cancelled, mutated validation and unowned changes never create successful versions', async t => {
  for (const mode of ['failure', 'cancel', 'untracked-mutation', 'tracked-mutation', 'index-flags', 'unowned']) await t.test(mode, async t => {
    const { folder, project } = await fixture(t); await major(project, folder);
    const before = (await project.status()).versions;
    await writeFile(path.join(folder, 'code.txt'), 'new');
    const controller = new AbortController(); let testCommand = succeeds;
    if (mode === 'failure') testCommand = [process.execPath, '-e', 'process.exit(7)'];
    if (mode === 'cancel') controller.abort();
    if (mode === 'untracked-mutation') {
      await writeFile(path.join(folder, 'new.txt'), 'before');
      testCommand = [process.execPath, '-e', "require('fs').writeFileSync('new.txt','after')"];
    }
    if (mode === 'tracked-mutation') testCommand = [process.execPath, '-e', "require('fs').writeFileSync('code.txt','test mutation')"];
    if (mode === 'index-flags') await project.git(['update-index', '--assume-unchanged', 'code.txt']);
    if (mode === 'unowned') await writeFile(path.join(folder, 'outside.txt'), 'preserve');
    await assert.rejects(project.complete({ paths: mode === 'untracked-mutation' ? ['code.txt', 'new.txt'] : ['code.txt'], test: testCommand, signal: controller.signal }));
    assert.deepEqual((await project.status()).versions, before);
    assert.equal(await readFile(path.join(folder, 'code.txt'), 'utf8'), mode === 'tracked-mutation' ? 'test mutation' : 'new');
  });
});

// GitHub is NEVER contacted: only gh's response and the transport URL are isolated.
// The actual commit-tree, push, receive-pack, object storage and reachability are Git.
async function isolatedRemote(project, base, { privateRepo = true, create = false } = {}) {
  const bare = path.join(base, 'remote.git'); await command('git', ['init', '--bare', bare]);
  if (!create) await project.git(['remote', 'add', 'origin', 'https://github.com/example/private-project.git']);
  const calls = [];
  const runner = async (file, args, options) => {
    calls.push([file, ...args]);
    if (file === 'gh') {
      if (args[1] === 'create') {
        assert.ok(args.includes('--private')); assert.ok(!args.includes('--push'));
        await project.git(['remote', 'add', 'origin', 'https://github.com/example/private-project.git']); return '';
      }
      assert.deepEqual(args, ['repo', 'view', 'example/private-project', '--json', 'isPrivate']);
      return JSON.stringify({ isPrivate: privateRepo });
    }
    if (args.includes('push')) {
      assert.ok(args.includes('--no-follow-tags')); assert.ok(!args.includes('--force')); assert.ok(!args.includes('--tags'));
      const rewritten = args.map(arg => arg === 'origin' ? bare : arg);
      return command(file, rewritten, options);
    }
    return command(file, args, options);
  };
  return { bare, calls, publisher: new VersionProject(project.project, { dataRoot: project.dataRoot, runner }) };
}

test('private isolated bare publication exposes exactly major snapshots, no development ancestors or tags', async t => {
  const { folder, project, base } = await fixture(t);
  // Simulate pre-existing private history, bypassing the plugin's credential
  // guard only to construct this adversarial fixture.
  await writeFile(path.join(folder, '.env'), 'historical development credential');
  await project.git(['add', '--', '.env']);
  await project.git(['-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'Private development ancestor']);
  const hidden = await project.git(['rev-parse', 'HEAD']);
  const credentialBlob = await project.git(['rev-parse', 'HEAD:.env']);
  await project.git(['-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'tag', '-a', 'do-not-publish', '-m', 'private', hidden]);
  await project.git(['rm', '--', '.env']);
  await project.git(['-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'Remove internal content']);
  const first = await major(project, folder);
  const { bare, calls, publisher } = await isolatedRemote(project, base, { create: true });
  await assert.rejects(publisher.publish({ authorized: false }), /explicit user/); assert.equal(calls.length, 0);
  await publisher.publish({ authorized: true, repository: 'example/private-project', version: first.id });
  const second = await major(project, folder, 'two');
  await publisher.publish({ authorized: true, version: second.id });
  const reachable = (await command('git', ['--git-dir', bare, 'rev-list', '--all'])).split('\n').sort();
  assert.deepEqual(reachable, [first.publishCommit, second.publishCommit].sort());
  assert.equal(await command('git', ['--git-dir', bare, 'tag', '--list']), '');
  assert.equal(await command('git', ['--git-dir', bare, 'show-ref', '--heads']), `${second.publishCommit} refs/heads/f-versions`);
  for (const object of [hidden, credentialBlob]) await assert.rejects(command('git', ['--git-dir', bare, 'cat-file', '-e', object]), error => error.code === 1);
  assert.equal(await project.git(['remote', 'get-url', 'origin']), 'https://github.com/example/private-project.git');
});

test('public, unknown visibility, unsafe origins and credential snapshot trees fail closed', async t => {
  for (const mode of ['public', 'unknown', 'query-error', 'unsafe-url', 'push-url', 'credentials']) await t.test(mode, async t => {
    const { folder, project, base } = await fixture(t);
    if (mode === 'credentials') {
      await writeFile(path.join(folder, 'auth.json'), 'existing secret');
      await project.git(['add', '--', 'auth.json']);
      await project.git(['-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'Existing repository fixture']);
      await assert.rejects(major(project, folder), /credentials/);
      assert.deepEqual((await project.status()).versions, []); return;
    }
    await major(project, folder);
    const { publisher, bare } = await isolatedRemote(project, base, { privateRepo: mode !== 'public' });
    const runner = publisher.run;
    if (mode === 'unknown') publisher.run = (file, args, options) => file === 'gh' ? Promise.resolve('{}') : runner(file, args, options);
    if (mode === 'query-error') publisher.run = (file, args, options) => file === 'gh' ? Promise.reject(new Error('Visibility unavailable')) : runner(file, args, options);
    if (mode === 'unsafe-url') await project.git(['remote', 'set-url', 'origin', 'https://example.com/owner/repo']);
    if (mode === 'push-url') await project.git(['remote', 'set-url', '--push', 'origin', 'https://github.com/example/public.git']);
    await assert.rejects(publisher.publish({ authorized: true }), /private|Visibility|origin/);
    assert.equal(await command('git', ['--git-dir', bare, 'rev-list', '--all']), '');
  });
});

test('a divergent remote stays unchanged; no force or hidden development push', async t => {
  const { folder, project, base } = await fixture(t); const version = await major(project, folder);
  const { publisher, bare } = await isolatedRemote(project, base);
  const tree = await project.git(['rev-parse', `${version.commit}^{tree}`]);
  const unrelated = await project.git(['-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit-tree', tree, '-m', 'Existing unrelated remote history']);
  await project.git(['push', bare, `${unrelated}:refs/heads/f-versions`]);
  await assert.rejects(publisher.publish({ authorized: true }), /rejected|fetch first|non-fast-forward/);
  assert.equal(await command('git', ['--git-dir', bare, 'rev-parse', 'refs/heads/f-versions']), unrelated);
});

test('goal_flow independent passed test actually creates a major; failed/cancelled/disabled tests do not', async t => {
  for (const mode of ['passed', 'failed', 'cancelled', 'disabled', 'mutated']) await t.test(mode, async t => {
    const { folder, project, base } = await fixture(t, mode !== 'disabled');
    await writeFile(path.join(folder, 'code.txt'), 'delivered code');
    const pi = host(), kernel = createKernel(pi), controller = new AbortController();
    let testerId = 0;
    kernel.provide('subagents', { async startActivation({ label }) {
      const childId = `independent-${++testerId}`;
      const result = (async () => {
        if (label === '最简化 agent') return { stopReason: 'completed', structured: { report: 'No redundant code found', changedPaths: [] } };
        const argv = mode === 'failed' ? [process.execPath, '-e', 'process.exit(9)'] : succeeds;
        let passed = true, output = '';
        try { output = await command(argv[0], argv.slice(1), { cwd: folder }); } catch (error) { passed = false; output = error.message; }
        await kernel.emit('subagent/event', { childId, event: { type: 'tool_execution_end', toolName: 'bash', isError: !passed, result: { output, command: argv, exitCode: passed ? 0 : 9 } } });
        if (mode === 'cancelled') controller.abort();
        if (mode === 'mutated') await writeFile(path.join(folder, 'code.txt'), 'modified by tester');
        return { stopReason: 'completed', structured: { passed, report: 'Actual local validation', checks: [{ subgoal: 'file verification', method: argv.join(' '), passed, evidence: output }] } };
      })();
      return { childId, result };
    } });
    const depth = process.env.F_AGENT_DEPTH; delete process.env.F_AGENT_DEPTH;
    try { await mountAIOS(kernel, { dataRoot: path.join(base, 'goal-state') }); }
    finally { if (depth !== undefined) process.env.F_AGENT_DEPTH = depth; }
    t.after(() => kernel.fiber.dispose());
    const context = { cwd: folder, sessionManager: { getSessionId: () => 'goal-test', getSessionFile: () => path.join(base, 'session.jsonl'), getBranch: () => [], getHeader: () => ({}) } };
    const flow = args => pi.tools.get('goal_flow').execute('', args, controller.signal, null, context);
    await flow({ action: 'begin', goal: 'Implement verified code', complexity: 'simple', artifact: 'code' });
    await flow({ action: 'delivered', report: 'Implemented' }); await flow({ action: 'simplify', paths: ['code.txt'] });
    if (['cancelled', 'mutated'].includes(mode)) await assert.rejects(flow({ action: 'test', paths: ['code.txt'] }), /cancelled|changed/);
    else {
      const result = (await flow({ action: 'test', paths: ['code.txt'] })).details;
      assert.equal(result.phase, mode === 'failed' ? 'rework' : 'complete');
      if (mode === 'passed') assert.equal(result.version.validation.independent, true);
    }
    assert.equal((await project.status()).versions.length, mode === 'passed' ? 1 : 0);
    if (mode === 'disabled') await assert.rejects(lstat(path.join(folder, '.git')), { code: 'ENOENT' });
  });
});
