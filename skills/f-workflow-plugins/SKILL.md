---
name: f-workflow-plugins
description: 为 F 编写或修改可复用 Workflow 脚本和 Agent 工具插件，规定输入素材、存放位置、工具接入、失败与取消行为。原生 UI 插件使用 f-plugins。
---

先读本技能资源根下 `../../gui-mac/PLUGIN_SPEC.md` 第 8 至 10 节，接口以规范和对应实现为准。
修改 F 自身同时使用 f-maintenance；说明和结果文案使用 unslop。

## 选择位置与准备素材

先查 `harness/src/index.mjs`、`harness/src/workflow/`、现有领域工具与项目 `.f/plugins/`。
已有功能修改原实现，保持工具名、Schema 与已有数据兼容；新增只补缺少的能力。

| 需求或素材 | 位置 |
| --- | --- |
| 一次编排 | workflow 的 script 参数，async 函数体，不加 export |
| 可复用任务说明和触发条件 | `skills/<name>/SKILL.md` |
| 编排函数体或输出模板 | 同技能 `assets/`，加载后作为 script 或交给子 Agent |
| 编写者阅读的领域约束 | 同技能 `references/`，从 SKILL.md 链接并说明何时读取 |
| 项目本地热更新工具 | `.f/plugins/<id>/v1.mjs`，遵守第 9 节 HMR 契约 |
| 随 F 发布的领域工具 | `harness/src/<domain>/index.mjs`，在组合入口挂载 Cordis 子作用域 |
| 验证与虚拟输入 | `harness/tests/<domain>.test.mjs`，使用临时目录 |
| 结果、用户数据和凭据 | 既有领域或会话存储，凭据复用现有认证服务 |

确认目标、输入文件、输出格式与成功条件。素材保持原文和来源，args 只传 JSON 与绝对路径，
文件由有权限的子 Agent 读取。不把密码、token 或无关素材塞进提示词和日志。

## Workflow 函数体

使用实际支持的 `agent`、`parallel`、`pipeline`、`phase`、`log` 与 `args`。
meta 包含 name、description，可选 whenToUse、phases；不发明工具调用或 import 钩子。
只有用户明确要求工作流或大型多 Agent 编排才启动 workflow，单步任务直接用已有工具。
多 Agent 修改仍需资源租约，子 Agent 不能越过父任务范围或发布应用。

```javascript
phase('检查素材');
const report = await agent('读取 ' + args.source + '，返回文件路径与检查结论，不修改文件。', {
  label: 'input-check', schema: { type: 'object', properties: {
    path: { type: 'string' }, summary: { type: 'string' }
  }, required: ['path', 'summary'], additionalProperties: false }
});
if (report === null) throw new Error('素材检查失败，未生成交付物');
return report;
```

子 Agent 失败返回 null，不能转成空成功；依赖步骤须等待前一步成功。
返回 JSON，不返回 NaN、函数或未等待的 Promise。默认并发上限 4，总 Agent 上限 32，
按真实依赖拆解，不用无界循环重试。后台执行用 workflow_control 查状态或取消。
断网、额度不足和上下文耗尽保留输入与已完成结果并报告失败；恢复前核对已有副作用。

## 工具插件与验证

内置工具使用 ctx.plugin、inject、ctx.tools.register、ctx.systemPrompt.register、ctx.effect，
依赖可撤回，清理由作用域管理；照既有领域入口接入，不复制内核。
项目 HMR 从 `harness/src/core/hmr-example.mjs` 改起，审阅并计算哈希后按用户请求显式加载。
只用自包含单文件，不导入依赖，不替换原生 UI；test 调用每个工具并做真实断言。
权限和外部写操作沿用现有服务边界，不因加入 workflow 获得额外授权。

运行目标套件与 `harness/tests/workflow.test.mjs`，工具插件覆盖注册、调用与卸载。
用隔离夹具检查正常输入、缺失素材、结构化输出、子任务失败、断网/额度错误、取消和再次运行，
核对无遗留进程、重复副作用和串会话回调。不吞错，不把部分完成标为成功。
维护 F 走完整隔离发布；skill 检查 frontmatter、链接与示例是否符合实际接口。
