# F 应用插件规范 v1

F 当前内置的功能插件是画板、浏览器、Daily Paper、Gmail、终端、SSH、side agent，以及无视图的 Skills、Subagent、Workflow。聊天、项目、历史、存储和窗口由宿主管理。
定时任务和桌面操作也是无视图服务，经同一 Cordis 总线启用并随作用域释放。桌面操作使用 F 已有的系统权限；定时任务保留失败记录，进程退出后不自动重放中断的命令。

实现位于 `packages/<id>/desktop` 或 `packages/<id>/agent`。`ui/desktop/Plugins/<Name>` 和 `runtime/harness/src/<domain>` 是兼容入口。构建从映射收集原生源码，签名资源保留同一目录关系，避免维护第二套实现。新增或编辑源码使用 packages 中的规范路径。
插件为随应用编译的 Swift 模块；此版本不自动加载外部动态库或执行下载的插件。

## 1. 注册与身份

在 `ui/desktop/Plugins/<Name>/` 中放置 Swift 源码，实现 `FPlugin`，并在
`Core/BuiltInPlugins.swift` 的 `make(project:)` 中注册。构建脚本自动编译该目录下的源码。

- `id`：稳定且全局唯一，使用小写字母、数字、点或连字符；发布后保持不变。
- `title`：应用栏、菜单和 plugin 开关使用的名称。
- `symbol`：单色 SF Symbol；使用黑、白、灰的系统动态颜色，保持现有界面的字体和间距。
- `placement = .workspace`：自动出现在左侧“应用”下面，并占用主工作区。
  主对话以外的工作区界面共用右下角的窗口级对话框（`AgentOverlayDock`），插件不要再创建
  自己的模型输入框；输入框上方的折叠对话由宿主管理。
- `placement = .bottom`：自动出现在底栏选择页和新建菜单。没有进程时展开底栏先选择；
  选择后底栏仍在窗口底部，左侧是纵向进程标签，右侧是当前进程页面。再次展开时若已有
  进程则直接显示标签和页面。

底栏模块可以实现 `FProcessProvider`，让同一个模块同时运行多个独立进程：

```swift
protocol FProcessProvider {
    var processDefaultName: String { get }   // 默认进程名，例如 terminal / ssh / side agent
    func makeProcess(project: URL) -> FPlugin // 每次返回拥有独立视图和资源的新实例
}
```

未实现该协议的底栏模块仍会自动出现在选择页和新建菜单，但只保留一个实例。停靠区负责
标签、改名、关闭和布局，插件不直接操作其他进程的界面。需要主对话上下文的进程可实现
`FContextualProcess`，每次请求都会重新读取 `contextProvider`，并通过
`boardDirectoryProvider` 与当前对话使用同一块画板。仍有任务或队列的进程可实现
`FProcessActivity`，让更新协调器等待其结束。

## 2. 项目关联

通过 `projectAssociation` 明确选择：

| 值 | 行为 | 数据位置 |
| --- | --- | --- |
| `.independent`（默认） | 独立应用，不随项目切换 | `PluginStorage.directory(for: id)` |
| `.project` | 每次项目切换收到 `projectDidChange(_:)` | `PluginStorage.directory(for: id, project: project)` |

宿主提供的项目 URL 是稳定标识。本机项目对应实际目录；远程项目对应 F 软件数据目录中的
远程项目描述，可用 `RemoteProjects.load(project)` 获取主机与远程路径。
远程文件操作使用已认证 SSH 会话，不把项目描述目录误当作远程工作目录。

插件自行创建存储目录，并采用临时文件加原子替换保存。禁止通过显示名称识别项目，
也不要把项目应用数据散放到源码目录。关闭插件不删除数据。画板沿用原有 `BoardStore`，
保持本机和远程执行环境的标识、统一存储、保存位置设置及旧数据兼容。

项目是一个本机文件夹或“SSH 端点＋远程路径”，一个项目下有多条独立会话。
`WhiteboardPlugin.bindConversation(boardID, project:)` 保留对话身份用于输入和恢复，场景统一在
`BoardStore.directory(for: project)/scene.json`。`ConversationBoards.directory` 只存会话私有状态。
旧会话 scene 合并到项目 scene 后仍保留原档；迁移记录防止重复合并。队列、Agent、模型和草稿不共享。

文件面板由 `FilesPlugin` 提供，作为 `.service` 的侧栏视图挂载。文本在面板编辑，PDF/Office
无额外外围框预览，复杂文档可从标题栏交给默认编辑应用。`VersionsPlugin` 显示透明圆点曲线版本网，
长历史支持水平滚动，选中节点后在下方显示绑定固定提交的200字内简介。文件内容保留只读预览。
项目版本启用与全局插件开关分开：构造、挂载和切换项目不启用仓库，首次打开版本应用才持久启用。
分支、范围提交和测试合并是 Agent 内部工具，不提供界面按钮或开发菜单。简单任务验收后记录线性
大版本，复杂任务保留固定的 Agent 派生节点与合并关系，失败或取消不记录成功大版本。

普通版本功能不因打开或任务完成自动联网，仍由用户菜单授权发布。复杂阶段工作流按用户启用的规则
先上传原始快照，再自动上传审核通过的候选，保持阶段父版本关系。新仓库私有，既有仓库先核实私有性，
不强推、不上传开发提交祖先。`status.versions`
中的节点以 `id` 标识，`commit`/`head` 为固定对象ID，`parents` 引用版本ID，`kind` 区分
`major` 与 `agent`；内部工作树信息保留在 `nodes`，不能把可变分支HEAD当作已固定版本。
`datasets` 和 `aios` 是可开关的 Agent 服务。

项目行右键仅提供 Rename、Delete。Delete 仅隐藏入口，保留文件与历史；显式重新打开恢复入口。
Rename 同步实际文件夹和项目引用，迁移前检查任务、队列及存活进程，先保存文件与画板。
必须保留会话ID、boardID、自定义画板根目录和原数据副本，目标冲突或迁移失败不得覆盖数据。
不能把 SSH 项目本机描述目录的改名当作远程目录改名；不支持安全迁移时应说明原因并拒绝。

## 3. 菜单与设置

工作区插件的 `menuCommands` 自动生成 `应用 → <title>` 子菜单。
`performMenuCommand(_:)` 接收命令 id。空标题的 `.separator` 用于分隔。
`open` 保留给打开应用，其余命令 id 由插件定义；例如 `settings`、`export`。
设置界面由插件持有，只通过这个菜单提供入口，不要求修改宿主 AppDelegate。

所有注册插件自动进入 `F → plugin`。勾选表示启用，点击切换，状态会保存。
关闭后宿主移除应用栏入口、设置子菜单及底栏入口；再次打开后自动恢复。

## 4. 生命周期

| 接口 | 责任 |
| --- | --- |
| `setEnabled(true)` | 恢复计时器、订阅和其他插件服务；应可重复调用 |
| `setEnabled(false)` | 停止后台活动，不删除数据；默认实现调用 deactivate 和 shutdown |
| `projectDidChange(project)` | 项目关联插件更新文档与存储，切换前保存旧项目 |
| `activate()` | 应用被打开后聚焦或开始必要的工作 |
| `reselect()` | 底栏进程再次被选择；SSH 可用它返回登录页 |
| `deactivate()` | 离开当前视图或收起面板，应保留会话和进程 |
| `applyAppearance(dark:)` | 使用宿主主题更新界面 |
| `confirmClose(completion)` | 未保存修改允许取消关闭时，异步返回是否可继续 |
| `prepareToClose(completion)` | 保存和 flush；完成后必须调用 completion 一次 |
| `shutdown()` | 应用退出或插件关闭时释放进程、文件描述符、订阅等资源 |

关闭插件的顺序是：确认未保存修改 → prepareToClose → 保存开关 → setEnabled(false) →
更新入口和菜单。启用时先同步最新项目和主题，再恢复插件服务。
任务进行中关闭插件时，宿主要求先停止任务，避免中途失去正在使用的工具或连接。

## 5. 视图与交互

原生工作区由宿主让出顶部 52 点供 F 的基础按钮使用；画板沿用现有网页内的角落占位。
插件可提供可选 `toolbarView`，默认 nil。宿主将其挂在顶部 52 点，并与工作区同步显隐。
工具栏随展开的左右侧栏内缩，同时避开 F 的软件按钮；插件负责其中控件的布局、主题和释放。
边栏动画使用同一工具栏边界，展开和收起过程中也不得重叠。
窄窗口中按比例缩小已展开侧栏，给工具栏至少保留 200 点，不改变用户设定的侧栏宽度。
浏览器通过该接口提供首行，与 F 的基础按钮同高同中线：可用区域左侧留 8 点开始后退、前进、
刷新三个 28 点按钮，再留 8 点是无占位文字的玻璃搜索栏，一直铺到可用区域右侧前 8 点；
下方36点在工作区内放可滚动标签栏，选中标签用灰色强调、其余标签透明，网页从两行以下开始。
Google结果页隐藏其原生搜索和分类栏。输入框悬停不显示快捷键提示。
应用、列表、正文与滚动容器保持透明，复用主对话的窗口背景及透明度。常用操作使用简洁文字；
仅在邮件选中或存在下一页时展示回复、归档与继续加载，不增加重复的设置或装饰图标。

`view` 由插件持有，宿主负责添加、隐藏、移除和调整大小。插件不可自行改变其他插件的视图。
需要辅助侧栏时可提供 `sidebarView`，并用 `onRequestSidebar` 请求宿主展示。

底栏没有进程时先显示已启用功能的选择；选择后隐藏所有选择图标，底栏左侧变成一列纵向进程
标签，右侧显示当前进程页面。标签从上到下排列并随名称伸缩：左键切换，双指按压（右键）改名，
标签上的 × 关闭；双指按压标签空白处或点左下角 + 新建进程。底栏始终停在窗口底部，只改变
高度，不占用工作区宽度。关闭底栏只隐藏界面，已有进程继续运行，再次展开直接回到标签和
页面。终端页面不添加额外标题、状态条或工具栏；保留终端本身的提示符与输出。Side Agent
页面同样只有白底、左对齐的文字与一个 `%` 提示符，输入回车后回答接在下面。
后台进程和文件回调应支持取消，并验证当前项目/连接，拒绝把晚到结果写入另一个项目。

## 6. 最小示例

```swift
import AppKit

final class NotesPlugin: FPlugin {
    let id = "notes"
    let title = "便笺"
    let symbol = "note.text"
    let placement = PluginPlacement.workspace
    let projectAssociation = PluginProjectAssociation.project
    let view = NSView() // 换成插件自己的内容视图
    private var project: URL?

    var menuCommands: [PluginMenuCommand] {
        [PluginMenuCommand(title: "打开", id: "open"),
         PluginMenuCommand(title: "设置…", id: "settings")]
    }
    func projectDidChange(_ project: URL) {
        // 先保存当前项目，再从新项目的数据目录载入。
        self.project = project
        let directory = PluginStorage.directory(for: id, project: project)
        // 在此创建目录、载入文档。
        _ = directory
    }
    func performMenuCommand(_ command: String) {
        if command == "settings" { /* 打开插件持有的设置窗口 */ }
    }
    func prepareToClose(_ completion: @escaping () -> Void) {
        // 完成文档保存之后调用。
        completion()
    }
}
```

将实例注册到 BuiltInPlugins 后，应用栏、应用菜单和 F/plugin 开关自动出现。
如果便笺不关联项目，将 `projectAssociation` 改为 `.independent`，并使用全局数据目录。

## 7. 验证要求

确认启用/关闭与重启后开关一致；关闭后所有入口和后台活动消失；重新启用能恢复数据。
项目关联插件还要验证本机和远程项目隔离、关闭期间切换项目后恢复正确文档，以及异步结果
不会写错项目。可运行 `tests/README.md` 中的现有回归脚本，并为新行为添加相应的隔离验证。


### Daily Paper

`Plugins/DailyPaper/DailyPaperPlugin.swift` 提供 `daily-paper` 独立工作区，不随项目切换论文库。
用户在应用菜单设置中导入自己的 Google 桌面 OAuth 客户端 JSON、启用 Gmail API，完成只读授权后，
仅读取名称为 daily papers（或 daily paper）的分类中最新一封邮件。OAuth 使用 PKCE 与本机回调，凭据保存在按应用身份隔离的
Keychain 项；权限本身允许读取邮箱，应用按指定范围读取，不发信、不删除、不标记邮件。
构造、挂载及打开设置仅读取本地状态与非敏感连接标记，不读取钥匙串；导入客户端、连接及撤销授权时才恢复凭据，避免系统授权弹窗阻塞更新启动。后台读取仍由只读 worker 负责。
新流程不分页导入历史邮件；从邮件链接及其所属表格提取论文标识和标题，不下载论文或调用模型。断开或禁用取消操作，失败保留原卡片。

论文与邮件出处保存在 `PluginStorage.directory(for: "daily-paper")`；卡片只显示图文，
列表复用可见行，不按整库条数创建卡片；显示图片只解码有限尺寸缩略图，原图保留磁盘。
不嵌入邮件 HTML 或追踪图片。新卡片只显示邮件中的标题及来源，指向 `https://www.alphaxiv.org/abs/<arXiv标识>`，点击后在本工作区的透明 WKWebView 中直接显示该站点。通过 `FBrowserSession.shared` 与浏览器插件共用持久 Cookie/localStorage，关闭阅读页保留登录。网站 JavaScript 正常运行，没有原生消息桥或本机文件权限；顶层导航仅允许 alphaXiv 官方域名，其他 HTTPS 链接由用户点击后交给外部浏览器。Google OAuth 跳转及显式登录菜单使用真实 Chrome 完成，不伪装内置浏览器。页面根背景注入透明样式，媒体不自动播放；返回、切换应用及禁用时释放阅读页。
`onOpenPaper: ((DailyPaperRecord) -> Void)?` 保留为历史宿主接口；卡片点击不调用该回调，不排队、不触发任何模型分析。旧论文卡片也直接浏览对应 alphaXiv。Daily Paper 页面隐藏画板及主对话输入框，底栏进程保持不变。

F 设置中的每日09:00开关由 `DailyPaperSchedule` 管理用户级 launchd 任务，启动签名 F 的 `--daily-paper-update` 后台入口；无需Codex或打开F窗口，电脑需开机登录，睡眠错过后补更。按Asia/Shanghai判断到期，失败每15分钟重试，当天完成后跳过。关闭开关/禁用插件卸载任务，普通退出F保留计划。后台任务进入插件活动统计，应用延迟更新会等待它完成；待安装清单存在时不新开任务。
启动后异步恢复已启用的计划；若安装器尚未清除待更新清单，稍后重试交接，避免首轮补更丢失。

后台与手动操作共用 `runtime/harness/src/daily-paper/cli.mjs` → `links.mjs`，复用 Daily Paper 的 readonly Keychain 凭据，不借用 Gmail 写权限。这个入口没有模型或全文下载依赖。分类最新邮件未变化后原子提交 state.json，随后清理受管理的旧批次；`batches/<批次>/` 只保存 cards.json 和 batch.json。`sourceMode=alphaxiv-links-v1` 区分新旧流程；旧 schema 1、阅读历史及数据可恢复。`update-status.json` 提供进度及失败状态。
从旧分析模式切换时可暂时暂停自动执行，并保存 `FDailyPaperResumeLinkUpdates` 标记；新插件挂载后恢复原有自动更新意图并消费标记，旧版本不会重新开始模型任务。

旧版主对话论文快照及阅读记录继续存入对话私有目录 `daily-paper.json`，不改变该对话的画板。
网站浏览由当前工作区持有选中状态；Side Agent仅在用户主动请求时附加论文标题和链接，不读取或分析站点内容。离开页面清除此临时上下文。旧主对话阅读仍保留选择代次校验，晚到结果不能覆盖新论文记录。
论文与既往 AI 回答标为不可信参考，邮箱账户、发件人和邮件 ID 不发送给模型。
主对话支持安全 Markdown 图片与点击后加载的可信直接视频；YouTube/Vimeo提供来源外部观看，
不嵌任意 iframe、不自动播放。无法访问的正文、配图或视频由主 Agent 明确说明，不伪造页码或证据。
聚焦回归为 `tests/run-daily-paper-tests.py` 和 `tests/run-paper-media-tests.py`，发布验证必跑；
隔离夹具不等同用户 Gmail 实际授权与同步验收。

### 浏览器与 Chrome 登录桥接

`Plugins/Browser` 提供 `browser` 独立工作区，透明地址/搜索框下方为后退、前进、刷新/停止、标签栏、新建标签和独立窗口。Cmd+L/T/N/W/R、Cmd+[/] 分别选择地址、新建标签/窗口、关闭标签、刷新和导航。每页独立保留历史、表单与错误。普通 target=_blank 链接在当前页继续浏览，保留后退历史；window.open 和新窗口表单使用 WebKit 原配置，在主浏览器中创建标签，保留 opener 与登录回传。脚本关闭标签后返回原标签。网页不自动弹出独立窗口，独立窗口仅由用户菜单或 Cmd+N 创建。原生网页对话框显示在所属窗口。网页启用脚本、禁止自动媒体播放；无原生消息桥和本机文件 URL。首次打开才创建网页，切换应用保留全部页面，禁用释放页面、独立窗口和控制端点。

生产环境沿用 F 固定应用身份的默认持久 `WKWebsiteDataStore`，与 Daily Paper 共用，独立于 Chrome。用户在 F 网页手动登录普通网站，Cookie/localStorage 由 WebKit 保存，各标签和窗口共享会话，关闭插件不清除账号。隔离测试使用非持久夹具与独立标识的持久测试 profile。[Google OAuth 政策](https://developers.google.com/identity/protocols/oauth2/policies) 禁止受应用控制的内嵌登录，F 显示原因，由用户选择菜单中的 Chrome 登录及可选桥接，不自动启动外部浏览器，不伪装 User-Agent 绕过限制。Google 密码、通行密钥及 Google 网站会话不导出。API Key 不能替代网页登录。

应用菜单“连接 Chrome”准备本地 MV3 扩展与用户级 `local.f.browser` Native Messaging host。用户安装扩展、填入 Chrome 显示的扩展 ID 后，host 的 `allowed_origins` 只允许此扩展。扩展初始没有网站权限，用户点击“同步本站登录到 F”时才申请选定 HTTPS 站点权限；alphaXiv 仅允许其官方域名。最多16个站点，每分钟单向同步到 F；Chrome关闭或F未开时不记录会话明文。停止同步入口在扩展弹出页；需要在F独立退出登录时先停止该站点同步。没有 Chrome 密码数据库读取或完整 Chrome Sync 接口。

桥接通过 Chrome 官方 cookies/scripting/nativeMessaging API 传送选定站点 Cookie 与有限的认证 storage 项。Google 域名及跨站分区 Cookie 不导入；Cookie 域须属于所选来源，保留 Secure/HttpOnly 等标记。全部数据验证后再更新共享存储。重复同步不重新载入当前页面、不会累积用户脚本；明确手动同步可打开/重新载入该站点。仅在内存保留有界的16个来源配置；持久登录由 WebKit 管理。

Agent 的 Cordis `browser` 能力由 `runtime/harness/src/browser/index.mjs` 注册，随插件开关与作用域卸载；操作为 open/state/read/click/fill/back/forward/reload/tabs/newTab/selectTab/closeTab，可用 tabId 指定工作区标签。read 返回有界正文、控件索引、tabId 和 snapshot；click/fill 须带该标签最新 snapshot，导航及切换标签后旧目标失效。独立窗口由用户操作，Agent 只控制工作区窗口。密码及隐藏输入不返回，不提供任意 JS、Cookie、Token 或私钥导出工具。网页内容是非可信参考，不能授权消息发送、付款、修改账号或安全设置；提交结果不明时先读取页面，不自动重试。

Native IPC 端点位于 `PluginStorage.directory(for:"browser")`，目录0700、连接与消息0600。Cookie请求使用当前实例随机密钥的 AES-GCM 加密，Chrome Native Messaging 仅传入本机，不经过模型或命令行参数；返回只有来源和数量。最多4个进行中请求，超时30秒，旧消息定期清理。关闭注销端点，不抢占其他存活实例；这是同一系统用户下的受信代码接口，并非对恶意本机代码的系统沙箱。

聚焦回归为 `tests/run-browser-tests.py` 与 `runtime/harness/tests/browser.test.mjs`，覆盖隔离站点表单登录、会话共享与恢复、多标签/窗口、标签回传、新窗口表单的POST正文、前进后退、断网恢复、页面进程终止、透明显示、Cookie范围、快照失效、真实Node/CryptoKit互通及关闭释放。第三方真实账号登录不由夹具代替。
从源码根目录运行 `F_BROWSER_LIVE_SCHOLAR=1 python3 ui/desktop/tests/run-browser-tests.py` 可用隔离会话实测 Scholar。测试把真实论文结果设为新窗口目标，检查仍在当前页打开及前进后退，并在输出目录保存截图和 `live-scholar.json`。不修改用户账号或搜索偏好。

## 8. 微内核服务与作用域

原生宿主通过 `Core/Kernel.swift` 挂载插件，与 Agent 进程里的官方 Cordis 保持相同的依赖和可逆注册语义。
`FPlugin.requiredServices` 声明服务键；`providedServices` 默认提供 `plugin.<id>`。
未满足依赖的插件保留启用偏好，等待服务出现；入口只展示实际挂载的插件。
服务撤回会释放依赖消费者，服务恢复后重新同步项目与外观并挂载。Workflow 声明依赖 `plugin.subagent`。

需要订阅或其他资源时实现 `mount(in scope: FPluginScope)`，通过 `scope.effect` 注册，返回对应的释放操作。
默认实现调用 `setEnabled(true)`，卸载调用 `setEnabled(false)`，所以已有插件无需修改。
作用域释放是幂等的，并逆序撤销副作用；关闭插件仍先执行原有确认和保存流程。
`placement = .service` 用于无视图 Agent 能力，仅进入 plugin 开关，不产生空应用页面或底栏进程。

Agent 侧插件使用真正的 Cordis `inject`、`ctx.effect`、`ctx.on` 和稳定服务键。
模型、远程和画板适配器位于 `runtime/pi/agent/modules/`；唯一组合入口位于 `runtime/harness/src/index.mjs`。
添加能力应挂载独立插件，而不是修改主 Agent 循环。运行中工具先完成所属任务回收，再移除其服务。

## 9. Agent 插件 HMR v1（显式开发入口）

这不是 Swift `FPlugin` / dylib 热卸载，也不替换签名应用资源。文件浏览器等原生宿主代码以及
现有内置 Skills/Subagent/Workflow、模型与远程适配器仍随应用构建发布；不能用本入口绕过应用更新验收。
HMR 只替换通过下列契约编写的本机 Agent 插件，在当前对话的 Cordis 子作用域里完成，F 无需重启。

在主对话输入（尖括号内容替换为实际值；路径是剩余整段文本，不需要 shell 引号）：

```text
/hmr status
/hmr load hello <64位小写SHA256> .f/plugins/hello/v1.mjs
/hmr unload hello
```

- 候选必须位于当前项目 `.f/plugins/<id>/` 下，是不超过 1 MB、非硬链接/符号链接的 `.mjs` 文件；
  必须先审阅源码并计算 SHA256，加载器校验并执行这些确切字节，不执行下载或自动发现的代码。
- v1 仅支持自包含单文件，不支持静态/动态导入、require、转导出或修改依赖图。保守检查也会拒绝
  注释中的 `import` 单词。示例见 `../runtime/harness/src/core/hmr-example.mjs`。
- 插件导出 `default { apiVersion: 1, id, apply(api, previousState), test(testApi), snapshot?() }`。
  `id` 为小写字母开头的字母/数字/连字符，最长 48。顶层不得启动资源；所有资源从 apply 创建，
  由 effect 的 cleanup 释放。模块级状态不是跨更新存储，需用 snapshot 返回可无损 JSON 化的状态。
- `api.tools.register` 注册的工具名必须以 `hmr_<id中连字符换下划线>_` 开头、有非空后缀且最长 64 字符；参数使用 Harness
  支持的 JSON Schema 子集。若宿主用 `--tools` 白名单，须显式授权这些动态工具名；HMR 不绕过白名单，
  激活检查失败即拒绝并回滚，不能把“注册但不可调用”算通过。F 主应用默认不使用此工具白名单。
  `api.prompts.register(name, render)`、`api.provide(name, value)` /
  `api.get(name)` 自动归入该插件命名空间，不覆盖宿主或其他插件服务。
- `api.on(event, handler)` 支持 message_start、message_end、tool_execution_end、agent_settled 通知。
  `api.effect(() => cleanup)` 的 cleanup 可异步；异步回调产生的工作需经 `api.track(async () => …)`
  跟踪并 await/catch。卸载先关闭新工作入口，进行中工作拒绝替换，不强制结束工具。
- 事务顺序：校验 → 保存旧状态 → 释放旧作用域 → 挂载候选 → **只测试候选自身功能** → 接受同一被测实例。
  同时只允许一个事务。空验收或失败断言（即使被 test 捕获）都不算通过；每个候选工具必须至少成功调用一次。
  无工具插件至少需要真实断言。`testApi` 提供临时 `cwd`、`invoke(本插件工具名, 参数)`、`assert`；
  必须返回非空 `[{ name, passed: true }]`。验收不调用 LLM，不跑其他插件或整个 F 的回归。
- 测试必须等待所有工作，使用临时 cwd，不修改用户文件；若测试改变业务内存状态，测试自行恢复它。
  验收之后不重新 apply，最终启用的就是被测实例。普通失败清理候选后按旧快照重挂旧版；
  资源清理失败则保留禁用状态，不叠加新旧实例，必须排查并安全回收后才能继续；
  未结束的验收任务仍使用临时目录时不会删除它，状态中的 acceptanceDirectory 可供排查，停稳后 unload 才回收。
- 状态和工具只属于当前 Agent 运行时：切换/关闭会话会释放，不自动执行磁盘插件或在重启时自动恢复。
  执行结果写入会话的 `f-plugin-hmr` 记录。JS 模块定义仍受 Node 缓存管理，HMR 释放的是作用域及资源，
  不承诺卸载机器码或回收所有模块缓存。受管理的子代理可继承父会话已批准的精确模块，启动时
  重新校验同一哈希并在自己的 Cordis 作用域挂载；不扫描未授权文件，不因重启自动恢复磁盘插件。
- **信任边界**：插件及其测试是受信本机代码，拥有 Pi 进程权限，不是 OS/网络/文件沙箱。
  哈希防误载，命名空间和生命周期防意外冲突；它们不审计恶意代码，也不能回滚未按契约执行的外部副作用。

## 10. Workflow 与 Agent 工具插件

开发入口为 `skills/f-workflow-plugins/SKILL.md`；原生界面和素材规则见 `skills/f-plugins/SKILL.md`。
Workflow 通过 Cordis Service、依赖和 effect 接入，不加载 Swift UI。旧专家投票、双审批、JavaScript
script/parallel/pipeline 执行接口已经移除。旧历史保留，但不继续执行旧的复杂目标状态。

`goal_flow` 的复杂目标和 `workflow` 使用同一个阶段引擎。简单目标仍使用 delivered/simplify/test。

| action | 输入与行为 |
| --- | --- |
| begin | goal、可选 artifact/paths/repository；先排除凭据并上传原始 Git 快照，成功后进入 planning |
| plan | tree；节点有唯一 id、title、objective、可选 children，根的 children 按顺序对应阶段 |
| propose | 为每个入选固定版本派出3位方向作者，summary 最多200字，另有 method、hypothesis、evaluation |
| review | 主 Agent 提交 judgments，每项 candidateId/valid/reason，加 distinctness；只让被否决者重提 |
| run | 所有方法通过后从各固定起点创建三条独立工作树，由方向作者继续实验并自行 commit |
| split | 仅顶层实验者可用一次，subgoals 为1至3项方向；创建孙分支，孙不能继续委派 |
| retry | candidateId；失败返回原实验者，保留原分支和反馈，重新派独立精简与测试 |
| report | 主 Agent 应用 unslop 提交最多1000字阶段报告，全部分支须已测试并上传 |
| status/cancel/archive | 查看、取消并等待所属任务停稳、归档历史；不删除用户文件或工作树 |

目标树只由实际用户 input 批准。用户可输入“批准阶段目标树”，或 `/goal approve <id> <revision>`。
树被批准后冻结，不再请求阶段方法或子目标审批。阶段结束用户输入“选择候选 1 3”等，或
`/goal select <id> <revision> <versionId>...`，选1至3个本阶段已发布候选，下一阶段每个入选版本再派3人。
过期审批、重复选择、未通过或未上传候选均不能推进。模型工具没有用户批准或选择动作。

实验者在自己的工作树中修改，先申请 resource_scope 并重新读取。主线保持只读，项目画板仍集中存储。
每条分支包括孙分支都要通过新的精简者和测试者，二者不同且不是该分支的实验者。测试有真实工具证据，
并绑定固定 HEAD、index、工作文件和该节点元数据；其他分支的独立提交不会使本分支测试失效。
测试失败交回原实验者，不能自测放行或冒充成功。孙分支评审由主 Agent 派出，不占用最多3名实验孙代理。
主进程保留一个评审容量，避免三个父实验者等待孙分支时无法派出评审。

所有受管理的子代理固定使用 cbi / deepseek-v4.1-flash / medium，启动、设置与实际状态都校验。
根 Agent 的模型选择不变。子代理继承主线最新 skills、共享 datasets、已启用应用和 Cordis 工具，
以及父会话已批准的精确 HMR 模块；显式工具白名单和插件开关继续作为权限上限。
默认 datasets 保存在应用数据目录，可由 F_DATASET_DIRECTORY 显式配置，子代理继承同一目录。

原始快照不声称已经过实验测试。候选需有精简和测试的不同身份及实际通过记录。
原始与候选的发布提交仅引用阶段父快照，不包含开发提交祖先；发布到独立 f-workflow 分支，
不改用户 origin，不强推。凭据路径、内容和仓库私有性均须检查。发布失败保留本地版本供核对与恢复。
`workflow_control` 的 list/status/cancel 只管理当前会话，不接受旧脚本运行句柄。

素材与任务说明放 skills/<name>，输出模板放 assets，领域材料放 references，内置领域工具放
`runtime/harness/src/<domain>/` 并由组合根挂载。验证目标树审批、方法拒绝重提、3分支固定起点、一次孙级拆分、
独立审核、失败修复、候选选择、取消、凭据拒传和真实固定模型工具继承。维护 F 按 F_MAINTENANCE.md 验收。
