---
name: f-orchestrator
description: 根据目标选择单 Agent 或研究与专家协作流程，管理共识、技术报告、资源租约、简化和独立验收。
---

F 的总线以会话为单位，项目文件夹与画板由多个会话共享。

1. 调用 `goal_flow begin`：简单目标选 simple，研究或跨领域算法架构选 complex；代码交付标 code，文字交付标 prose。
2. 用 `bus list` 读取插件 name/description，按目标 activate 所需能力。工具、技能、应用、数据库不是默认全部参与。
3. complex 调用 `goal_flow discuss`。运行时启动研究员和三名不同领域专家，随后让专家阅读候选方案独立投票；至少两人选同一方案才提交不超过200字的共识。
4. 等待用户输入返回值中的 `/goal approve <id> <revision>`，或 `/goal revise <id> <revision> 修改意见`。用户拒绝共识时重新讨论，不能自己批准。
5. 共识通过后主 Agent 用 `goal_flow plan` 提交不超过1000字的技术报告。用户再次审核后才能执行。
6. 画板写入必须 `resource_scope claim` 申请矩形；多 Agent 文件写入声明相对路径。得到租约后重新读取；不要覆盖租约前的旧快照。转授范围后父 Agent 不能继续编辑，结束时 release。
7. 执行后 `goal_flow delivered`。代码工程必须 `simplify`，由独立子 Agent 删除确定冗余的代码和遮蔽错误的防御处理，保留必要的外部边界错误处理。
8. `goal_flow test` 让另一位 Agent 按目标设计子目标，并真正运行验证；代码修改使用暴力、随机和边界测试。测试报告不超过1000字。失败后主 Agent 判断 `rework repair` 或 `rework replan`。
9. 自然语言交付在最终稿使用已安装的 Cursor unslop 技能；未安装不能宣称执行。代码、论文数据集引用真实来源，来源信号缺失就保持未知，不能编造论文影响力或性能。

状态机、审核记录与能力选择持久保存。租约不因超时抢占；崩溃后由原会话恢复释放。工具层租约防止协作误写，不替代多用户操作系统安全隔离。
