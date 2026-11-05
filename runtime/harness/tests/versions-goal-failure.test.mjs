import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createKernel } from '../src/core/kernel.mjs';
import { mountAIOS } from '../../../packages/agent-bus/agent/index.mjs';
import { VersionProject } from '../../../packages/versions/agent/project.mjs';
import { command } from '../../../packages/data-base/agent/providers.mjs';

function host() {
  const tools = new Map(); let active = [];
  return { tools, appendEntry() {}, registerTool(tool) { tools.set(tool.name, tool); active.push(tool.name); },
    getAllTools: () => [...tools.values()], getActiveTools: () => active, setActiveTools(names) { active = names; },
    on() { return () => {}; } };
}

test('a passed executable test with version recording failure enters rework and can be repaired', async t => {
  const base = await mkdtemp(path.join(os.tmpdir(), 'f-version-goal-repair-'));
  t.after(() => rm(base, { recursive: true, force: true }));
  const folder = path.join(base, 'project'); await mkdir(folder);
  const project = new VersionProject(folder, { dataRoot: path.join(base, 'versions') });
  await project.enable();
  await writeFile(path.join(folder, 'code.txt'), 'verified output');
  await writeFile(path.join(folder, 'notes.txt'), 'preserve unowned draft');
  const pi = host(), kernel = createKernel(pi); let sequence = 0;
  t.after(() => kernel.fiber.dispose());
  const argv = [process.execPath, '-e', "require('assert').equal(require('fs').readFileSync('code.txt','utf8'),'verified output'); console.log('assertion passed')"];
  kernel.provide('subagents', { async startActivation({ label }) {
    const childId = `goal-repair-${++sequence}`;
    const result = (async () => {
      if (label === '最简化 agent') return { stopReason: 'completed', structured: { report: 'No duplicate implementation', changedPaths: [] } };
      const output = await command(argv[0], argv.slice(1), { cwd: folder });
      await kernel.emit('subagent/event', { childId, event: { type: 'tool_execution_end', toolName: 'bash', isError: false, result: { output, exitCode: 0 } } });
      return { stopReason: 'completed', structured: { passed: true, report: 'Real Node assertion passed', checks: [{ subgoal: 'code content', method: argv.join(' '), passed: true, evidence: output }] } };
    })();
    return { childId, result };
  } });
  const savedDepth = process.env.F_AGENT_DEPTH; delete process.env.F_AGENT_DEPTH;
  try { await mountAIOS(kernel, { dataRoot: path.join(base, 'goals') }); }
  finally { if (savedDepth !== undefined) process.env.F_AGENT_DEPTH = savedDepth; }
  const context = { cwd: folder, sessionManager: { getSessionId: () => 'version-goal-repair', getSessionFile: () => path.join(base, 'session.jsonl'), getBranch: () => [], getHeader: () => ({}) } };
  const flow = args => pi.tools.get('goal_flow').execute('', args, undefined, null, context);
  await flow({ action: 'begin', goal: 'Write verified code', complexity: 'simple', artifact: 'code' });
  await flow({ action: 'delivered', report: 'Code ready' });
  await flow({ action: 'simplify', paths: ['code.txt'] });
  const before = await project.git(['rev-parse', 'HEAD']);
  await assert.rejects(flow({ action: 'test', paths: ['code.txt'] }), /大版本记录失败.*修复/);
  const failed = (await flow({ action: 'status' })).details;
  assert.equal(failed.phase, 'rework');
  assert.equal(failed.testReport.passed, true, 'Do not falsify the genuinely passed test');
  assert.match(failed.versionFailure.message, /explicit owned paths/);
  assert.equal((await project.status()).versions.length, 0);
  assert.equal(await project.git(['rev-parse', 'HEAD']), before);
  assert.equal(await readFile(path.join(folder, 'notes.txt'), 'utf8'), 'preserve unowned draft');
  await project.commit({ paths: ['notes.txt'], message: 'Preserve independent draft separately' });
  await flow({ action: 'rework', route: 'repair', report: 'Unowned draft committed independently' });
  await flow({ action: 'simplify', paths: ['code.txt'] });
  const repaired = (await flow({ action: 'test', paths: ['code.txt'] })).details;
  assert.equal(repaired.phase, 'complete');
  assert.equal(repaired.version.major, true);
  assert.equal(repaired.versionFailure, undefined);
  assert.equal(repaired.feedback, '');
  assert.equal((await project.status()).versions.filter(v => v.major).length, 1);
});
