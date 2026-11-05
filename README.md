# F

F 把一个目标的讨论、文件、画板和实验留在同一个项目里。项目是文件夹，下面可以开多条会话。会话各自运行 Agent，拥有自己的画板，共享经过申请的资源。

日常任务直接做。复杂任务先上传原始版本，再和你讨论阶段目标树，只批准一次。每个阶段起点派出三位方向作者，由主 Agent 审方法后各自开分支实验。分支通过独立精简与测试，收成候选并上传；你每阶段挑选一至三个版本继续。所有子代理固定使用 cbi deepseek-v4.1-flash medium。

能力都通过插件接入。Agent 先看到名称和说明，按目标启用工具、技能、数据集和子代理。详细流程见 [AI OS](skills/f-maintenance/references/AI_OS.md)。

| 目录 | 内容 |
| --- | --- |
| `packages/` | Cordis 能力、原生插件、画板前端与工作区数据库 |
| `skills/` | 按需加载的操作指导与维护文档 |
| `workflows/` | 既有阶段引擎及四种任务目标树模板 |
| `ui/` | macOS 宿主、Web 画板入口与 Chrome 扩展 |
| `vendor/` | 固定提交的 DeepSeek Harness 与 Cursor 参考源码 |
| `auth/` | 模型来源配置，凭据沿用本机私有存储 |
| `mcp/` | MCP 配置及已有 Pi 客户端的接入说明 |
| `runtime/` | Harness、Pi、故障恢复、租约、检查点及 Office 工具 |
| `profiles/` | base、gui、cli 的插件组合 |
| `F_data/` | 工作区索引入口，用户数据保存在应用数据目录 |

软件一级目录固定为上表十项。`AGENTS.md`、本说明和维护指南是根目录文档，Git 元数据不属于软件模块。`fy` 下保留旧开发入口；实现只存一份。

原生插件源码在 `packages/<id>/desktop`，`ui/desktop/Plugins` 保留宿主的构建映射。Agent 能力在 `packages/<id>/agent`，`runtime/harness/src` 的旧模块入口用于兼容既有调用。新代码直接导入实现，编辑使用规范路径。

工作区 F 指向本源码文件夹。`F_data/workspace-F` 指向应用数据目录中的工作区，包含 `workspace.json`、`state.db`、`sessions` 和 `workspace_apps`。会话历史与画板引用原文件，既有保存位置继续优先。版本历史在 `workspace_apps/versions/history.json` 引用已有 versions 数据。

维护前读 [维护指南](F_MAINTENANCE.md)。插件接口以 [PLUGIN_SPEC](ui/desktop/PLUGIN_SPEC.md) 为准。应用数据继续保存在 `~/Library/Application Support/F`，自定义画板位置继续有效。

`runtime/pi/agent` 的凭据与历史、`runtime/pi/codebuddy`、`auth/deepseek/deepseek-api.md`、`packages/zotero/api-key.md` 不进入版本库。
