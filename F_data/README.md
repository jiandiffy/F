# 工作区数据

实际数据默认在 `~/Library/Application Support/F/F_data`，可用 `F_DATA_DIRECTORY` 指定其他位置。本目录只提供工作区入口，不把历史、产物或数据库提交到源码版本。

每个工作区包含 `workspace.json`、SQLite `state.db`、`sessions/<id>/conversation.jsonl`、`session_apps`、`artifacts` 和 `workspace_apps`。JSONL 与 Excalidraw 入口链接已有集中存储，不复制可写状态。现有自定义画板路径优先。

浏览器继续与 Daily Paper 共用已有登录配置。PTY 进程只在存活时保留，重启后不声称恢复任意 shell 进程。命令记录与持久状态可以存入对应应用目录。
