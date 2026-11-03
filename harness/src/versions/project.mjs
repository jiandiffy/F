import { realpath, mkdir, readFile, lstat, readlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { command } from '../datasets/providers.mjs';
import { applicationData, atomicJSON, withLock } from '../datasets/store.mjs';

const validRepo = value => /^[\w.-]+\/[\w.-]+$/.test(value);
const gitIdentity = ['-c', 'user.name=F', '-c', 'user.email=f@localhost'];
const secrets = /(^|\/)(auth\.json|credentials[^/]*|.*api[-_]key.*|\.env(?:\..*)?|id_(?:rsa|ed25519)|signing-keychain-password)(\/|$)/i;
export const cleanPath = value => {
  if (typeof value !== 'string' || !value || value.includes('\0') || path.isAbsolute(value) || value.split(/[\\/]/).some(p => p === '..' || p === '.git')) throw new Error('File scope must be project-relative, without .. or .git');
  return value.replace(/^\.\//, '').replace(/\/$/, '') || '.';
};
const contains = (parent, file) => parent === '.' || parent === file || file.startsWith(parent + '/');

export class VersionProject {
  constructor(project, { dataRoot = path.join(applicationData(), 'applications/versions'), runner = command, agentId = process.env.F_AGENT_ID } = {}) {
    this.project = path.resolve(project); this.dataRoot = dataRoot; this.run = runner; this.agentId = agentId;
  }
  async git(args, cwd = this.project, options = {}) { return this.run('git', ['--literal-pathspecs', '-C', cwd, ...args], { trim: !args.includes('-z'), ...options }); }
  exclusive(run) { return withLock(this.lock, run); }
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
    try {
      const state = JSON.parse(await readFile(this.metadata, 'utf8'));
      return { ...state, legacyPending: !Array.isArray(state.versions), versions: state.versions ?? [], enabled: state.enabled === true };
    } catch (error) { if (error.code !== 'ENOENT') throw error; return { version: 2, enabled: false, nodes: [], versions: [], legacyPending: true }; }
  }
  async migrateLegacy(state) {
    // Called only under enable's operation lock, after explicit UI authorization.
    // Import actual objects/parents, never infer a passed test or a major release.
    const raw = await this.git(['log', '--all', '--topo-order', '--reverse', '-z', '--no-show-signature', '--no-notes', '--format=%H%x00%P%x00%cI%x00%s']);
    const fields = raw.split('\0');
    if (fields.at(-1) === '') fields.pop();
    if (fields.length % 4) throw new Error('Invalid legacy Git history; original metadata remains unchanged');
    const refs = new Map((await this.git(['for-each-ref', '--format=%(refname)%00%(objectname)', 'refs/heads'])).split('\n').filter(Boolean).map(line => line.split('\0')));
    const versions = [];
    for (let index = 0; index < fields.length; index += 4) {
      const [commit, parentText, createdAt, subject] = fields.slice(index, index + 4), hashes = parentText.split(' ').filter(Boolean);
      if (![commit, ...hashes].every(hash => /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(hash))) throw new Error('Invalid legacy commit object ID');
      const parents = hashes.map(hash => 'legacy-' + hash);
      versions.push({ id: 'legacy-' + commit, commit, head: commit, parents, parent: parents[0] ?? null, label: subject, summary: Array.from(subject).slice(0, 200).join(''), kind: 'agent', major: false, legacy: true, sourceNode: state.nodes.find(node => refs.get('refs/heads/' + node.branch) === commit)?.id ?? null, createdAt, validation: null });
    }
    // Pin graph tips, which retain every ancestor, without changing any existing
    // branch/tag/worktree. IDs remain the same across retries or later branch moves.
    const ancestors = new Set(versions.flatMap(version => version.parents));
    for (const tip of versions.filter(version => !ancestors.has(version.id))) await this.git(['update-ref', `refs/f/version-sources/${tip.id}`, tip.commit]);
    state.versions = versions;
    state.legacyMigratedAt = new Date().toISOString();
  }
  async enabledState() {
    const state = await this.state();
    if (!state.enabled) throw new Error('Version management is disabled. Only the user-facing Versions UI can enable this project.');
    return state;
  }
  async isEnabled() {
    try { await lstat(path.join(this.project, '.git')); }
    catch (error) { if (error.code === 'ENOENT') return false; throw error; }
    return (await this.state()).enabled;
  }
  async enable() {
    await mkdir(this.project, { recursive: true });
    let ownsGit = false;
    try { await lstat(path.join(this.project, '.git')); ownsGit = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (!ownsGit) await this.git(['init', '--initial-branch=main']);
    await this.verify();
    return this.exclusive(async () => {
      let hasHead = true;
      try { await this.git(['rev-parse', '--verify', '--quiet', 'HEAD']); }
      catch (error) { if (error.code !== 1) throw error; hasHead = false; }
      if (!hasHead) await this.git([...gitIdentity, 'commit', '--allow-empty', '--only', '-m', 'Start F project version tree']);
      const state = await this.state();
      if (!state.nodes.length) {
        const branch = await this.git(['symbolic-ref', '--short', 'HEAD']);
        state.nodes.push({ id: 'root', label: path.basename(this.project), branch, parent: null, worktree: this.project, paths: ['.'], createdAt: new Date().toISOString() });
      }
      // Plain Git is legacy too, even without F metadata. Create the in-memory
      // root first so imported tips connect to the first tested major. Never
      // import the synthetic initial commit of a newly created/unborn repository.
      if (state.legacyPending && hasHead) await this.migrateLegacy(state);
      state.legacyPending = false;
      state.version = 2; state.enabled = true;
      await atomicJSON(this.metadata, state);
      return this.status();
    });
  }
  async status() {
    if (!await this.isEnabled()) return { project: this.project, enabled: false, nodes: [], versions: [], remotes: '' };
    const state = await this.enabledState();
    const nodes = [];
    for (const node of state.nodes) {
      // Missing worktrees remain visible, but Git/configuration/permission errors
      // in an existing worktree must reach the caller instead of appearing empty.
      try { await realpath(node.worktree); }
      catch (error) {
        if (error.code !== 'ENOENT') throw error;
        nodes.push({ ...node, head: null, changes: null });
        continue;
      }
      const head = await this.git(['rev-parse', 'HEAD'], node.worktree);
      const changes = await this.git(['status', '--short'], node.worktree);
      nodes.push({ ...node, head, changes });
    }
    const remotes = (await this.git(['remote', '-v'])).replace(/(https?:\/\/)[^\s/@]+@/g, '$1[redacted]@');
    return { project: this.project, enabled: true, nodes, versions: state.versions, remotes };
  }
  async branch({ parent = 'root', label, paths }) {
    await this.verify();
    if (!label?.trim() || !Array.isArray(paths) || !paths.length) throw new Error('A branch needs a label and explicit file scopes');
    paths = paths.map(cleanPath);
    return this.exclusive(async () => {
      const state = await this.enabledState(), ancestor = state.nodes.find(node => node.id === parent);
      if (!ancestor) throw new Error('Unknown parent version');
      await this.node(parent);
      for (const scope of paths) if (!ancestor.paths.some(p => contains(p, scope))) throw new Error('Child scope exceeds parent scope');
      const id = randomUUID(), slug = label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 32) || 'task';
      const branch = `codex/f/${slug}-${id.slice(0, 8)}`, worktree = path.join(this.workspaceRoot, id);
      await mkdir(this.workspaceRoot, { recursive: true });
      await this.git(['worktree', 'add', '-b', branch, worktree, ancestor.branch]);
      const node = { id, label, branch, parent, worktree, paths, base: await this.git(['rev-parse', ancestor.branch]), versionBase: state.versions.filter(v => v.sourceNode === parent).at(-1)?.id ?? ancestor.versionBase ?? null, createdAt: new Date().toISOString() };
      state.nodes.push(node); await atomicJSON(this.metadata, state); return node;
    });
  }
  async node(id, { allowParent = false } = {}) {
    const state = await this.enabledState(), node = state.nodes.find(node => node.id === id);
    if (!node) throw new Error('Unknown version node');
    const root = state.nodes.find(n => n.id === 'root');
    const actual=await realpath(this.project),parent=allowParent&&state.nodes.find(n=>n.id===node.parent);
    if (actual !== await realpath(root.worktree) && actual !== await realpath(node.worktree) && (!parent || actual !== await realpath(parent.worktree))) throw new Error('A child worktree can only operate its own assigned version node');
    const current = await this.git(['symbolic-ref', '--short', 'HEAD'], node.worktree);
    if (current !== node.branch) throw new Error('Version worktree has switched branches; restore its assigned branch first');
    return node;
  }
  async commit({ node: id = 'root', paths, message }) {
    await this.verify();
    if (!message?.trim() || !Array.isArray(paths) || !paths.length) throw new Error('Commit requires a message and explicit paths');
    paths = paths.map(cleanPath);
    return this.exclusive(async () => {
      const node = await this.node(id);
      await this.commitOwned(node, paths, message);
      const commit = await this.git(['rev-parse', 'HEAD'], node.worktree);
      // Simple root tasks display only their tested major. Child worktree commits
      // retain immutable development vertices, not moving branch heads.
      if (id !== 'root') {
        const state = await this.enabledState();
        const parent = state.versions.filter(v => v.sourceNode === id).at(-1)?.id ?? node.versionBase;
        const version = { id: 'agent-' + randomUUID(), commit, head: commit, parents: parent ? [parent] : [], parent: parent ?? null, label: node.label, summary: Array.from(message).slice(0, 200).join(''), kind: 'agent', major: false, sourceNode: id, agentId:this.agentId, createdAt: new Date().toISOString(), validation: null };
        await this.git(['update-ref', `refs/f/version-sources/${version.id}`, commit]);
        state.versions.push(version); await atomicJSON(this.metadata, state);
      }
      return { node: id, commit, paths };
    });
  }
  async commitOwned(node, paths, message) {
    for (const file of paths) if (!node.paths.some(scope => contains(scope, file))) throw new Error('Commit path is outside the assigned scope');
    const files = (await this.git(['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', ...paths], node.worktree)).split('\0').filter(Boolean);
    if (files.some(file => secrets.test(file))) throw new Error('Selected files include credentials. Narrow the commit scope or add private files to .gitignore.');
    for (const file of files) {
      let resolved;
      try { resolved = await realpath(path.join(node.worktree, file)); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      const relative = path.relative(await realpath(node.worktree), resolved);
      if (relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) throw new Error('Commit scope contains a symlink outside the project');
    }
    await this.git(['add', '--', ...paths], node.worktree);
    await this.git([...gitIdentity, 'commit', '--only', '-m', message, '--', ...paths], node.worktree);
  }
  async validationState(node) {
    const pending = await this.git(['rev-parse', '--git-path', 'MERGE_HEAD'], node.worktree);
    let mergeHead = null;
    try { mergeHead = await readFile(path.resolve(node.worktree, pending), 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    return {
      head: await this.git(['rev-parse', 'HEAD'], node.worktree),
      branch: await this.git(['symbolic-ref', '--short', 'HEAD'], node.worktree),
      index: await this.git(['ls-files', '--stage', '-z'], node.worktree),
      indexFlags: await this.git(['ls-files', '-v', '-z'], node.worktree),
      worktree: await this.git(['diff', '--no-ext-diff', '--no-textconv', '--binary', '--no-renames'], node.worktree, { trim: false }),
      status: await this.git(['status', '--porcelain=v1', '-z', '--untracked-files=all'], node.worktree),
      mergeHead,
      metadataDigest: createHash('sha256').update(await readFile(this.metadata)).digest('hex'),
      configDigest: createHash('sha256').update(await this.git(['config', '--null', '--list', '--show-origin'], node.worktree, { trim: false })).digest('hex'),
      untracked: await Promise.all((await this.git(['ls-files', '--others', '--exclude-standard', '-z'], node.worktree)).split('\0').filter(Boolean).sort().map(async file => {
        const full = path.join(node.worktree, file), stat = await lstat(full);
        const contents = stat.isSymbolicLink() ? await readlink(full) : await readFile(full);
        return [file, stat.mode, createHash('sha256').update(contents).digest('hex')];
      })),
    };
  }
  async assertValidationState(node, expected) {
    const actual = await this.validationState(node);
    if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`Validation test changed HEAD, index or worktree in ${node.worktree}; all changes remain for explicit repair`);
  }
  async merge({ node: id, test, signal }) {
    await this.verify();
    if (!Array.isArray(test) || !test.length || test.some(value => typeof value !== 'string')) throw new Error('Merge requires an actual test command as an argv array');
    return this.exclusive(async () => {
      const state = await this.enabledState(), source = await this.node(id,{allowParent:true});
      if (!source.parent) throw new Error('Root has no parent to merge into');
      const target = await this.node(source.parent);
      const sourceBefore = await this.validationState(source), targetBefore = await this.validationState(target);
      for (const snapshot of [sourceBefore, targetBefore]) {
        // These flags hide worktree mutations from both diff and status.
        if (snapshot.indexFlags.split('\0').some(entry => /^[a-zS] /.test(entry))) throw new Error('Clear assume-unchanged and skip-worktree flags before merging; files and index remain unchanged');
        if (snapshot.status || snapshot.worktree || snapshot.mergeHead) throw new Error('Commit or resolve worktree changes before merging');
      }
      const changed = (await this.git(['diff', '--no-renames', '--name-only', '-z', `${source.base}..${sourceBefore.head}`])).split('\0').filter(Boolean);
      if (changed.some(file => !source.paths.some(scope => contains(scope, file)))) throw new Error('Branch changes exceed its assigned file scope');
      if (changed.some(file => secrets.test(file))) throw new Error('Branch changes include credentials; narrow the changes before merging');
      await this.run(test[0], test.slice(1), { cwd: source.worktree });
      await this.assertValidationState(source, sourceBefore);
      await this.assertValidationState(target, targetBefore);
      // Merge only the validated commit. A failed merge/test stays pending; never reset or discard files.
      await this.git([...gitIdentity, 'merge', '--no-ff', '--no-commit', sourceBefore.head], target.worktree);
      const merged = await this.validationState(target);
      let output;
      try {
        output = await this.run(test[0], test.slice(1), { cwd: target.worktree });
        await this.assertValidationState(source, sourceBefore);
        await this.assertValidationState(target, merged);
        if (signal?.aborted) throw new Error('Version merge cancelled');
      } catch (error) { throw new Error(`Merged result did not pass validation; pending changes remain in ${target.worktree}. ${error.message}`, { cause: error }); }
      // Persistence failures are not failed tests: preserve their original error
      // codes/output, and leave every Git/worktree change for explicit repair.
      if (merged.mergeHead) await this.git([...gitIdentity, 'commit', '-m', `Merge ${source.label}`], target.worktree);
      source.mergedAt = new Date().toISOString(); source.validation = { command: test, output: output.slice(-12000), exitCode: 0, passed: true };
      const commit = await this.git(['rev-parse', 'HEAD'], target.worktree);
      const targetVersion = state.versions.filter(v => v.sourceNode === target.id).at(-1)?.id ?? target.versionBase;
      const sourceVersion = state.versions.filter(v => v.sourceNode === source.id).at(-1)?.id ?? source.versionBase;
      const parents = [...new Set([targetVersion, sourceVersion].filter(Boolean))];
      const vertex = { id: 'agent-' + randomUUID(), commit, head: commit, parents, parent: parents[0] ?? null, label: `Merge ${source.label}`, summary: `Merge ${source.label}`.slice(0, 200), kind: 'agent', major: false, sourceNode: target.id, createdAt: source.mergedAt, validation: source.validation };
      await this.git(['update-ref', `refs/f/version-sources/${vertex.id}`, commit]);
      if (signal?.aborted) throw new Error('Version merge cancelled');
      state.versions.push(vertex);
      state.nodes[state.nodes.findIndex(n => n.id === id)] = source; await atomicJSON(this.metadata, state);
      return { source: id, target: target.id, commit, validation: source.validation };
    });
  }
  async goalCheckpoint() {
    if (!await this.isEnabled()) return null;
    const root = await this.node('root');
    return this.validationState(root);
  }
  async recordGoal({ goal, paths, expected, signal }) {
    if (!expected) return null; // A never-enabled project is never implicitly opted in.
    const report = goal.testReport;
    if (goal.phase !== 'complete' || !report?.passed || !report.childId || !report.checks?.length || report.checks.some(c => c.passed !== true) || !report.evidence?.some(e => e.toolName === 'bash' && !e.isError)) throw new Error('A completed independent executable goal test is required');
    return this.complete({ paths, summary: goal.goal, complexity: goal.complexity, goalId: goal.id, signal }, { expected, validation: { ...report, independent: true } });
  }
  async complete({ paths, summary = '', complexity = 'simple', goalId, test, signal }, observed) {
    await this.verify();
    if (!Array.isArray(paths) || !paths.length) throw new Error('Completion requires explicit owned paths');
    paths = paths.map(cleanPath);
    if (!['simple','complex'].includes(complexity)) throw new Error('Invalid completion complexity');
    if (!observed && (!Array.isArray(test) || !test.length || test.some(s => typeof s !== 'string' || !s))) throw new Error('Completion requires an actual test command as an argv array');
    return this.exclusive(async () => {
      const state = await this.enabledState(), root = await this.node('root');
      const duplicate = goalId && state.versions.find(v => v.major && v.goalId === goalId);
      if (duplicate) return duplicate;
      const before = observed?.expected ?? await this.validationState(root);
      await this.assertValidationState(root, before);
      if (before.mergeHead || before.indexFlags.split('\0').some(entry => /^[a-zS] /.test(entry))) throw new Error('Resolve pending merge and clear assume-unchanged/skip-worktree flags before completion');
      const changed = (await this.git(['diff', '--no-renames', '--name-only', '-z', 'HEAD'])).split('\0').filter(Boolean);
      const untracked = before.untracked.map(([file]) => file);
      if ([...changed, ...untracked].some(file => !paths.some(scope => contains(scope, file)))) throw new Error('Completion changes exceed explicit owned paths; preserve and commit them separately');
      let validation = observed?.validation;
      if (!validation) {
        const output = await this.run(test[0], test.slice(1), { cwd: root.worktree, signal });
        validation = { command: test, output: String(output).slice(-12000), exitCode: 0, passed: true };
      }
      await this.assertValidationState(root, before);
      if (signal?.aborted) throw new Error('Version completion cancelled');
      if (changed.length || untracked.length) await this.commitOwned(root, paths, summary || 'Complete validated task');
      const commit = await this.git(['rev-parse', 'HEAD']);
      const files = (await this.git(['ls-tree', '-r', '--name-only', '-z', commit])).split('\0').filter(Boolean);
      if (files.some(file => secrets.test(file))) throw new Error('Snapshot includes credentials; no successful version was recorded');
      const previous = state.versions.filter(v => v.major).at(-1);
      const derived = complexity === 'complex' ? state.nodes.filter(n => n.mergedAt && (!previous || n.mergedAt > previous.createdAt)).map(n => state.versions.filter(v => v.sourceNode === n.id).at(-1)?.id).filter(Boolean) : [];
      const rootVertex = complexity === 'complex' ? state.versions.filter(v => v.sourceNode === 'root').at(-1)?.id : null;
      const legacyRoot = state.versions.filter(v => v.legacy && v.sourceNode === 'root').at(-1)?.id;
      const parents = [...new Set([previous?.id ?? legacyRoot, rootVertex, ...derived].filter(Boolean))];
      const id = 'major-' + randomUUID(), label = `v${state.versions.filter(v => v.major).length + 1}`;
      const tree = await this.git(['rev-parse', `${commit}^{tree}`]);
      const publishCommit = await this.git([...gitIdentity, '-c', 'commit.gpgsign=false', 'commit-tree', tree, ...(previous ? ['-p', previous.publishCommit] : []), '-m', label]);
      const version = { id, commit, head: commit, parents, parent: parents[0] ?? null, label, summary: Array.from(summary).slice(0, 200).join(''), kind: 'major', major: true, sourceNode: 'root', complexity, goalId, createdAt: new Date().toISOString(), validation, publishCommit };
      if (signal?.aborted) throw new Error('Version completion cancelled');
      await this.git(['update-ref', `refs/f/version-sources/${id}`, commit]);
      await this.git(['update-ref', `refs/f/version-snapshots/${id}`, publishCommit]);
      state.versions.push(version); await atomicJSON(this.metadata, state);
      return version;
    });
  }
  async publish({ version: selected, repository, authorized = false }) {
    if (authorized !== true) throw new Error('GitHub publication requires an explicit user publish action');
    await this.verify();
    const current=await this.enabledState(),workflow=current.versions.find(v=>v.id===selected && v.workflowId);
    if(workflow) {
      const { WorkflowProject }=await import('./workflow.mjs');
      return new WorkflowProject(this.project,{dataRoot:this.dataRoot,runner:this.run}).publishWorkflow(workflow,repository ?? current.workflowRepository);
    }
    return this.exclusive(async () => {
      const state = await this.enabledState();
      const version = selected ? state.versions.find(v => v.id === selected) : state.versions.filter(v => v.major).at(-1);
      if (!version?.major || !version.validation?.passed) throw new Error('Select a successfully tested major version to publish');
      // Check every exported object, including older snapshots; credentials in Git
      // development ancestors are intentionally NOT traversed or transmitted.
      const majors = state.versions.filter(v => v.major), end = majors.indexOf(version);
      let previous = null;
      for (const item of majors.slice(0, end + 1)) {
        const tree = await this.git(['rev-parse', `${item.commit}^{tree}`]);
        const exportedTree = await this.git(['rev-parse', `${item.publishCommit}^{tree}`]);
        const ancestry = (await this.git(['rev-list', '--parents', '-n', '1', item.publishCommit])).split(' ').slice(1);
        if (tree !== exportedTree || JSON.stringify(ancestry) !== JSON.stringify(previous ? [previous] : [])) throw new Error('Invalid major-only publication ancestry');
        const files = (await this.git(['ls-tree', '-r', '--name-only', '-z', item.publishCommit])).split('\0').filter(Boolean);
        if (files.some(file => secrets.test(file))) throw new Error('Publication snapshot includes credentials');
        previous = item.publishCommit;
      }
      const remotes = (await this.git(['remote'])).split('\n');
      if (!remotes.includes('origin')) {
        if (!validRepo(repository ?? '')) throw new Error('First publication needs GitHub owner/repository');
        await this.run('gh', ['repo', 'create', repository, '--private', '--source', this.project, '--remote', 'origin']);
      }
      const remote = await this.git(['remote', 'get-url', 'origin']);
      const match = /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([\w.-]+\/[\w.-]+?)(?:\.git)?$/.exec(remote);
      if (!match || !validRepo(match[1])) throw new Error('origin is not a supported github.com repository');
      const urls = [await this.git(['remote', 'get-url', '--all', 'origin']), await this.git(['remote', 'get-url', '--push', '--all', 'origin'])];
      if (urls.some(url => url.split('\n').some(value => value !== remote))) throw new Error('origin has conflicting fetch/push URLs');
      if (repository && repository !== match[1]) throw new Error('Requested repository does not match origin');
      const privacy = JSON.parse(await this.run('gh', ['repo', 'view', match[1], '--json', 'isPrivate']));
      if (privacy.isPrivate !== true) throw new Error('GitHub repository must be verified private before publication');
      // Explicit object/refspec only: no development branch, tags, force, mirror,
      // upstream mutation or ancestry rewrite. A divergent remote fails normally.
      const branch = 'f-versions';
      await this.git(['-c', 'push.followTags=false', '-c', 'core.hooksPath=/dev/null', 'push', '--no-follow-tags', '--recurse-submodules=no', 'origin', `${version.publishCommit}:refs/heads/${branch}`]);
      return { version: version.id, branch, remote, commit: version.commit, publishCommit: version.publishCommit };
    });
  }
}
