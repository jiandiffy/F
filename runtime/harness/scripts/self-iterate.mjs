/** Run one auditable iteration through F's own model and tool runtime. */
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import { ChildRPC } from '../../../packages/side-agent/agent/rpc.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const resume = process.argv.includes('--resume-session') ? path.resolve(process.argv[process.argv.indexOf('--resume-session') + 1]) : undefined;
const directory = resume ? path.dirname(resume) : await mkdtemp(path.join(os.tmpdir(), 'f-self-iteration-'));
const reportFile = process.argv.includes('--report') ? path.resolve(process.argv[process.argv.indexOf('--report') + 1]) : path.join(directory, 'report.json');
const previous = resume ? JSON.parse(await readFile(reportFile, 'utf8')) : undefined;
const requestFile = process.argv.includes('--request-file') ? path.resolve(process.argv[process.argv.indexOf('--request-file') + 1]) : undefined;
const request = requestFile ? await readFile(requestFile, 'utf8') : undefined;
const report = { provider: 'gpt', model: 'gpt-6.1-sol', thinking: 'high', startedAt: new Date().toISOString(), tools: [], passed: false, session: resume ?? path.join(directory, 'session.jsonl'),
  ...(previous ? { priorAttempts: [...(previous.priorAttempts ?? []), { startedAt: previous.startedAt, finishedAt: previous.finishedAt, stopReason: previous.stopReason, error: previous.error, summary: previous.summary, tools: previous.tools }] } : {}) };
const tools = ['read','write','edit','bash','ls','find','grep','skill','bus','resource_scope','maintenance_scope','subagent','list_agents','send_message','interrupt_agent'];
let child;
try {
  child = new ChildRPC(path.join(root, 'runtime/agent/bin/f'), ['--session', report.session, '--provider', report.provider, '--model', report.model, '--thinking', report.thinking, '--tools', tools.join(',')], {
    cwd: root,
    env: { ...process.env, F_AGENT_DEPTH: '0', F_BOARD_DIR: path.join(directory, 'board'), F_CONVERSATION_DIR: path.join(directory, 'conversation'), F_SOURCE_ROOT: root, F_HARNESS_DIR: path.join(root, 'runtime/harness'), F_UPDATE_DELEGATED: '1' },
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
  const instruction = request ?? (resume ? `继续同一轮F自迭代。你的versions污染保护与bus白名单修改已保留；上轮因两层sandbox嵌套和墙钟超时中断，不算通过。主维护Agent已修复沙箱组合、动态工具挂卸与dataset边界，错误的测试断言位置也已修正。现在只读复查和验收，不再修改产品或测试文件。
先检查并释放你自己的遗留 resource_scope 与 maintenance_scope 租约，不能清除别人的。运行 ./runtime/node/bin/node --test runtime/harness/tests/versions*.test.mjs runtime/harness/tests/aios*.test.mjs，保留真实退出码，不可用吞错命令。然后用独立 subagent 只读复查你修的versions和bus并执行针对性测试；不要传maxDepth，默认1已禁止孙agent；它不需要申请写范围，不要向不存在的parent发消息。你是本次维护验证的主agent，外部维护者稍后发布。全部完成后必须调用skill unslop并给1000字以内中文报告，区分实际通过和仍失败项。不要构建APP、发布、重启或停掉F。` : `你正在通过 F 自身运行时，用 gpt-6.1-sol high 做用户要求的一轮自迭代。主维护Agent已完成AI OS重构，现在授权你检查、修复和验证这一轮修改。不要发布更新、不要重启或停止F，主维护Agent在你结束后统一构建验收。
先读取 AGENTS.md、skills/f-maintenance/SKILL.md、skills/f-maintenance/references/maintenance.md 和 skills/f-maintenance/references/AI_OS.md。检查范围仅 runtime/harness/src/aios/bus.mjs、runtime/harness/src/versions/project.mjs 及相应 tests，不读取凭据或私人历史。其他模块有独立Agent在修，请勿修改。
独立检测已复现两个需局部修复的问题：1) versions-adversarial.test.mjs：merge前测试可自行提交越界文件，merge后测试可git add范围外文件、秘密src/.env，然后自动merge commit带入。必须验证测试前后HEAD、index与工作树，拒绝带入且保留现场，不能reset丢数据。2) aios-adversarial.test.mjs：显式--tools时bus deactivate不移除实际schema/execute权限，白名单应为权限上限，仍要尊重停用。识别并修复这两个真实功能缺陷，不修改测试来隐藏失败。没有真实问题就报告验证结果，不凑改动。写文件前先 maintenance_scope claim，再 resource_scope claim，重新读取最新文件；做完释放两个租约。bash对F源码只读，修改只能write/edit。测试输出放/tmp。
测试命令使用 ./runtime/node/bin/node --test runtime/harness/tests/versions*.test.mjs runtime/harness/tests/aios*.test.mjs；其中dataset evidence/arxiv解析失败由另一Agent负责，你只报告这些外部失败，不修改dataset模块。用独立subagent检查你修过的部分并实际测试，子agent只读测试时不需要写源码。不要让子agent再创建子agent。完成后返回1000字以内中文报告，列出实际修复和测试、未解决问题；自然语言报告先调用unslop。`);
  const result = await child.prompt(instruction + "\n报告最后一行只写：验收通过 或 验收未通过。存在未解决产品缺陷时必须写验收未通过，不得把完成运行当作验证通过。");
  report.stopReason = result.stopReason;
  report.summary = result.output?.filter(part => part.type === 'text').map(part => part.text).join('\n');
  report.completed = result.stopReason === 'completed' && ['read', 'bash', 'skill'].every(name => report.tools.some(tool => tool.name === name && !tool.isError));
  report.passed = report.completed && /(?:^|\n)验收通过\s*$/.test(report.summary ?? '');
  if (!report.passed) throw new Error('Self-iteration did not complete with observed inspection and validation');
} catch (error) {
  report.error = error.message; process.exitCode = 1;
} finally {
  await child?.dispose();
  report.finishedAt = new Date().toISOString();
  await mkdir(path.dirname(reportFile), { recursive: true });
  await writeFile(reportFile, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify({ passed: report.passed, model: report.actualModel, report: reportFile, error: report.error }));
}
