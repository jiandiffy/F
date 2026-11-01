import { realpath, mkdir, readFile, lstat } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { command } from '../datasets/providers.mjs';
import { applicationData, atomicJSON, withLock } from '../datasets/store.mjs';

const validRepo = value => /^[\w.-]+\/[\w.-]+$/.test(value);
const gitIdentity = ['-c', 'user.name=F', '-c', 'user.email=f@localhost'];
const cleanPath = value => {
  if (typeof value !== 'string' || !value || value.includes('\0') || path.isAbsolute(value) || value.split(/[\\/]/).some(p => p === '..' || p === '.git')) throw new Error('File scope must be project-relative, without .. or .git');
  return value.replace(/^\.\//, '').replace(/\/$/, '') || '.';
};
const contains = (parent, file) => parent === '.' || parent === file || file.startsWith(parent + '/');

export class VersionProject {
  constructor(project, { dataRoot = path.join(applicationData(), 'applications/versions'), runner = command } = {}) {
    this.project = path.resolve(project); this.dataRoot = dataRoot; this.run = runner;
  }
  async git(args, cwd = this.project, options = {}) { return this.run('git', ['--literal-pathspecs', '-C', cwd, ...args], { trim: !args.includes('-z'), ...options }); }
  async verify() {
    const actual = await realpath(this.project);
    const top = await this.git(['rev-parse', '--show-toplevel']);
    if (await realpath(top) !== actual) throw new Error('This folder has no own Git repository. Enable version management first; parent repositories are never modified.');
    const common = await this.git(['rev-parse', '--path-format=absolute', '--git-common-dir']);
    this.metadata = path.join(common, 'f-tree.json'); this.lock = path.join(common, 'f-tree-operation.lock');
    this.workspaceRoot = path.join(this.dataRoot, createHash('sha256').update(actual).digest('hex'), 'worktrees');
  }
  async state() {
    await this.verify();
    try { return JSON.parse(await readFile(this.metadata, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; return { version: 1, nodes: [] }; }
  }
  async enable() {
    await mkdir(this.project, { recursive: true });
    let ownsGit = false;
    try { await lstat(path.join(this.project, '.git')); ownsGit = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (!ownsGit) await this.git(['init', '--initial-branch=main']);
    await this.verify();
    return withLock(this.lock, async () => {
      let hasHead = true;
      try { await this.git(['rev-parse', '--verify', 'HEAD']); } catch { hasHead = false; }
      if (!hasHead) await this.git([...gitIdentity, 'commit', '--allow-empty', '--only', '-m', 'Start F project version tree']);
      const state = await this.state();
      if (!state.nodes.length) {
        const branch = await this.git(['symbolic-ref', '--short', 'HEAD']);
        state.nodes.push({ id: 'root', label: path.basename(this.project), branch, parent: null, worktree: this.project, paths: ['.'], createdAt: new Date().toISOString() });
        await atomicJSON(this.metadata, state);
      }
      return this.status();
    });
  }
  async status() {
    const state = await this.state();
    const nodes = [];
    for (const node of state.nodes) {
      let head = null, changes = null;
      try { head = await this.git(['rev-parse', 'HEAD'], node.worktree); changes = await this.git(['status', '--short'], node.worktree); }
      catch { /* Removed worktrees remain visible in the tree until explicitly repaired. */ }
      nodes.push({ ...node, head, changes });
    }
    const remotes = (await this.git(['remote', '-v'])).replace(/(https?:\/\/)[^\s/@]+@/g, '$1[redacted]@');
    return { project: this.project, nodes, remotes };
  }
  async branch({ parent = 'root', label, paths }) {
    await this.verify();
    if (!label?.trim() || !Array.isArray(paths) || !paths.length) throw new Error('A branch needs a label and explicit file scopes');
    paths = paths.map(cleanPath);
    return withLock(this.lock, async () => {
      const state = await this.state(), ancestor = state.nodes.find(node => node.id === parent);
      if (!ancestor) throw new Error('Unknown parent version');
      for (const scope of paths) if (!ancestor.paths.some(p => contains(p, scope))) throw new Error('Child scope exceeds parent scope');
      const id = randomUUID(), slug = label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 32) || 'task';
      const branch = `codex/f/${slug}-${id.slice(0, 8)}`, worktree = path.join(this.workspaceRoot, id);
      await mkdir(this.workspaceRoot, { recursive: true });
      await this.git(['worktree', 'add', '-b', branch, worktree, ancestor.branch]);
      const node = { id, label, branch, parent, worktree, paths, base: await this.git(['rev-parse', ancestor.branch]), createdAt: new Date().toISOString() };
      state.nodes.push(node); await atomicJSON(this.metadata, state); return node;
    });
  }
  async node(id) {
    const node = (await this.state()).nodes.find(node => node.id === id);
    if (!node) throw new Error('Unknown version node');
    const current = await this.git(['symbolic-ref', '--short', 'HEAD'], node.worktree);
    if (current !== node.branch) throw new Error('Version worktree has switched branches; restore its assigned branch first');
    return node;
  }
  async commit({ node: id = 'root', paths, message }) {
    await this.verify();
    if (!message?.trim() || !Array.isArray(paths) || !paths.length) throw new Error('Commit requires a message and explicit paths');
    paths = paths.map(cleanPath);
    return withLock(this.lock, async () => {
      const node = await this.node(id);
      for (const file of paths) if (!node.paths.some(scope => contains(scope, file))) throw new Error('Commit path is outside the assigned scope');
      // Check symlinks and tracked/untracked file paths before staging any requested scope.
      const files = (await this.git(['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', ...paths], node.worktree)).split('\0').filter(Boolean);
      const secrets = /(^|\/)(auth\.json|credentials[^/]*|.*api[-_]key.*|\.env(?:\..*)?|id_(?:rsa|ed25519)|signing-keychain-password)(\/|$)/i;
      if (files.some(file => secrets.test(file))) throw new Error('Selected files include credentials. Narrow the commit scope or add private files to .gitignore.');
      for (const file of files) {
        const full = path.join(node.worktree, file);
        let resolved;
        try { resolved = await realpath(full); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
        const relative = path.relative(await realpath(node.worktree), resolved);
        if (relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) throw new Error('Commit scope contains a symlink outside the project');
      }
      await this.git(['add', '--', ...paths], node.worktree);
      await this.git([...gitIdentity, 'commit', '--only', '-m', message, '--', ...paths], node.worktree);
      return { node: id, commit: await this.git(['rev-parse', 'HEAD'], node.worktree), paths };
    });
  }
  async merge({ node: id, test }) {
    await this.verify();
    if (!Array.isArray(test) || !test.length || test.some(value => typeof value !== 'string')) throw new Error('Merge requires an actual test command as an argv array');
    return withLock(this.lock, async () => {
      const state = await this.state(), source = await this.node(id);
      if (!source.parent) throw new Error('Root has no parent to merge into');
      const target = await this.node(source.parent);
      for (const node of [source, target]) if (await this.git(['status', '--porcelain'], node.worktree)) throw new Error('Commit or resolve worktree changes before merging');
      const changed = (await this.git(['diff', '--no-renames', '--name-only', '-z', `${source.base}..${source.branch}`])).split('\0').filter(Boolean);
      if (changed.some(file => !source.paths.some(scope => contains(scope, file)))) throw new Error('Branch changes exceed its assigned file scope');
      await this.run(test[0], test.slice(1), { cwd: source.worktree });
      // A failed merge/test is left explicitly pending for repair; never reset or discard files.
      await this.git([...gitIdentity, 'merge', '--no-ff', '--no-commit', source.branch], target.worktree);
      try {
        const output = await this.run(test[0], test.slice(1), { cwd: target.worktree });
        const pending = await this.git(['rev-parse', '--git-path', 'MERGE_HEAD'], target.worktree);
        let hasMerge = false; try { await lstat(path.resolve(target.worktree, pending)); hasMerge = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
        if (hasMerge) await this.git([...gitIdentity, 'commit', '-m', `Merge ${source.label}`], target.worktree);
        source.mergedAt = new Date().toISOString(); source.validation = { command: test, output: output.slice(-12000), passed: true };
        state.nodes[state.nodes.findIndex(n => n.id === id)] = source; await atomicJSON(this.metadata, state);
        return { source: id, target: target.id, commit: await this.git(['rev-parse', 'HEAD'], target.worktree), validation: source.validation };
      } catch (error) { throw new Error(`Merged result did not pass validation; pending changes remain in ${target.worktree}. ${error.message}`); }
    });
  }
  async publish({ node: id = 'root', repository, authorized = false }) {
    if (!authorized) throw new Error('GitHub publication requires an explicit user publish action');
    await this.verify();
    return withLock(this.lock, async () => {
      const node = await this.node(id);
      if (await this.git(['status', '--porcelain'], node.worktree)) throw new Error('Commit the intended files before publishing');
      const remotes = (await this.git(['remote'])).split('\n');
      if (!remotes.includes('origin')) {
        if (!validRepo(repository ?? '')) throw new Error('First publication needs GitHub owner/repository');
        await this.run('gh', ['repo', 'create', repository, '--private', '--source', this.project, '--remote', 'origin']);
      }
      const remote = await this.git(['remote', 'get-url', 'origin']);
      if (!/^(https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)[\w.-]+\/[\w.-]+(?:\.git)?$/.test(remote)) throw new Error('origin is not a supported github.com repository');
      await this.git(['push', '--set-upstream', 'origin', node.branch], node.worktree);
      return { branch: node.branch, remote, commit: await this.git(['rev-parse', 'HEAD'], node.worktree) };
    });
  }
}
