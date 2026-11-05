import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { VersionProject } from '../../../packages/versions/agent/project.mjs';

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'f-version-adversarial-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const folder = path.join(directory, 'project');
  const project = new VersionProject(folder, { dataRoot: path.join(directory, 'data') });
  await project.enable();
  await mkdir(path.join(folder, 'src'));
  await writeFile(path.join(folder, 'src/code.txt'), 'before');
  await writeFile(path.join(folder, 'outside.txt'), 'preserved');
  await project.commit({ paths: ['src', 'outside.txt'], message: 'Fixture' });
  const child = await project.branch({ label: 'scoped task', paths: ['src'] });
  await writeFile(path.join(child.worktree, 'src/code.txt'), 'after');
  await project.commit({ node: child.id, paths: ['src'], message: 'Allowed change' });
  return { directory, folder, project, child, before: await project.git(['rev-parse', 'HEAD']) };
}

test('post-merge validation cannot smuggle staged outside files or credentials into a merge', async t => {
  for (const file of ['outside.txt', 'unexpected.txt', 'src/.env']) await t.test(file, async t => {
    const { folder, project, child, before } = await fixture(t);
    const script = `const fs=require('fs'),cp=require('child_process');if(fs.realpathSync(process.cwd())===fs.realpathSync(${JSON.stringify(folder)})){fs.writeFileSync(${JSON.stringify(file)},'test-generated secret');cp.execFileSync('git',['add','--',${JSON.stringify(file)}]);}`;
    await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', script] }), /scope|credentials|changed|dirty|validation|index|test/i);
    assert.equal(await project.git(['rev-parse', 'HEAD']), before, 'Rejected validation must not create a parent commit');
    assert.equal(await readFile(path.join(folder, file), 'utf8'), 'test-generated secret', 'Rejected validation must preserve the working file');
    assert.equal(await project.git(['show', `:${file}`]), 'test-generated secret', 'Rejected validation must preserve the staged file');
    assert.equal(await project.git(['rev-parse', 'MERGE_HEAD']), await project.git(['rev-parse', 'HEAD'], child.worktree));
    assert.equal((await project.status()).nodes.find(node => node.id === child.id).validation, undefined);
  });
});

test('pre-merge validation cannot extend the child branch after its scope was checked', async t => {
  const { project, child, before } = await fixture(t);
  const script = `const fs=require('fs'),cp=require('child_process');if(fs.realpathSync(process.cwd())===fs.realpathSync(${JSON.stringify(child.worktree)})){fs.writeFileSync('outside.txt','outside committed during test');cp.execFileSync('git',['add','--','outside.txt']);cp.execFileSync('git',['-c','user.name=Test','-c','user.email=test@localhost','commit','-m','Validation mutation']);}`;
  await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', script] }), /scope|changed|dirty|validation|test|HEAD/i);
  assert.equal(await project.git(['rev-parse', 'HEAD']), before);
  assert.equal(await project.git(['show', 'HEAD:outside.txt'], child.worktree), 'outside committed during test', 'Rejected validation must preserve the child commit');
});

test('pre-merge validation cannot contaminate the parent index through an absolute path', async t => {
  const { project, folder, child, before } = await fixture(t);
  const script = `const fs=require('fs'),cp=require('child_process');if(fs.realpathSync(process.cwd())===fs.realpathSync(${JSON.stringify(child.worktree)})){fs.writeFileSync(${JSON.stringify(path.join(folder, 'outside.txt'))},'parent index mutation');cp.execFileSync('git',['-C',${JSON.stringify(folder)},'add','--','outside.txt']);}`;
  await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', script] }), /scope|changed|dirty|validation|index|test/i);
  assert.equal(await project.git(['rev-parse', 'HEAD']), before);
  assert.equal(await project.git(['show', 'HEAD:outside.txt'], child.worktree), 'preserved', 'The child commit must remain unchanged');
  assert.equal(await project.git(['show', ':outside.txt']), 'parent index mutation', 'Rejected validation must preserve the parent index');
  assert.equal(await readFile(path.join(folder, 'outside.txt'), 'utf8'), 'parent index mutation', 'Rejected validation must preserve the parent working file');
});

test('validation rejects HEAD, index and unstaged mutations in either worktree without discarding them', async t => {
  for (const phase of ['pre', 'post']) for (const destination of ['source', 'target']) for (const mutation of ['worktree', 'index', 'HEAD', 'index-flags']) {
    await t.test(`${phase}/${destination}/${mutation}`, async t => {
      const { folder, project, child, before } = await fixture(t);
      const sourceHead = await project.git(['rev-parse', 'HEAD'], child.worktree);
      const working = destination === 'source' ? child.worktree : folder;
      const activeDirectory = phase === 'pre' ? child.worktree : folder;
      const script = `const fs=require('fs'),cp=require('child_process');if(fs.realpathSync(process.cwd())===fs.realpathSync(${JSON.stringify(activeDirectory)})){
        const cwd=${JSON.stringify(working)},git=args=>cp.execFileSync('git',['-C',cwd,...args]);
        fs.writeFileSync(require('path').join(cwd,'src/code.txt'),'test mutation');
        if(${JSON.stringify(mutation)}==='index')git(['add','--','src/code.txt']);
        if(${JSON.stringify(mutation)}==='HEAD'){git(['add','--','src/code.txt']);git(['-c','user.name=Test','-c','user.email=test@localhost','commit','-m','Test mutation']);}
        if(${JSON.stringify(mutation)}==='index-flags')git(['update-index','--assume-unchanged','src/code.txt']);
      }`;
      await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', script] }), /changed|validation|HEAD|index/i);
      assert.equal(await readFile(path.join(working, 'src/code.txt'), 'utf8'), 'test mutation');
      const parentHead = await project.git(['rev-parse', 'HEAD']);
      if (mutation === 'HEAD' && destination === 'target') assert.notEqual(parentHead, before, 'Keep the commit made by the test rather than resetting it');
      else assert.equal(parentHead, before, 'Never create an automatic merge commit on validation mutation');
      if (mutation === 'HEAD' && destination === 'source') assert.notEqual(await project.git(['rev-parse', 'HEAD'], child.worktree), sourceHead);
      assert.equal((await project.status()).nodes.find(node => node.id === child.id).validation, undefined);
    });
  }
});

test('a directly committed credential cannot bypass the merge credential guard', async t => {
  const { project, child, before } = await fixture(t);
  await writeFile(path.join(child.worktree, 'src/.env'), 'fixture secret');
  await project.git(['add', '--', 'src/.env'], child.worktree);
  await project.git(['-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'Direct credential commit'], child.worktree);
  await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', 'process.exit(0)'] }), /credentials/);
  assert.equal(await project.git(['rev-parse', 'HEAD']), before);
  assert.equal(await project.git(['show', 'HEAD:src/.env'], child.worktree), 'fixture secret');
});

test('pre-existing hidden index flags block validation in either worktree without changing files or flags', async t => {
  for (const flag of ['assume-unchanged', 'skip-worktree']) for (const destination of ['source', 'target']) {
    await t.test(`${flag}/${destination}`, async t => {
      const { directory, folder, project, child, before } = await fixture(t);
      const working = destination === 'source' ? child.worktree : folder;
      const sourceHead = await project.git(['rev-parse', 'HEAD'], child.worktree);
      const marker = path.join(directory, 'test-ran');
      await project.git(['update-index', `--${flag}`, '--', 'outside.txt'], working);
      await writeFile(path.join(working, 'outside.txt'), 'hidden local change');
      const flags = await project.git(['ls-files', '-v', '-z'], working);
      assert.equal(await project.git(['status', '--porcelain']), '');
      assert.equal(await project.git(['status', '--porcelain'], child.worktree), '');
      const script = `require('fs').writeFileSync(${JSON.stringify(marker)},'ran');require('fs').writeFileSync(${JSON.stringify(path.join(working, 'outside.txt'))},'test pollution')`;
      await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', script] }), /assume-unchanged|skip-worktree/);
      await assert.rejects(readFile(marker), { code: 'ENOENT' }, 'Reject before executing validation');
      assert.equal(await readFile(path.join(working, 'outside.txt'), 'utf8'), 'hidden local change');
      assert.equal(await project.git(['ls-files', '-v', '-z'], working), flags);
      assert.equal(await project.git(['rev-parse', 'HEAD']), before);
      assert.equal(await project.git(['rev-parse', 'HEAD'], child.worktree), sourceHead);
      assert.equal((await project.status()).nodes.find(node => node.id === child.id).validation, undefined);
    });
  }
});

test('cancellation after the merged-result test preserves pending files without a success vertex', async t => {
  const { project, folder, child, before } = await fixture(t);
  const versions = (await project.status()).versions, controller = new AbortController(), run = project.run;
  project.run = async (file, args, options) => {
    const output = await run(file, args, options);
    if (file === process.execPath && options.cwd === folder) controller.abort();
    return output;
  };
  await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', "require('assert').equal(require('fs').readFileSync('src/code.txt','utf8'),'after')"], signal: controller.signal }), /cancelled/);
  assert.equal(await project.git(['rev-parse', 'HEAD']), before);
  assert.equal(await readFile(path.join(folder, 'src/code.txt'), 'utf8'), 'after');
  assert.deepEqual((await project.status()).versions, versions);
});

test('child project contexts cannot select the root or a sibling as their assigned worktree', async t => {
  const { project, child } = await fixture(t);
  const scoped = new VersionProject(child.worktree, { dataRoot: project.dataRoot });
  await assert.rejects(scoped.commit({ paths: ['src'], message: 'Wrong root' }), /own assigned/);
  await assert.rejects(scoped.branch({ label: 'Escape root', paths: ['outside.txt'] }), /own assigned/);
  await assert.rejects(scoped.complete({ paths: ['src'], test: [process.execPath, '-e', 'process.exit(0)'] }), /own assigned/);
  await writeFile(path.join(child.worktree, 'src/code.txt'), 'owned');
  await scoped.commit({ node: child.id, paths: ['src'], message: 'Owned child commit' });
  assert.equal(await project.git(['show', 'HEAD:src/code.txt'], child.worktree), 'owned');
});

test('validation cannot mutate version consent metadata or Git config and then be marked passed', async t => {
  for (const mode of ['metadata', 'config']) await t.test(mode, async t => {
    const { project, folder, child, before } = await fixture(t);
    const file = path.join(folder, '.git', mode === 'metadata' ? 'f-tree.json' : 'config');
    const script = mode === 'metadata'
      ? `const fs=require('fs'),file=${JSON.stringify(file)},state=JSON.parse(fs.readFileSync(file));state.tampered=true;fs.writeFileSync(file,JSON.stringify(state));`
      : `require('child_process').execFileSync('git',['-C',${JSON.stringify(folder)},'config','f.testMutation','true'])`;
    await assert.rejects(project.merge({ node: child.id, test: [process.execPath, '-e', script] }), /changed/);
    assert.equal(await project.git(['rev-parse', 'HEAD']), before);
    assert.equal((await project.status()).nodes.find(n => n.id === child.id).validation, undefined);
    if (mode === 'metadata') assert.equal(JSON.parse(await readFile(file, 'utf8')).tampered, true);
    else assert.equal(await project.git(['config', 'f.testMutation']), 'true');
  });
});

test('explicit commit paths exclude every pre-staged sibling with Git pathspec metacharacters', async t => {
  const { project, folder } = await fixture(t);
  const names = ['literal[1].txt', 'literal*.txt', ':literal.txt', 'space name.txt', '中文.txt', '--flag.txt', 'line\nbreak.txt', '$(literal).txt'];
  for (let index = 0; index < names.length; index++) {
    const selected = path.join('src', names[index]);
    await writeFile(path.join(folder, selected), `selected ${index}`);
    await writeFile(path.join(folder, 'outside.txt'), `staged sibling ${index}`);
    await project.git(['add', '--', 'outside.txt']);
    await project.commit({ paths: [selected], message: `Literal case ${index}` });
    assert.deepEqual((await project.git(['diff-tree', '--no-commit-id', '--name-only', '-z', '-r', 'HEAD'])).split('\0').filter(Boolean), [selected]);
    assert.equal(await project.git(['show', 'HEAD:outside.txt']), 'preserved');
    assert.equal(await project.git(['diff', '--cached', '--name-only']), 'outside.txt');
  }
});
