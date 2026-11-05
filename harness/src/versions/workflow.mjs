import { lstat, realpath, unlink, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { VersionProject } from './project.mjs';
import { atomicJSON, withLock } from '../datasets/store.mjs';
import { privatePath, scanSource, assertNoSecret } from './secrets.mjs';

const identity = ['-c','user.name=F','-c','user.email=f@localhost','-c','commit.gpgsign=false'];
const validRepository = value => /^[\w.-]+\/[\w.-]+$/.test(value);

export class WorkflowProject extends VersionProject {
  constructor(project, options = {}) { super(project, options); this.signal = options.signal; }
  exclusive(run) { return withLock(this.lock, run, { timeoutMs:120000, signal:this.signal }); }
  async validationState(node) {
    const snapshot=await super.validationState(node);
    const own=(await this.enabledState()).nodes.find(n=>n.id===node.id);
    snapshot.metadataDigest=createHash('sha256').update(JSON.stringify(own)).digest('hex');
    return snapshot;
  }
  async fork({ parent, commit, versionBase, label, paths }) {
    await this.verify();
    return this.exclusive(async () => {
      const state = await this.enabledState(), ancestor = await this.node(parent);
      if (!/^[a-f0-9]{40,64}$/.test(commit) || !paths?.length || paths.some(p => !ancestor.paths.some(scope => scope === '.' || p === scope || p.startsWith(scope+'/')))) throw new Error('Experimental branch exceeds its fixed parent or file scope');
      const id = randomUUID(), branch = 'codex/f/experiment-'+id, worktree = path.join(this.workspaceRoot,id);
      await mkdir(this.workspaceRoot,{recursive:true});
      await this.git(['worktree','add','-b',branch,worktree,commit]);
      const node = { id, label, branch, parent, worktree, paths, base:commit, versionBase, createdAt:new Date().toISOString() };
      state.nodes.push(node); await atomicJSON(this.metadata,state); return node;
    });
  }
  async version(id) {
    const value = (await this.enabledState()).versions.find(v => v.id === id);
    if (!value) throw new Error('Unknown fixed workflow version');
    return value;
  }
  async scanCommit(commit) {
    const entries = (await this.git(['ls-tree','-r','-z',commit])).split('\0').filter(Boolean);
    for (const entry of entries) {
      const [header, file] = entry.split('\t'), [, type, blob] = header.split(' ');
      if (privatePath(file) || type !== 'blob') throw new Error('Publication refused: private path or unsupported Git object in ' + file);
      const data = await this.git(['cat-file','blob',blob], this.project, { trim:false, encoding:'buffer', maxBuffer:128*1024*1024 });
      assertNoSecret(data, file);
    }
  }
  async original(goalId, summary) {
    await this.enable();
    return this.exclusive(async () => {
      const state = await this.enabledState(), existing = state.versions.find(v => v.workflowId === goalId && v.baseline);
      if (existing) return existing;
      const root = await realpath(this.project), files = [];
      for (const file of (await this.git(['ls-files','--cached','--others','--exclude-standard','-z'])).split('\0').filter(Boolean)) {
        if (privatePath(file)) continue;
        let info;
        try { info = await lstat(path.join(root,file)); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
        if (!info.isFile() && !info.isSymbolicLink()) throw new Error('Snapshot needs regular source files: ' + file);
        const resolved = await realpath(path.join(root,file));
        if (!resolved.startsWith(root + path.sep)) throw new Error('Snapshot symlink leaves the project: ' + file);
        await scanSource(resolved,file); files.push(file);
      }
      const index = path.join(path.dirname(this.metadata),'f-original-' + randomUUID() + '.index');
      const env = { ...process.env, GIT_INDEX_FILE:index };
      let tree;
      try {
        await this.git(['read-tree','--empty'], this.project, { env });
        for (let n = 0; n < files.length; n += 128) await this.git(['add','--',...files.slice(n,n+128)], this.project, { env });
        tree = await this.git(['write-tree'], this.project, { env });
      } finally { await unlink(index).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
      const commit = await this.git([...identity,'commit-tree',tree,'-m','Original workflow snapshot']);
      await this.scanCommit(commit);
      const version = { id:'original-'+goalId, workflowId:goalId, baseline:true, commit, head:commit, publishCommit:commit, parents:[], parent:null, label:'原始版本', summary:summary.slice(0,200), kind:'major', major:true, sourceNode:'root', createdAt:new Date().toISOString(), validation:{ kind:'original-snapshot', passed:false } };
      await this.git(['update-ref',`refs/f/version-sources/${version.id}`,commit]);
      await this.git(['update-ref',`refs/f/version-snapshots/${version.id}`,commit]);
      state.versions.push(version); await atomicJSON(this.metadata,state); return version;
    });
  }
  async candidate({ goalId, node, baseVersion, summary, validation, expected }) {
    await this.verify();
    return this.exclusive(async () => {
      const state = await this.enabledState(), branch = await this.node(node), base = await this.version(baseVersion);
      await this.assertValidationState(branch,expected);
      if (expected.status || expected.mergeHead || !validation?.passed || !validation.simplifier || validation.simplifier === validation.childId || [validation.simplifier,validation.childId].includes(validation.experimenter)) throw new Error('Candidate requires a clean, independently simplified and tested commit');
      await this.git(['merge-base','--is-ancestor',base.commit,expected.head]);
      await this.scanCommit(expected.head);
      const tree = await this.git(['rev-parse',expected.head+'^{tree}']);
      const publishCommit = await this.git([...identity,'commit-tree',tree,'-p',base.publishCommit,'-m',summary.slice(0,200)]);
      const id = 'candidate-'+randomUUID();
      const version = { id, workflowId:goalId, commit:expected.head, head:expected.head, publishCommit, parents:[baseVersion], parent:baseVersion, sourceNode:node, label:branch.label, summary:summary.slice(0,200), kind:'major', major:true, createdAt:new Date().toISOString(), validation };
      await this.git(['update-ref',`refs/f/version-sources/${id}`,version.commit]); await this.git(['update-ref',`refs/f/version-snapshots/${id}`,publishCommit]);
      state.versions.push(version); await atomicJSON(this.metadata,state); return version;
    });
  }
  async publishWorkflow(version, repository) {
    await this.verify();
    return this.exclusive(async () => {
      const state = await this.enabledState();
      let repo = repository ?? state.workflowRepository;
      if (!repo) {
        const login = (await this.run('gh',['api','user','--jq','.login'])).trim();
        const slug = path.basename(this.project).replace(/[^\w.-]+/g,'-') || 'F';
        repo = login+'/'+slug+'-workflow-'+createHash('sha256').update(await realpath(this.project)).digest('hex').slice(0,8);
      }
      if (!validRepository(repo)) throw new Error('Workflow repository must be owner/name');
      let privacy;
      try { privacy = JSON.parse(await this.run('gh',['repo','view',repo,'--json','isPrivate'])); }
      catch (error) {
        if (!/not found|could not resolve|404/i.test(String(error.stderr ?? error.message))) throw error;
        await this.run('gh',['repo','create',repo,'--private']);
        privacy = JSON.parse(await this.run('gh',['repo','view',repo,'--json','isPrivate']));
      }
      if (privacy.isPrivate !== true) throw new Error('Workflow publication requires a verified private GitHub repository');
      const visited = new Set();
      const verify = async item => {
        if (visited.has(item.id)) return; visited.add(item.id);
        if (!item.workflowId || (!item.baseline && !item.validation?.passed)) throw new Error('Only original or independently tested workflow snapshots may be published');
        await this.scanCommit(item.commit); await this.scanCommit(item.publishCommit);
        assertNoSecret(await this.git(['cat-file','commit',item.publishCommit]),'snapshot commit metadata');
        if (await this.git(['rev-parse',item.commit+'^{tree}']) !== await this.git(['rev-parse',item.publishCommit+'^{tree}'])) throw new Error('Snapshot content changed');
        const parents = item.parents.map(id => state.versions.find(v => v.id === id));
        if (parents.some(p => !p || p.workflowId !== item.workflowId)) throw new Error('Invalid workflow snapshot ancestry');
        const hashes = (await this.git(['rev-list','--parents','-n','1',item.publishCommit])).split(' ').slice(1);
        if (JSON.stringify(hashes) !== JSON.stringify(parents.map(p => p.publishCommit))) throw new Error('Development ancestors cannot be uploaded');
        for (const parent of parents) await verify(parent);
      };
      await verify(version);
      const branch = 'f-workflow/'+version.workflowId+'/'+version.id;
      await this.git(['-c','push.followTags=false','-c','core.hooksPath=/dev/null','push','--no-follow-tags','--recurse-submodules=no','https://github.com/'+repo+'.git',version.publishCommit+':refs/heads/'+branch]);
      state.workflowRepository = repo; await atomicJSON(this.metadata,state);
      return { repository:repo, branch, commit:version.publishCommit, url:'https://github.com/'+repo+'/tree/'+branch };
    });
  }
}
