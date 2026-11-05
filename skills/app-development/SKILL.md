---
name: app-development
description: 在 F 的现有 Cordis 与原生插件框架中开发应用。
---

先加载 f-maintenance 和 f-plugins。接口以 ../../ui/desktop/PLUGIN_SPEC.md 为准。先查 packages 下同类服务；UI 复用 ui/desktop 宿主，业务实现放 packages/<id>/agent 或 desktop。工具注册与订阅用 Cordis effect，卸载释放全部资源。Workflow 使用 f-workflow-plugins。运行对应原生回归与完整发布验收。
