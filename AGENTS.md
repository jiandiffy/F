# F 项目维护

维护 F 时先使用 [f-maintenance](skills/f-maintenance/SKILL.md)，并读取 [F_MAINTENANCE.md](F_MAINTENANCE.md)。
保留现有功能、项目与画板统一存储。
应用插件修改使用 [f-plugins](skills/f-plugins/SKILL.md)，接口唯一来源为 [gui-mac/PLUGIN_SPEC.md](gui-mac/PLUGIN_SPEC.md)。
UI 插件按 f-plugins 规范素材、界面和生命周期；Workflow/Agent 插件使用
[f-workflow-plugins](skills/f-workflow-plugins/SKILL.md)。先查已有功能，有则修改，没有才新增。
界面文案、开发规范和交付说明使用 [unslop](skills/unslop/SKILL.md)，删去空泛、夸张和重复表达。

在 F 内置 Agent 中更新 F，必须使用指南规定的隔离构建、测试和延迟重启流程，不能提前
终止 F 或 Agent。完成后在主对话回复 100 字以内的中文更新公告。
