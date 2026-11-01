# F 项目维护

维护 F 时先使用 [f-maintenance](skills/f-maintenance/SKILL.md)，并读取 [F_MAINTENANCE.md](F_MAINTENANCE.md)。
保留现有功能、项目与画板统一存储。
应用插件修改使用 [f-plugins](skills/f-plugins/SKILL.md)，接口唯一来源为 [gui-mac/PLUGIN_SPEC.md](gui-mac/PLUGIN_SPEC.md)。

在 F 内置 Agent 中更新 F，必须使用指南规定的隔离构建、测试和延迟重启流程，不能提前
终止 F 或 Agent。完成后在主对话回复 100 字以内的中文更新公告。
