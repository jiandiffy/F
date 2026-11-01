import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

export function boundedReport(text, limit, label = 'Report') {
  if (typeof text !== 'string' || !text.trim() || Array.from(text).length > limit) throw new Error(`${label} must contain 1–${limit} characters`);
  return text.trim();
}
const phases = new Set(['discussing','consensus_review','planning','plan_review','executing','simplifying','testing','rework','complete']);
export class GoalState {
  constructor({ directory, sessionId }) { this.file = path.join(directory, createHash('sha256').update(sessionId).digest('hex') + '.json'); this.queue = Promise.resolve(); }
  async read() { return readFile(this.file, 'utf8').then(JSON.parse, error => { if (error.code !== 'ENOENT') throw error; return { version: 1, goals: [], selected: null, capabilities: [] }; }); }
  mutate(fn) {
    const running = this.queue.then(async () => {
      const state = await this.read(), value = await fn(state);
      await mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
      const temporary = this.file + '.' + randomUUID() + '.tmp';
      await writeFile(temporary, JSON.stringify(state, null, 2), { mode: 0o600 }); await rename(temporary, this.file);
      return structuredClone(value);
    });
    this.queue = running.catch(() => {}); return running;
  }
  async current() { const state = await this.read(); return state.goals.find(g => g.id === state.selected); }
  begin({ goal, complexity, artifact = 'other', domains = ['物理','数学','计算机'] }) {
    boundedReport(goal, 16000, 'Goal');
    if (!['simple','complex'].includes(complexity) || !['code','prose','other'].includes(artifact)) throw new Error('Invalid goal classification');
    if (domains.length !== 3 || new Set(domains).size !== 3 || domains.some(d => !d.trim())) throw new Error('Choose three distinct expert domains');
    return this.mutate(state => {
      if (state.goals.some(g => g.id === state.selected && g.phase !== 'complete')) throw new Error('Finish the current goal before beginning another');
      const entry = { id: randomUUID(), goal, complexity, artifact, domains, phase: complexity === 'complex' ? 'discussing' : 'executing', revision: 0, rounds: [], history: [], createdAt: new Date().toISOString() };
      state.goals.push(entry); state.selected = entry.id; return entry;
    });
  }
  update(id, expected, fn) {
    return this.mutate(state => {
      const entry = state.goals.find(g => g.id === id);
      if (!entry || entry.phase !== expected) throw new Error(`Goal must be in ${expected}`);
      fn(entry);
      if (!phases.has(entry.phase)) throw new Error('Invalid goal phase');
      entry.history.push({ phase: entry.phase, at: new Date().toISOString() }); return entry;
    });
  }
  consensus(id, { research, candidates, votes }) {
    return this.update(id, 'discussing', entry => {
      if (candidates.length !== 3 || new Set(candidates.map(c => c.childId)).size !== 3 || votes.length !== 3 || new Set(votes.map(v => v.childId)).size !== 3) throw new Error('Three independent expert results are required');
      for (const vote of votes) if (!candidates.some(c => c.childId === vote.childId) || !candidates.some(c => c.childId === vote.proposalId)) throw new Error('Vote is not from a participating expert or names an unknown proposal');
      const agreed = candidates.find(c => votes.filter(v => v.proposalId === c.childId).length >= 2);
      entry.rounds.push({ research, candidates, votes });
      if (!agreed) { entry.feedback = '尚无两名专家选择同一方案；继续讨论。'; return; }
      entry.consensus = { proposalId: agreed.childId, supporters: votes.filter(v => v.proposalId === agreed.childId).map(v => v.childId), report: boundedReport(agreed.report, 200, 'Consensus report') };
      entry.phase = 'consensus_review'; entry.revision++;
    });
  }
  plan(id, report) { return this.update(id, 'planning', entry => { entry.technicalReport = boundedReport(report, 1000, 'Technical report'); entry.phase = 'plan_review'; entry.revision++; }); }
  review({ id, revision, decision, feedback = '' }) {
    return this.mutate(state => {
      const entry = state.goals.find(g => g.id === id);
      if (!entry || !['consensus_review','plan_review'].includes(entry.phase) || entry.revision !== revision) throw new Error('Review is stale or no matching report is awaiting review');
      if (!['approve','revise'].includes(decision)) throw new Error('Invalid review decision');
      if (decision === 'revise' && !feedback.trim()) throw new Error('Please include the requested changes');
      entry.history.push({ action: decision, revision, feedback, source: 'user-command', at: new Date().toISOString() });
      entry.feedback = feedback;
      entry.phase = decision === 'approve' ? (entry.phase === 'consensus_review' ? 'planning' : 'executing') : (entry.phase === 'consensus_review' ? 'discussing' : 'planning');
      return entry;
    });
  }
  skillUsed(name) {
    return this.mutate(state => {
      const entry = state.goals.find(g => g.id === state.selected);
      if (entry && name === 'unslop') entry.prosePolish = { skill: name, loadedAt: new Date().toISOString() };
      return entry;
    });
  }
  delivered(id, summary) { return this.update(id, 'executing', entry => {
    if (entry.artifact === 'prose' && !entry.prosePolish) throw new Error('Load and apply the unslop skill before prose delivery');
    entry.executionSummary = boundedReport(summary, 1000, 'Execution summary');
    entry.phase = entry.artifact === 'code' ? 'simplifying' : (entry.complexity === 'complex' ? 'testing' : 'complete');
  }); }
  simplified(id, report) { return this.update(id, 'simplifying', entry => { entry.simplification = report; entry.phase = 'testing'; }); }
  tested(id, { childId, passed, report, checks, evidence }) {
    return this.update(id, 'testing', entry => {
      boundedReport(report, 1000, 'Test report');
      if (!childId || !Array.isArray(checks) || !checks.length || !Array.isArray(evidence) || !evidence.length) throw new Error('Independent test results require subgoals and observed tool executions');
      if (childId === entry.simplification?.childId) throw new Error('The tester must be independent of the simplifier');
      if (passed && checks.some(check => check.passed !== true)) throw new Error('Every subgoal must pass before completion');
      if (passed && !evidence.some(item => !item.isError && (entry.artifact !== 'code' || item.toolName === 'bash'))) throw new Error('A successful executable test must be observed before code completion');
      entry.testReport = { childId, passed, report, checks, evidence };
      entry.phase = passed ? 'complete' : 'rework';
    });
  }
  rework(id, { route, reason }) {
    return this.update(id, 'rework', entry => {
      if (!['replan','repair'].includes(route)) throw new Error('Choose replan or repair');
      entry.feedback = boundedReport(reason, 1000, 'Rework reason');
      entry.phase = route === 'replan' ? (entry.complexity === 'complex' ? 'discussing' : 'executing') : (entry.artifact === 'code' ? 'simplifying' : 'executing');
    });
  }
}
