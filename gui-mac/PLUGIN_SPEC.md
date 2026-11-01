# F 应用插件规范 v1

F 当前内置的功能插件是画板、终端、SSH、side agent，以及无视图的 Skills、Subagent、Workflow。聊天、项目、历史、存储和窗口由宿主管理。
插件为随应用编译的 Swift 模块；此版本不自动加载外部动态库或执行下载的插件。

## 1. 注册与身份

在 `gui-mac/Plugins/<Name>/` 中放置 Swift 源码，实现 `FPlugin`，并在
`Core/BuiltInPlugins.swift` 的 `make(project:)` 中注册。构建脚本自动编译该目录下的源码。

- `id`：稳定且全局唯一，使用小写字母、数字、点或连字符；发布后保持不变。
- `title`：应用栏、菜单和 plugin 开关使用的名称。
- `symbol`：单色 SF Symbol；使用黑、白、灰的系统动态颜色，保持现有界面的字体和间距。
- `placement = .workspace`：自动出现在左侧“应用”下面，并占用主工作区。
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
`boardDirectoryProvider` 与主对话使用同一块画板。仍有任务或队列的进程可实现
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
无额外外围框预览，复杂文档可从标题栏交给默认编辑应用。`VersionsPlugin` 提供树状版本、
工作分支与显式 GitHub 发布。`datasets` 和 `aios` 是可开关的 Agent 服务。

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
模型、远程和画板适配器位于 `pi/agent/modules/`；唯一组合入口位于 `harness/src/index.mjs`。
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
  注释中的 `import` 单词。示例见 `../harness/src/core/hmr-example.mjs`。
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
  不承诺卸载机器码或回收所有模块缓存。
- **信任边界**：插件及其测试是受信本机代码，拥有 Pi 进程权限，不是 OS/网络/文件沙箱。
  哈希防误载，命名空间和生命周期防意外冲突；它们不审计恶意代码，也不能回滚未按契约执行的外部副作用。
