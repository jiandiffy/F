---
name: f-plugins
description: 为 F 新增、修改或测试应用插件时使用，涵盖服务依赖、可逆注册、菜单、底栏多进程、项目与对话隔离。
---

先读取本技能资源根下的 ../../gui-mac/PLUGIN_SPEC.md；该规范是应用插件接口的唯一来源。
每个插件声明稳定身份、服务依赖与作用域；由宿主挂载和卸载，注册与订阅必须有释放操作。
保留现有 FPlugin 与底栏多进程接口，项目 URL 不能代替对话 boardID。
使用 gui-mac/tests/run-plugin-tests.py 验证开关持久化、菜单与入口、释放、真实 PTY/SSH、并发进程和项目隔离。
涉及队列、画板或更新时，按 f-maintenance 指向的完整维护指南运行相关回归。
