# Daily Paper

只处理 Gmail `daily papers` 分类内最新一封邮件。分类不存在、为空或没有论文链接时保留当前批次，不退回发件人搜索或全邮箱扫描。保留旧数据 schema 1、readonly OAuth 及主对话既有论文上下文的兼容接口。

点击“更新论文”后，先实际获取各论文全文（alphaXiv全文文本，或可读的arXiv HTML），摘要和登录页不算正文。以全文及可用的alphaXiv参考分析为依据，使用 `cbi/deepseek-v4.1-flash` 生成中文深入解读。模型无文件、Shell、MCP等工具权限，邮箱身份不进入模型提示。没有来源的实验数字、图片、视频不应被生成；超过360,000字符的模型输入会明确标注截取，完整文本仍保存在本地。

每篇文章在 `PluginStorage.directory(for: "daily-paper")/batches/<批次>/<论文>/` 中保存：

- `paper.md`：实际读取的论文正文；可下载时另存 `paper.pdf`。
- `alphaxiv-reference.md`：可获取时的alphaXiv参考分析。
- `media-*`：有来源的论文插图和项目视频；图片显示副本缩到最长边1600像素，卡片只解码340像素缩略图。无可获取视频时明确说明。
- `analysis.json`、`index.html`：指定模型的分析及直接可读的HTML页面。
- `complete.json`：单篇完成标记，供失败重试恢复，不作为可执行内容。

卡片复用可见行；点击后直接在Daily Paper中显示本地分析，用简洁文字返回列表。首批迁移时可先预览已完成卡片，旧数据文件仍保留到整批提交。Side Agent每次请求读取当前页面的论文与中文分析上下文，不包含邮箱身份。主对话、队列、草稿和画板不受影响。HTML所有模型文本均转义，禁用脚本、表单、任意iframe和远程自动加载；媒体是受限本地文件，视频 `preload=none`，离开页面释放WebKit视图。页面保留论文、alphaXiv和媒体来源链接。

更新最多并行两篇，不会为整个库创建图片和视图。HTTP精确限制可信主机、重定向、响应大小，图片另限像素数量；正文和媒体不执行邮件HTML。使用当前Daily Paper的macOS Keychain readonly授权，不读取主Gmail应用的modify凭据，不发送、删除、归档或设为已读。

一批的全部可读文章分析完成后，再次确认分类最新邮件未变化，原子替换 `state.json`，然后删除带本应用批次标记的旧文件夹及旧缓存；失败或取消保留旧一批和已完成单篇。不会清理用户其他目录、项目、会话或画板。每个自然日（Asia/Shanghai）生成一次，同日完整批次复用已有页面；新一日重新分析。

在 F 设置中开启“每日09:00自动更新”后，F 自行注册并管理 `local.f.app.daily-paper.updater` 用户级 launchd 任务，执行签名 F 程序的 `--daily-paper-update` 后台入口。无需 Codex，也不要求打开 F 窗口；电脑需开机并登录。09:00触发，睡眠错过后补更，未完成时每15分钟重试；入口以Asia/Shanghai判断是否到期，当天成功后不重复。关闭开关或禁用插件移除该任务，关闭 F 窗口不会关闭每日更新。任务通过现有只读凭据和同一个导入器执行，不修改主对话、队列或模型选择。

`update-status.json` 记录进度和失败原因，F 页面在显示时读取状态；单篇完成文件供恢复。更新协调器会等待论文任务结束，后台入口在存在待安装应用更新时不会启动新任务，避免替换正在使用的资源。在“应用 → Daily Paper”中可手动更新、取消当前操作或打开论文文件夹。

验证：

```sh
runtime/node/bin/node --test runtime/harness/tests/daily-paper.test.mjs runtime/harness/tests/gmail.test.mjs
python3 ui/desktop/Plugins/DailyPaper/run-tests.py
python3 ui/desktop/tests/run-daily-paper-tests.py
```

离线测试覆盖只读最新分类邮件、正文门槛、原子替换与过期清理、失败恢复、旧批保留、来源和像素边界、HTML转义、本地页面直接显示及禁用页面脚本；调度测试覆盖北京时间09:00门槛、同日跳过、下一日到期、幂等注册、开关卸载，并以独立无害任务验证真实launchd注册/卸载。保留原有OAuth/数据兼容测试和10,000篇论文、40次滚动/缩放、512MiB预算的独立内存回归。真实模型及用户邮箱验收必须另记证据，不能把离线夹具当作真实联网通过。
