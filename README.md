# F

F 把一个目标的讨论、文件、画板和实验留在同一个项目里。项目是文件夹，下面可以开多条会话。会话各自运行 Agent，共享项目画板和经过申请的资源。

日常任务直接做。复杂任务先上传原始版本，再和你讨论阶段目标树，只批准一次。每个阶段起点派出三位方向作者，由主 Agent 审方法后各自开分支实验。分支通过独立精简与测试，收成候选并上传；你每阶段挑选一至三个版本继续。所有子代理固定使用 cbi deepseek-v4.1-flash medium。

能力都通过插件接入。Agent 先看到名称和说明，按目标启用工具、技能、数据集和子代理。详细流程见 [AI OS](docs/AI_OS.md)。

| 目录 | 内容 |
| --- | --- |
| `gui-mac/` | 原生界面、项目与会话、应用插件、更新 |
| `harness/` | Cordis、总线、状态机、租约、数据集和版本管理 |
| `skills/` | 自维护、插件规范、编排与文字交付技能 |
| `pi/` | F 的 Agent 运行时与模型来源，包含忽略的本机凭据和历史 |
| `whiteboard/` | 可编辑无限画板 |
| `vendor/` | 固定提交的 DeepSeek Harness 与 Cursor 参考源码 |
| `docs/` | 设计与验收记录 |

源码统一放在 `fy/F`。`fy` 下的旧入口是兼容链接，现有应用、会话和本机配置仍可找到原路径。

维护前读 [维护指南](F_MAINTENANCE.md)。插件接口以 [PLUGIN_SPEC](gui-mac/PLUGIN_SPEC.md) 为准。应用数据继续保存在 `~/Library/Application Support/F`，自定义画板位置继续有效。

`pi/agent` 的凭据与历史、`pi/codebuddy`、`dsh/deepseek-api.md`、`zotero/api-key.md` 不进入版本库。
