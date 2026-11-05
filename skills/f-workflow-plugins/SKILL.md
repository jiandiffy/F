---
name: f-workflow-plugins
description: 为 F 修改阶段实验工作流或 Agent 工具插件，规定目标树、素材、固定版本、候选审核、模型约束和可逆 Cordis 接入。原生 UI 插件使用 f-plugins。
---

先读 `../../ui/desktop/PLUGIN_SPEC.md` 第8至10节。修改 F 自身同时使用 f-maintenance；文案和报告应用 unslop。已有能力修改原实现，缺少时才新增，不另建一套编排器。

| 内容 | 位置 |
| --- | --- |
| 阶段、分支与审核运行时 | `workflows/engine/`，通过 Cordis Service、inject 和 effect 管理 |
| 持久目标树与用户选择 | `packages/agent-bus/agent/state.mjs`，只从真实用户 input 跨越用户审批门 |
| 原始版本、固定起点、候选和私有发布 | `packages/versions/agent/workflow.mjs` |
| 子代理模型、深度和继承 | `packages/side-agent/agent/`，由运行时强制约束 |
| 可复用任务规范与素材模板 | `skills/<name>/SKILL.md`，模板放 assets，领域说明放 references |
| 项目本地热更新工具 | `.f/plugins/<id>/v1.mjs`，沿用第9节哈希与验收契约 |
| 内置工具与注册 | `runtime/harness/src/<domain>/` 和 `runtime/harness/src/index.mjs` |
| 回归和输入夹具 | `runtime/harness/tests/`，输出、临时仓库与测试 datasets 放临时目录 |

准备真实输入、目标、允许修改路径、验收方法和素材来源。目标树包含唯一 id、title、objective 和可选 children，根的 children 按顺序对应阶段。工具用 plan 接收 tree，不再接收 JavaScript script、parallel 或 pipeline 函数体。

复杂流程固定为 begin 上传原始版本、plan 与一次用户批准、propose 三方向、review 由主 Agent 判方法、run 实验、独立精简与测试、report 阶段报告、用户选择1至3个候选，再进入下一阶段。
每个入选起点都派3位作者。方向简介最多200字，阶段报告最多1000字。拒绝方向只重提该作者，测试失败 retry 恢复原实验者。不能让模型工具自己批准目标树或选版本。

实验分支必须从固定提交创建，作者自己 commit。顶层作者最多使用一次 split，最多3名实验孙代理；孙不能继续委派。所有分支都要通过不同于实验者的精简者与测试者，两种评审不能由同一身份担任。审核绑定实际提交，测试期间改动 HEAD、index 或工作文件必须失败。
子代理统一为 cbi / deepseek-v4.1-flash / medium，不能只靠提示词约束。保留主线 skills、datasets、已启用应用和工具；工具白名单、插件禁用和主线只读约束必须继续生效。

GitHub 只传原始快照及审核通过的候选快照，按阶段父版本建立快照父链，不传开发提交祖先。先排除凭据路径，再扫描内容；目的仓库必须查证私有。发布失败保留本地提交和失败证据，不清空工作树或强推。

工具插件沿用 ctx.plugin、inject、ctx.tools.register、ctx.systemPrompt.register 和 ctx.effect。HMR 仍是显式审阅的自包含模块，父会话已批准的精确模块可继承到子作用域，重启不会自动执行磁盘插件。

验证实际 Git 分支、用户审批、失败打回、深度与身份、私有发布和凭据拒传；补取消、断网和恢复检查。运行 workflow、subagent、aios、versions 套件，并用真实固定模型验证主线 skill 热更新、共享 dataset 与工具继承。原生 F 更新继续走完整隔离构建和延迟重启。
