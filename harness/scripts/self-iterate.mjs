/** Run one auditable iteration through F's own model and tool runtime. */
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import { ChildRPC } from '../src/subagent/rpc.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const directory = await mkdtemp(path.join(os.tmpdir(), 'f-self-iteration-'));
const reportFile = process.argv.includes('--report') ? path.resolve(process.argv[process.argv.indexOf('--report') + 1]) : path.join(directory, 'report.json');
const report = { provider: 'gpt', model: 'gpt-6.1-sol', thinking: 'high', startedAt: new Date().toISOString(), tools: [], passed: false, session: path.join(directory, 'session.jsonl') };
const tools = ['read','write','edit','bash','ls','find','grep','skill','bus','resource_scope','maintenance_scope','subagent','list_agents','send_message','interrupt_agent'];
let child;
const timeout = setTimeout(() => { report.error = 'Self-iteration exceeded 30 minutes'; void child?.dispose(); }, 30 * 60_000);
try {
  child = new ChildRPC(path.join(root, 'pi/bin/pi'), ['--session', report.session, '--provider', report.provider, '--model', report.model, '--thinking', report.thinking, '--tools', tools.join(',')], {
    cwd: root,
    env: { ...process.env, F_BOARD_DIR: path.join(directory, 'board'), F_CONVERSATION_DIR: path.join(directory, 'conversation'), F_SOURCE_ROOT: root, F_HARNESS_DIR: path.join(root, 'harness'), F_UPDATE_DELEGATED: '1' },
    onEvent(event) {
      if (event.type === 'tool_execution_end') {
        report.tools.push({ name: event.toolName, isError: !!event.isError });
        console.log(`${event.isError ? 'FAIL' : 'TOOL'} ${event.toolName}`);
      }
    },
  });
  const state = await child.request('get_state');
  if (state.model?.provider !== report.provider || state.model?.id !== report.model || state.thinkingLevel !== 'high') throw new Error('The requested model or thinking level is not active');
  report.actualModel = state.model.id; report.actualThinking = state.thinkingLevel;
  const result = await child.prompt(`你正在通过 F 自身运行时，用 gpt-6.1-sol high 做用户要求的一轮自迭代。主维护Agent已完成AI OS重构，现在授权你检查、修复和验证这一轮修改。不要发布更新、不要重启或停止F，主维护Agent在你结束后统一构建验收。
先读取 AGENTS.md、skills/f-maintenance/SKILL.md、F_MAINTENANCE.md 和 docs/AI_OS.md。检查范围仅 harness/src/aios、harness/src/datasets、harness/src/versions、pi/agent/modules/fy-whiteboard.ts 及相应 tests，不读取凭据或私人历史。
识别真实功能缺陷或可删除的冗余，重点是工具门控、租约、审批状态、数据证据、Git范围提交。最多修复两个经过测试复现的问题。没有真实问题就报告验证结果，不凑改动。写文件前先 maintenance_scope claim，再 resource_scope claim，重新读取最新文件；做完释放两个租约。bash对F源码只读，修改只能write/edit。测试输出放/tmp。
用独立subagent检查你修过的部分并实际测试，子agent只读测试时不需要写源码。不要让子agent再创建子agent。完成后返回1000字以内中文报告，列出实际修复和测试、未解决问题；自然语言报告先调用unslop。`);
  report.stopReason = result.stopReason;
  report.summary = result.output?.filter(part => part.type === 'text').map(part => part.text).join('\n');
  report.passed = result.stopReason === 'completed' && report.tools.some(tool => tool.name === 'read' && !tool.isError) && report.tools.some(tool => tool.name === 'bash' && !tool.isError);
  if (!report.passed) throw new Error('Self-iteration did not complete with observed inspection and validation');
} catch (error) {
  report.error = error.message; process.exitCode = 1;
} finally {
  clearTimeout(timeout); await child?.dispose();
  report.finishedAt = new Date().toISOString();
  await mkdir(path.dirname(reportFile), { recursive: true });
  await writeFile(reportFile, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify({ passed: report.passed, model: report.actualModel, report: reportFile, error: report.error }));
}
