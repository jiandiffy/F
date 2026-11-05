import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { atomicJSON, withLock } from '../datasets/store.mjs';

export function boundedReport(text, limit, label = 'Report') {
  if (typeof text !== 'string' || !text.trim() || Array.from(text).length > limit) throw new Error(`${label} must contain 1–${limit} characters`);
  return text.trim();
}
export function stageTree(tree) {
  const ids = new Set(); let count = 0;
  function visit(node, depth) {
    if (!node || depth > 8 || ++count > 100 || typeof node.id !== 'string' || !/^[\w-]{1,64}$/.test(node.id) || ids.has(node.id)) throw new Error('Stage tree requires unique IDs, at most 100 nodes and depth 8');
    ids.add(node.id); boundedReport(node.title, 200, 'Stage title'); boundedReport(node.objective, 2000, 'Stage objective');
    if (node.children !== undefined && !Array.isArray(node.children)) throw new Error('Tree children must be an array');
    for (const child of node.children ?? []) visit(child, depth + 1);
  }
  visit(tree, 0);
  if (!tree.children?.length) throw new Error('The approved tree must contain stages below the root');
  return structuredClone(tree);
}
export function independentTest(report, excluded = []) {
  boundedReport(report.report, 1000, 'Test report');
  if (!report.childId || excluded.includes(report.childId) || !report.checks?.length || !report.evidence?.length) throw new Error('Independent test results require a distinct tester, subgoals and observed tool executions');
  if (report.passed && (report.checks.some(c => c.passed !== true) || !report.evidence.some(e => e.toolName === 'bash' && !e.isError))) throw new Error('A successful executable test must be observed and every subgoal must pass');
  return report;
}
export class GoalState {
  constructor({ directory, sessionId, file }) { this.file = file ?? path.join(directory, createHash('sha256').update(sessionId).digest('hex') + '.json'); }
  async read() { return readFile(this.file, 'utf8').then(JSON.parse, error => { if (error.code !== 'ENOENT') throw error; return { version: 2, goals: [], selected: null, capabilities: [] }; }); }
  async mutate(fn) {
    return withLock(this.file + '.lock', async () => {
      const state = await this.read(), value = await fn(state);
      state.version = 2; await atomicJSON(this.file, state); return structuredClone(value);
    });
  }
  async current() { const state = await this.read(); return state.goals.find(g => g.id === state.selected); }
  begin({ goal, complexity, artifact = 'other', baseline, id = randomUUID(), project, paths = ['.'], initializing = false }) {
    boundedReport(goal, 16000, 'Goal');
    if (!['simple','complex'].includes(complexity) || !['code','prose','other'].includes(artifact)) throw new Error('Invalid goal classification');
    if (complexity === 'complex' && !initializing && !baseline?.publication) throw new Error('Publish the original Git snapshot before planning a complex goal');
    return this.mutate(state => {
      const current = state.goals.find(g => g.id === state.selected);
      if (current && !['complete','archived'].includes(current.phase)) throw new Error('Finish or explicitly archive the current goal before beginning another');
      const entry = { id, goal, complexity, artifact, baseline, project, paths, phase: complexity === 'complex' ? (initializing ? 'initializing' : 'planning') : 'executing', revision: 0, stages: [], history: [], createdAt: new Date().toISOString() };
      state.goals.push(entry); state.selected = entry.id; return entry;
    });
  }
  update(id, expected, fn) {
    return this.mutate(state => {
      const entry = state.goals.find(g => g.id === id);
      if (!entry || !(Array.isArray(expected) ? expected : [expected]).includes(entry.phase)) throw new Error(`Goal must be in ${expected}`);
      fn(entry); entry.history.push({ phase: entry.phase, at: new Date().toISOString() }); return entry;
    });
  }
  plan(id, tree) { return this.update(id, ['planning','tree_review'], entry => { entry.tree = stageTree(tree); entry.phase = 'tree_review'; entry.revision++; }); }
  review({ id, revision, decision, feedback = '', selections }) {
    return this.mutate(state => {
      const entry = state.goals.find(g => g.id === id);
      if (!entry || !['tree_review','selection'].includes(entry.phase) || entry.revision !== revision) throw new Error('Review is stale or no matching stage report is awaiting review');
      if (decision === 'revise' && entry.phase === 'tree_review') { entry.feedback = boundedReport(feedback, 2000, 'Tree feedback'); entry.phase = 'planning'; }
      else if (decision === 'approve' && entry.phase === 'tree_review') {
        entry.approvedTree = structuredClone(entry.tree); entry.treeApproval = { revision, at: new Date().toISOString() }; entry.stageIndex = 0; entry.selectedVersions = [entry.baseline.id]; entry.phase = 'proposing';
      } else if (decision === 'select' && entry.phase === 'selection') {
        const stage = entry.stages.at(-1), choices = selections ?? [];
        if (!choices.length || choices.length > 3 || new Set(choices).size !== choices.length || choices.some(id => !stage.candidates.some(c => c.version?.id === id && c.phase === 'candidate' && c.publication))) throw new Error('Select one to three distinct published candidates from this stage');
        stage.selected = choices; entry.selectedVersions = choices; entry.stageIndex++;
        entry.phase = entry.stageIndex < entry.approvedTree.children.length ? 'proposing' : 'complete';
      } else throw new Error('Only tree approval or candidate selection is available at this gate');
      entry.history.push({ action: decision, revision, feedback, selections, source: 'user-command', at: new Date().toISOString() }); return entry;
    });
  }
  report(id, report) { return this.update(id, 'reporting', entry => {
    const stage = entry.stages.at(-1);
    if (!stage.candidates.length || stage.candidates.some(c => c.phase !== 'candidate' || !c.publication)) throw new Error('Every branch must close as a tested, published candidate before the stage report');
    stage.report = boundedReport(report, 1000, 'Stage report'); entry.phase = 'selection'; entry.revision++;
  }); }
  archive(id, reason) { return this.update(id, ['initializing','discussing','consensus_review','planning','plan_review','tree_review','proposing','direction_review','ready','executing','simplifying','testing','rework','reporting','selection','paused'], entry => { entry.phase = 'archived'; entry.archiveReason = boundedReport(reason, 1000); }); }
  skillUsed(name) { return this.mutate(state => { const entry = state.goals.find(g => g.id === state.selected); if (entry && name === 'unslop') entry.prosePolish = { skill: name, loadedAt: new Date().toISOString() }; return entry; }); }
  delivered(id, summary) { return this.update(id, 'executing', entry => {
    if (entry.complexity !== 'simple') throw new Error('Complex goals close through stage candidates, not the retired delivery flow');
    if (entry.artifact === 'prose' && !entry.prosePolish) throw new Error('Load and apply the unslop skill before prose delivery');
    entry.executionSummary = boundedReport(summary, 1000); entry.phase = entry.artifact === 'code' ? 'simplifying' : 'complete';
  }); }
  simplified(id, report) { return this.update(id, 'simplifying', entry => { entry.simplification = report; entry.phase = 'testing'; }); }
  tested(id, report) { return this.update(id, 'testing', entry => { entry.testReport = independentTest(report, [entry.simplification?.childId]); entry.phase = report.passed ? 'complete' : 'rework'; }); }
  rework(id, { route, reason }) { return this.update(id, 'rework', entry => {
    if (entry.complexity !== 'simple' || !['replan','repair'].includes(route)) throw new Error('Use workflow retry for a complex experiment branch');
    entry.feedback = boundedReport(reason, 1000); entry.phase = entry.artifact === 'code' ? 'simplifying' : 'executing';
  }); }
}
