# F Harness

F 的 Agent 层使用 DeepSeek 官方 vendored Cordis；AppKit 载体实现相同的服务依赖、作用域和可逆副作用机制。
现有 Pi 会话格式、模型来源、远程工具、画板工具与原生交互保留，通过适配器接入。

官方基线为 [ce7073d51254c26cd63b22a60835b8f948deb447](https://github.com/deepseek-ai/deepseek-harness/commit/ce7073d51254c26cd63b22a60835b8f948deb447)，核对日期 2026-10-31。
`vendor/cordis/SOURCE.json` 逐文件记录 Git blob 与 SHA256；`scripts/verify-upstream.py` 在构建前验证。
签名应用只捆绑实际引用的上游代码、类型与许可证。完整参考仓库已删除，运行子集集中于 `vendor/cordis`，技能直接引用的说明保存在 `skills/dsh-doc/upstream`。

| 层 | 服务与职责 |
| --- | --- |
| `src/core/kernel.mjs` | Cordis 根上下文、可逆工具注册和提示词服务；不包含业务能力 |
| `src/core/plugin-hmr.mjs` | 显式 `/hmr` 命令、候选自身验收、旧状态迁移、失败回滚 |
| `src/index.mjs` | F 默认组合根；按持久插件开关挂载能力和适配器 |
| `src/skills/` | 官方 SkillRegistry 与 FileSystemSkillProvider；目录消息、按需正文与用户调用适配 |
| `src/subagent/` | activation、spawn/fork、持久父子目录、消息、恢复、深度/容量和取消清理 |
| `src/workflow/` | Cordis 阶段实验服务、固定起点三分支、一次孙级拆分、独立精简测试和用户候选选择 |
| `src/adapters/` | 已认证 SSH 文件系统与技能发现桥接 |
| `../runtime/agent/adapters/` | 原有模型、远程工具与画板适配器；全部由 Cordis 作用域持有 |
| `../ui/desktop/Core/Kernel.swift` | 原生服务容器；依赖缺失暂停消费者，服务替换后重新挂载 |

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
子级固定使用 cbi/deepseek-v4.1-flash/medium，CLI、设置及实际状态均核对，不能用参数切换。执行环境和对话画板保留；主线技能、共享 datasets、已启用应用工具及已批准的精确 HMR 模块可在子级使用，显式工具白名单继续生效。
默认最多4个直接并行子级，阶段实验保留一个主进程评审容量；只有工作流可进行一次孙级拆分，最多3名实验孙代理，绝对深度上限2。结构化输出使用官方 JSON Schema 子集验证。
CBI/CBC 历史导入会连接所有用户/助手记录的父链，并保留工具参数与结果正文，避免多轮 fork/冷恢复丢失早期上下文。
结果等到 `agent_settled`、进程和消息通道回收后结算；不把低层 `agent_end` 误认为最终完成。
目录身份与结果来源分开；切换主会话时先释放旧任务，晚到结果不能写入另一条会话。

这里实现 F/Pi 后端，不安装 Codex、Claude、ACP 等外部子代理后端，也不启用 Agent Teams。
独立 DSH `agentPreset` 需要完整 DSH 组装环境；F 提供方明确拒绝该选项，不伪装支持。

## Workflow

复杂目标先由 begin 保存并上传原始 Git 快照，再由 plan 提交阶段目标树。用户只批准一次。propose 对每个入选起点派出3位方向作者，简介最多200字；主 Agent 通过 review 判断方法成立且互不重复，只重提不通过者。

run 从固定提交创建独立工作树，作者自己 commit。顶层作者可 split 一次，最多3名实验孙代理，孙不能继续委派。每条分支由主 Agent 派出不同身份的精简者和测试者，两者也不能是实验者。失败退回原实验者 retry。主进程预留评审容量，孙分支评审不是实验者自行派出的孙代理。

所有分支完成后生成已上传的候选，主 Agent 应用 unslop 写最多1000字阶段报告。用户选择1至3个版本，下一阶段对每个入选版本再派3位方向作者。只有真实用户 input 可以批准目标树或选择候选，模型工具不能代替。

状态、失败、提交和审核身份持久保存。候选绑定实际 Git 提交与测试时的分支状态，其他分支提交不会使本分支验证误报失败。原始与候选快照按阶段父版本建立发布父链，排除凭据、查证私有，不上传开发祖先，不改 origin 或强推。取消保留现场并等待全部所属进程停稳。旧投票、双审批和任意 JavaScript 脚本工作流已删除。

协议见 [PLUGIN_SPEC.md 第10节](../ui/desktop/PLUGIN_SPEC.md#10-workflow-与-agent-工具插件)。阶段状态与技能均沿用真正的 Cordis 服务和可逆作用域。

## Agent 插件热替换

主对话可使用 `/hmr status`、`/hmr load <id> <sha256> <path>`、`/hmr unload <id>`。
仅针对显式审阅的本机单文件 Agent 插件，不是原生 Swift 的 HMR；不自动扫描或重启 F。
契约、信任边界、临时目录验收、异步资源回收和失败回滚的唯一规范见
[PLUGIN_SPEC.md §9](../ui/desktop/PLUGIN_SPEC.md#9-agent-插件-hmr-v1显式开发入口)。
后续符合契约的插件热替换只验收该候选；首次集成宿主或修改静态宿主仍走完整安全发布。
自包含可复制示例为 `src/core/hmr-example.mjs`。`plugin-hmr*.test.mjs` 验证真实 Cordis 与
真实 Pi SDK 的命令/工具替换、隐藏旧工具、回滚、状态、同一被测实例、异步卸载门禁与失败断言锁存；
SDK 模型流为本地 stub，不等同付费模型验收。

## 原生与分发

`F → plugin` 包含 Skills、Subagent、Workflow 开关；Workflow 依赖 Subagent。
原有应用插件可用 `requiredServices`、`providedServices`、`mount(in:)` 扩展；默认实现兼容所有现有 FPlugin。
项目改为文件夹下多会话；boardID 继续隔离会话的视角与重启状态，每条对话一块画板，底栏多进程保留。
构建把 `src/` 与捆绑全部依赖的 `dist/` 放进签名 F.app，PiRPC 传入 `F_HARNESS_DIR`，新会话加载已验证版本。
适配器仍使用现有受锁定的 Pi 安装与模型凭据；不会复制或替换用户凭据。

## 验证

在项目根目录执行：

```sh
python3 runtime/harness/scripts/verify-upstream.py
PATH="$PWD/runtime/node/bin:$PATH" npm run --prefix runtime/harness build
./runtime/node/bin/node --test runtime/harness/tests/*.test.mjs
./runtime/node/bin/node runtime/harness/tests/test-cbi.mjs --report /tmp/f-cbi-report.json
```

最后一条会调用真实 cbi/deepseek-v4.1-flash，仅使用临时项目、会话和画板。
覆盖文件工具、技能、画板编辑、子代理/消息/恢复/fork/中断、阶段实验、固定版本与候选选择、共享技能和 datasets；断言真实工具结果与磁盘状态。
阶段验收的出版传输使用隔离的本机 bare Git，不创建测试 GitHub 仓库；真实私有 GitHub 上传属于正式发布步骤。
HMR 验收还会在临时项目加载 v1 → 替换 v2 → 拒绝失败候选并回滚，逐次要求实际模型调用新工具并核对返回版本，
最后卸载并确认无残留插件。仅静态检查或 SDK stub 通过不能代替这份真实模型记录。
原生完整检查与更新使用 `python3 ui/desktop/scripts/prepare-update.py --announcement '百字内公告'`。
该入口先隔离构建，再串行运行全部回归和 CBI 验收、资源/签名验证，最后发布 pending.json。
测试记录在该次更新的 `validation/` 中；发布后由 F 等待任务和队列空闲再安装，不提前退出宿主。

实现参考：[微内核](https://github.com/deepseek-ai/deepseek-harness/blob/master/skills/f-maintenance/references/architecture.zh.md)、[Cordis](https://github.com/deepseek-ai/deepseek-harness/blob/master/skills/f-maintenance/references/cordis-primer.zh.md)、[Skills](https://github.com/deepseek-ai/deepseek-harness/blob/master/skills/f-maintenance/references/subsystems/skills.zh.md)、[Subagent](https://github.com/deepseek-ai/deepseek-harness/blob/master/skills/f-maintenance/references/subsystems/subagent.zh.md)、[Workflow](https://github.com/deepseek-ai/deepseek-harness/blob/master/skills/f-maintenance/references/subsystems/workflow.zh.md)。


## AI OS 与项目插件

`src/aios` 提供能力目录、持久目标状态机和资源申请。`bus` 按名称/描述启用工具参数；显式 CLI 白名单是权限上限，停用仍生效。`goal_flow` 的复杂任务使用阶段目标树、三条独立实验分支和一次目标树审批，每阶段由用户选择候选。代码交付经过简化和独立测试，文字交付要求成功加载 `unslop`。

`resource_scope` 在共享项目目录保存矩形与文件范围租约。画板写入在同一事务锁中检查新旧元素范围、版本，再原子保存。原生画板使用该锁并做三方合并，未确认的前端编辑会先保存再接受外部场景。Shell 保护与 F 自维护保护组合成一层 macOS sandbox，避免嵌套失败。

`src/datasets` 注册 GitHub、Zotero、arXiv 和自定义提供方；`src/versions` 管理独立项目仓库、树状工作树、范围提交和经过验证的合并。测试命令改变 HEAD、index 或工作文件时保留现场并拒绝自动合并。连接实测见 [CONNECTIONS](../skills/f-maintenance/references/CONNECTIONS.md)。

`F_BOARD_DIR` 为当前对话的画板目录；`F_CONVERSATION_DIR` 指向同一目录的会话私有状态。远程文件仍走已认证 SSH；当前远程多 Agent 写入需要远端租约提供方，运行时会明确拒绝未经协调的远端并行写入。
