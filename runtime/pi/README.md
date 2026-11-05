# Pi：四个模型来源

在新终端中输入 `pi`。已打开的终端先运行 `source ~/.zshrc`。
进入 Pi 后输入 `/model`，按来源名称搜索：

| 来源 | 含义 | 示例 |
|---|---|---|
| `dp` | DeepSeek 官方 API | `dp/deepseek-flash`、`dp/deepseek-v4-pro` |
| `cbc` | CodeBuddy 国内版账号，通过 pi-codebuddy-sdk | `cbc/deepseek-v4.1-flash` |
| `cbi` | CodeBuddy 海外版账号，通过 pi-codebuddy-sdk | `cbi/default-model` |
| `gpt` | ChatGPT 订阅（Codex OAuth） | `gpt/gpt-6.1-sol` |

默认按 agent/settings.json 配置（当前为 `cbc/deepseek-v4.1-flash`）。模型选择器内按 Ctrl+S 保存新默认值。
也可以直接运行：

```sh
pi --model dp/deepseek-flash
pi --model cbc/deepseek-v4.1-flash
pi --model cbi/default-model
pi --model gpt/gpt-6.1-sol
pi --list-models
```

海外 CodeBuddy 账号当前被服务端识别为 `personal_free_user`；`default-model` 已验证可用，GPT 等付费模型可能返回无权限。这是海外 CodeBuddy 账号本身的权益，和 `gpt` 来源下的 ChatGPT 订阅分别计量。

## 文件位置

- `bin/pi`：终端入口，不改变当前工作目录。
- `runtime/node`：独立 Node 24.22.2。
- `node_modules`、`package-lock.json`：Pi 1.4.0、pi-codebuddy-sdk 0.4.41、CodeBuddy CLI 2.178.1 及固定依赖。
- `agent`：Pi 设置、登录凭据、会话、模型缓存、自定义来源扩展。
- `codebuddy/cbc`、`codebuddy/cbi`：分开的国内/海外 CLI 配置。
- `codebuddy/shared-runtime`：CodeBuddy 底层运行时及凭据；`fy-pi-cbc.info`、`fy-pi-cbi.info` 使用不同标识保存登录。
- `vendor/pi-codebuddy-sdk-cbc`、`vendor/pi-codebuddy-sdk-cbi`：同一固定版本 SDK 扩展的两份隔离实例，分开提供者名、API 名、模块全局状态和模型缓存。
- `scripts/build-codebuddy-providers.py`：从已安装的原版扩展重建隔离实例和对应产品配置。

为兼容 CodeBuddy 固定的数据路径，本机 `~/.codebuddy` 和 `~/Library/Application Support/CodeBuddyExtension` 是指向本目录内数据的符号链接。唯一的 shell 配置改动是 `~/.zshrc` 增加本目录 `bin` 到 PATH。

启动脚本会在没有显式终端代理设置时读取 macOS 系统 HTTPS 代理，供 ChatGPT 等服务连接。

网络规则集中在 `scripts/network.cjs`：`cbc` 国内版强制直连；`cbi` 海外版使用显式终端代理或当前 macOS 系统代理。`dp` 走国内接口直连，`gpt` 使用代理；localhost、127.0.0.1、::1 始终绕过代理。当前系统代理为 `http://127.0.0.1:7897`，脚本在每次启动时读取系统设置，无需固定端口。

若出现 `Request timeout: initialize`，表示 CodeBuddy SDK 尚未完成子进程初始化握手，不是模型生成超时。当前配置在进程启动前固定区域和登录配置，不在握手阶段再次切换区域。配置更新后退出旧 Pi（Ctrl+D）再启动 `pi`。

可检查登录/目录初始化（不发起模型推理）：

```sh
/Users/fanfy/Desktop/fy/F/runtime/pi/runtime/node/bin/node /Users/fanfy/Desktop/fy/F/runtime/pi/scripts/probe-codebuddy.mjs cbc
/Users/fanfy/Desktop/fy/F/runtime/pi/runtime/node/bin/node /Users/fanfy/Desktop/fy/F/runtime/pi/scripts/probe-codebuddy.mjs cbi
```


## 重新登录

国内版：运行 `codebuddy-cbc`，在 CLI 中输入 `/login`，选择 Chinese Site。
海外版：运行 `codebuddy-cbi`，在 CLI 中输入 `/login`，选择 International Site。
也可以双击 `login-cbc.command`、`login-cbi.command`。

ChatGPT：在 Pi 中输入 `/login`，选择 `gpt` 对应的 ChatGPT 登录。
DeepSeek：在 Pi 中输入 `/login`，选择 `dp` 更新 API 密钥。

密钥和登录状态位于权限受限的本地文件，不要分享 `agent/auth.json` 或 `codebuddy`。原有 DeepSeek 密钥文件仍在 `../auth/deepseek/deepseek-api.md`。

## 更新

依赖固定在 package.json 和 package-lock.json 中。更新前保留整个目录；更新 SDK 后运行：

```sh
/Users/fanfy/Desktop/fy/F/runtime/pi/runtime/node/bin/node --version
python3 /Users/fanfy/Desktop/fy/F/runtime/pi/scripts/build-codebuddy-providers.py
```

隔离脚本针对当前固定版本；升级 SDK 扩展时应核对源码变化，并重新验证国内与海外的登录和工具调用。

隔离脚本会保留本地工具回传修复：SDK 的流式工具调用与随后完整回复按调用 ID 去重，
工具声明、MCP 请求与结果在查询期间持续关联。MCP 请求按工具名及规范化参数匹配，
不依赖消息开始时会重置的位置游标，支持请求和结果乱序到达、并行同名工具及取消。
无法关联的请求会明确报错，不会无期限等待；已关联的长时间构建仍等待其真实结果。
重建后验证：

```sh
./runtime/node/bin/node --test scripts/test-codebuddy-tool-replay.mjs
```

24 项回归覆盖先返回结果、先进入 MCP handler、延迟 message_start、并行工具乱序、
完整回复回退、真实 MCP 传输、取消、重复请求和不同查询隔离，含 1,200 轮持续回传。
旧版的延迟 message_start 故障可用同一组测试复现，新版修复已在原会话中验证。

参考：[Pi](https://pi.dev/)、[pi-codebuddy-sdk](https://pi.dev/packages/pi-codebuddy-sdk)、[CodeBuddy 认证说明](https://www.codebuddy.ai/skills/f-maintenance/references/cli/iam)、[OpenAI 登录说明](https://learn.chatgpt.com/skills/f-maintenance/references/auth)。


## F Harness

F 自定义扩展只有 `agent/extensions/fy-harness.ts` 一个组合入口。
原有模型来源、SSH 和画板工具移至 `agent/modules/`，由 Cordis 作用域持有，行为和数据位置不变。
新增的 Skills、Subagent、Workflow 及验收命令见 [Harness](../runtime/harness/README.md)。
应用会话优先加载签名 Resources/harness，独立 CLI 使用源码 harness；用户会话与凭据均保持原路径。


CodeBuddy 冷导入的每条用户消息都会接续前一条记录的 parentId，保留跨多轮的完整可达历史。
工具调用参数及工具结果正文也进入导入记录，避免 fork 或恢复后只剩最后一轮或工具占位符。
该修复由 patch-codebuddy-tool-replay.py 与构建脚本保留，CBC/CBI 均有真实文件父链回归。
