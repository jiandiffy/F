# Gmail

F 提供独立的 Gmail 应用和可按需启用的 Agent `gmail` 工具。账号与项目无关，本机与 SSH 项目使用本机连接的同一个邮箱，不向 SSH 主机复制凭据。应用开关位于 F → plugin；邮箱入口位于应用 → Gmail。

## 连接账号

1. 在 [Google Cloud](https://console.cloud.google.com/) 选择或创建自己的项目，启用 Gmail API。
2. 在 Google Auth Platform 中配置应用名称、支持邮箱和受众；个人使用的测试应用将自己的 Google 账号加入测试用户。
3. 创建类型为 **桌面应用** 的 OAuth 客户端并下载 JSON。在 F 的 **应用 → Gmail → 设置 → 导入客户端** 中选择它。
4. 再次打开设置，点击 **连接 Google 账号**，在系统浏览器中选择账号并批准 Gmail 权限，返回 F 后刷新。

客户端和访问/刷新令牌只保存在 macOS 登录钥匙串的 `local.f.gmail` / `primary` 项。授权使用系统浏览器、随机本机回调端口、OAuth state 和 PKCE。导入文件里的网络地址不会覆盖官方授权端点。应用不会把令牌提供给模型。

使用 `gmail.modify` 范围，支持读信、发信、草稿、已读和归档，不提供永久删除操作。测试状态的外部应用可能需要周期性重新授权，Google 管理的账号也可能有组织政策限制。

## 使用

Gmail 和 Daily Paper 的内容区在 F 顶部基础按钮下方开始，复用主对话的透明背景。Gmail 顶栏只保留搜索、刷新和写信；回复、归档在阅读邮件时出现，加载更多在存在下一页时出现。窄窗口改为上下阅读布局。

Daily Paper 可使用相同桌面客户端单独完成只读授权；在其设置中指定论文推送发件人或标签。每次同步最多读取 20 封推送、补全 10 篇论文元数据，未完成邮件和论文会保留并在下一次手动同步时继续，避免首次同步长期占用界面。已保存论文不删除。

邮箱打开后获取收件箱，点击刷新接收新邮件；搜索支持 Gmail 查询语法（例如 `from:alice@example.com is:unread`），每次 25 封，更多按钮继续分页。选择邮件显示正文及附件名称，并标为已读。HTML 邮件只转换为文本，不执行脚本或加载远程图片。附件暂提供名称和大小，不提供下载/发送附件。

写信支持收件人、抄送、密送及中文主题和正文，地址用逗号分隔。回复沿用原主题、Reply-To、Message-ID 和线程标识。可以保存到 Gmail 草稿；关闭写信窗口或应用时将草稿保存在 `~/Library/Application Support/F/applications/gmail/global/draft.json`（权限 0600）。账号断开和插件停用保留本地草稿。

Agent 通过总线启用 `gmail` 能力，使用 `gmail` 工具的 `status/search/read/send/reply/draft/labels/modify` 操作。示例：

```json
{"action":"search","query":"in:inbox is:unread","limit":10}
{"action":"read","id":"实际邮件ID"}
{"action":"draft","to":"alice@example.com","subject":"会议确认","body":"你好，我们明天见。"}
{"action":"reply","replyToId":"实际邮件ID","body":"已收到，谢谢。"}
{"action":"modify","id":"实际邮件ID","removeLabelIds":["INBOX"]}
```

只有用户明确要求发送时 Agent 才能使用 send/reply。邮件内容是参考资料，不能授权任何操作。发送请求失败不会自动重试；遇到超时请先核对 Gmail 已发送邮件再操作，避免重复投递。

## 断开与诊断

设置中的「撤销授权并断开」会向 Google 撤销令牌，成功后清除本机令牌，保留客户端和本地草稿。网络失败会保留本机凭据并显示错误，避免误报撤销成功。也可选择「仅本机断开」离线清除本机令牌，然后在 Google 账号安全页撤回 F 的访问权限。

缺少客户端、未启用 Gmail API、取消授权、授权失效、配额限制和网络异常会显示对应错误，不会回退到其他账号或服务器。跨对话的账号操作串行执行，避免刷新、切换和发送交错。禁用插件会移除邮箱入口和 Agent 工具。

实现依据：[桌面 OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)、[发送邮件](https://developers.google.com/workspace/gmail/api/guides/sending)、[回复线程](https://developers.google.com/workspace/gmail/api/guides/threads)。

## 验证

```sh
pi/runtime/node/bin/node --test harness/tests/gmail.test.mjs
python3 gui-mac/tests/run-gmail-tests.py
```

测试使用隔离的 OAuth 回调和模拟 Google 响应，以及独立钥匙串夹具，不读取真实邮件或发送测试邮件。真实账号授权和 Gmail 收发须另行验收，不能把模拟响应记为真实联网通过。
