# F Agent 运行时

这里提供 F 的会话宿主、模型适配器和命令行入口。Pi 1.4.0 是固定的 npm 依赖，负责 Agent loop、JSONL 会话与 RPC；删除该依赖会中断现有对话、恢复和工具调用。F 不保留单独的 Pi 项目或另一份 Agent 引擎。

- `bin/f` 是 F 命令行入口；`bin/pi` 是同一入口的兼容链接。
- `extensions/fy-harness.ts` 加载 F 的 Cordis 组合，`adapters/` 接入模型、SSH、MCP 和画板。
- `providers/cbc`、`providers/cbi` 是固定 SDK 的隔离适配器，保持不同登录区域和模块状态。`scripts/build-codebuddy-providers.py` 可重建本地修复。
- `package.json`、`package-lock.json` 固定宿主与模型 SDK 依赖，第三方许可证随依赖保留。
- Node 统一位于 `runtime/node`。
- `state`、`codebuddy` 链接到 `~/Library/Application Support/F/agent` 与 `auth/codebuddy`。凭据、历史和用户配置只有这一份，不进入代码仓库。

四个模型来源保持不变：`dp` 为 DeepSeek，`gpt` 为 ChatGPT，`cbc`、`cbi` 分别为 CodeBuddy 国内、海外账户。认证标识保留，已有登录继续有效。

在项目根目录运行：

```sh
runtime/agent/bin/f --list-models
python3 runtime/agent/scripts/build-codebuddy-providers.py
runtime/node/bin/node --test runtime/agent/scripts/test-codebuddy-tool-replay.mjs
```

`runtime/agent/bin/codebuddy-cbc` 和 `codebuddy-cbi` 保留登录入口。网络策略仍由 `scripts/network.cjs` 统一处理，国内直连，海外读取当前系统代理，本机回环地址绕过代理。F 的插件、技能和工作流实现见 `runtime/harness/README.md`。
