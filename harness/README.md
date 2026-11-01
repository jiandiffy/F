# F Harness

F 的 Agent 层使用 DeepSeek 官方 vendored Cordis；AppKit 载体实现相同的服务依赖、作用域和可逆副作用机制。
现有 Pi 会话格式、模型来源、远程工具、画板工具与原生交互保留，通过适配器接入。

官方基线为 [ce7073d51254c26cd63b22a60835b8f948deb447](https://github.com/deepseek-ai/deepseek-harness/commit/ce7073d51254c26cd63b22a60835b8f948deb447)，核对日期 2026-10-31。
`upstream/SOURCE.json` 逐文件记录 Git blob 与 SHA256；`scripts/verify-upstream.py` 在构建前验证。
只复制实际编译的 32 个上游源文件和相邻类型、许可证，没有复制完整 DSH 应用或启用其他子系统。

| 层 | 服务与职责 |
| --- | --- |
| `src/core/kernel.mjs` | Cordis 根上下文、可逆工具注册和提示词服务；不包含业务能力 |
| `src/core/plugin-hmr.mjs` | 显式 `/hmr` 命令、候选自身验收、旧状态迁移、失败回滚 |
| `src/index.mjs` | F 默认组合根；按持久插件开关挂载能力和适配器 |
| `src/skills/` | 官方 SkillRegistry 与 FileSystemSkillProvider；目录消息、按需正文与用户调用适配 |
| `src/subagent/` | activation、spawn/fork、持久父子目录、消息、恢复、深度/容量和取消清理 |
| `src/workflow/` | 官方 WorkflowExecution、元数据与 JSON 校验；独立 Node 进程传输和所属子级清理 |
| `src/adapters/` | 已认证 SSH 文件系统与技能发现桥接 |
| `../pi/agent/modules/` | 原有模型、远程工具与画板适配器；全部由 Cordis 作用域持有 |
| `../gui-mac/Core/Kernel.swift` | 原生服务容器；依赖缺失暂停消费者，服务替换后重新挂载 |

每条对话拥有独立 Cordis 树。服务通过稳定的 `ctx` 键查找；插件声明 `inject`；工具、事件订阅、提供方和提示词均以 effect 注册。
卸载会移除实际注册与工具可见性。调用中的工具捕获所属运行依赖，先停止并回收任务，再结束作用域。
Pi 是可替换的宿主适配器，不修改其安装包中的 Agent loop；F 继续使用现有 JSONL RPC 与历史格式。

## Skills

发现与优先级沿用 DSH：项目 `.dsh/skills`（100）、`.agents/skills`（200）、自定义（300）、用户 DSH（400）、用户 agents（500）、F 随包技能（600）。
支持顶层 `<name>/SKILL.md` 或 `<name>.md`、YAML frontmatter、严格调用开关、符号链接和按需资源基底。
`skill` 只加载允许模型调用的技能；`/<name>` 可以显式调用 user-invocable 技能。
目录以带来源元数据的持久 `skill-catalog` 消息进入对话，变动追加替换目录；正文每次重新读取。
本机目录由官方 watcher 更新；write/edit/bash 完成后通过注册表公共失效接口同步刷新。
远程项目通过 SSH 文件系统 seam 扫描远程项目及用户技能；随包技能仍从本机读取，不扫描本机远程描述目录。
远程目录在轮次开始重新发现；SSH 错误作为不完整观测保留诊断，不退回本机文件。

`f-maintenance` 和 `f-plugins` 是随包技能。维护指南和插件规范保持单一来源，由技能引用。
自维护的必要规则始终注入 F 源码任务，即使模型侧 Skills 开关关闭也保留更新保护。

## Subagent

`ctx.subagents.startActivation()` 统一拥有一次执行、结果与 dispose；`delivery: parent` 生成归属明确的完成消息，`caller` 只把结果交给工作流。
`spawn` 使用独立 Pi 会话；`fork` 复制父级已完成轮次的精确 Pi 分支，保留工具结果、压缩与树条目，不复制当前进行中的轮次。
每个子级最多一个在线 activation；父级私有目录记录 membership，后续 `send_message` 可冷恢复原会话。
只有直接父级可以列举、消息或中断所属子级；子级以 `childId: parent` 通过所属消息通道回传。
子级继承模型、思考程度、执行环境和同一条对话的画板目录；可显式选模型和初始 cwd。
默认最多 4 个直接并行子级，绝对深度上限 1。模型请求只能收紧上限。结构化输出使用官方 JSON Schema 子集验证。
CBI/CBC 历史导入会连接所有用户/助手记录的父链，并保留工具参数与结果正文，避免多轮 fork/冷恢复丢失早期上下文。
结果等到 `agent_settled`、进程和消息通道回收后结算；不把低层 `agent_end` 误认为最终完成。
目录身份与结果来源分开；切换主会话时先释放旧任务，晚到结果不能写入另一条会话。

这里实现 F/Pi 后端，不安装 Codex、Claude、ACP 等外部子代理后端，也不启用 Agent Teams。
独立 DSH `agentPreset` 需要完整 DSH 组装环境；F 提供方明确拒绝该选项，不伪装支持。

## Workflow

`workflow` 接收 `meta`、JavaScript 函数体、对象 `args` 与可选 `run_in_background`。
官方运行时提供 `agent`、`parallel`、`pipeline`、`phase`、`log`，并执行参数、JSON 返回值、并发/总量/条目上限检查。
脚本在独立 Node 进程内执行；VM 只提供脚本环境，不是安全边界。当前沿用 F 的完整文件访问执行策略，未引入 DSH 的 OS 沙箱子系统。
Host 绑定到 `ctx.subagents`，捕获工作目录和模型选择；取消会结束脚本、待启动子级和已接受子级，并等待回收。
普通子级失败由官方组合器返回 null，脚本或基础设施失败不作为部分成功。
默认 4 并行、32 个子级、256 条目；同步 VM 片段上限 1 秒，异步程序由所属运行取消。
后台运行由 F 的 `workflow_control` 列举、查询和取消，并提供有界实时进度与最终通知；没有引入 DSH Jobs 模块。
根运行的开始、成员与结束留在父会话中，程序结果在所有所属任务停稳后交付。更新协调器等待这些工作结束。

## Agent 插件热替换

主对话可使用 `/hmr status`、`/hmr load <id> <sha256> <path>`、`/hmr unload <id>`。
仅针对显式审阅的本机单文件 Agent 插件，不是原生 Swift 的 HMR；不自动扫描或重启 F。
契约、信任边界、临时目录验收、异步资源回收和失败回滚的唯一规范见
[PLUGIN_SPEC.md §9](../gui-mac/PLUGIN_SPEC.md#9-agent-插件-hmr-v1显式开发入口)。
后续符合契约的插件热替换只验收该候选；首次集成宿主或修改静态宿主仍走完整安全发布。
自包含可复制示例为 `src/core/hmr-example.mjs`。`plugin-hmr*.test.mjs` 验证真实 Cordis 与
真实 Pi SDK 的命令/工具替换、隐藏旧工具、回滚、状态、同一被测实例、异步卸载门禁与失败断言锁存；
SDK 模型流为本地 stub，不等同付费模型验收。

## 原生与分发

`F → plugin` 包含 Skills、Subagent、Workflow 开关；Workflow 依赖 Subagent。
原有应用插件可用 `requiredServices`、`providedServices`、`mount(in:)` 扩展；默认实现兼容所有现有 FPlugin。
项目、会话、boardID、底栏多进程和统一存储契约不变。
构建把 `src/` 与捆绑全部依赖的 `dist/` 放进签名 F.app，PiRPC 传入 `F_HARNESS_DIR`，新会话加载已验证版本。
适配器仍使用现有受锁定的 Pi 安装与模型凭据；不会复制或替换用户凭据。

## 验证

在项目根目录执行：

```sh
python3 harness/scripts/verify-upstream.py
PATH="$PWD/pi/runtime/node/bin:$PATH" npm run --prefix harness build
./pi/runtime/node/bin/node --test harness/tests/*.test.mjs
./pi/runtime/node/bin/node harness/tests/test-cbi.mjs --report /tmp/f-cbi-report.json
```

最后一条会调用真实 cbi/deepseek-v4.1-flash，仅使用临时项目、会话和画板。
覆盖文件工具、技能、画板编辑、子代理/消息/恢复/fork/中断、前台并发工作流和后台取消；断言真实工具结果与磁盘状态。
HMR 验收还会在临时项目加载 v1 → 替换 v2 → 拒绝失败候选并回滚，逐次要求实际模型调用新工具并核对返回版本，
最后卸载并确认无残留插件。仅静态检查或 SDK stub 通过不能代替这份真实模型记录。
原生完整检查与更新使用 `python3 gui-mac/scripts/prepare-update.py --announcement '百字内公告'`。
该入口先隔离构建，再串行运行全部回归和 CBI 验收、资源/签名验证，最后发布 pending.json。
测试记录在该次更新的 `validation/` 中；发布后由 F 等待任务和队列空闲再安装，不提前退出宿主。

实现参考：[微内核](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.zh.md)、[Cordis](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-primer.zh.md)、[Skills](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/skills.zh.md)、[Subagent](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/subagent.zh.md)、[Workflow](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/workflow.zh.md)。
