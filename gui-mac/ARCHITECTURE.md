# F 的模块与插件

`main.swift` 只保留应用入口。`Core/` 分别管理窗口、对话、项目存储、历史、
文件预览和共享界面。功能模块通过
`Core/Plugins.swift` 的 `FPlugin` 接口注册，由窗口提供布局和生命周期。

| 模块 | 入口 | 负责的内容 |
| --- | --- | --- |
| 画板 | `Plugins/Whiteboard/WhiteboardPlugin.swift` | WebKit 画板、原生输入框、项目场景同步、导出 |
| 本机终端 | `Plugins/Terminal/TerminalPlugin.swift` | PTY、键盘与粘贴、输出、项目环境 |
| Side Agent | `Plugins/SideAgent/SideAgentPlugin.swift` | 停靠区里的独立 pi 进程、主对话上下文、相关任务 |
| SSH | `Plugins/SSH/SSHPlugin.swift` | 主机选择、手动认证、远程终端、config 编辑 |
| SSH 传输 | `Plugins/SSH/SSHTransport.swift` | 配置别名、连接参数、复用认证后的连接、远程文件操作 |
| 远程文件 | `Plugins/SSH/RemoteBrowserView.swift` | 目录、文本编辑、保存与未保存状态 |
| 底栏停靠区 | `Core/UI/SideDock.swift` | 功能选择页、左侧纵向进程标签、原位改名/关闭/新建、底部固定布局 |

## 扩展方式

完整接口、项目关联和菜单约定见 [应用插件规范](PLUGIN_SPEC.md)。

1. 在 `Plugins/<Name>/` 中实现 `FPlugin`，提供唯一 `id`、标题、单色 SF Symbol、
   `placement` 和 `view`。
2. 在 `Core/BuiltInPlugins.swift` 注册实例。底部模块会自动出现在功能选择器中。
3. 可提供 `sidebarView` 和 `onRequestSidebar`，由宿主显示右侧内容。
4. 通过 `activate` / `deactivate`、`projectDidChange`、`applyAppearance`、
   `confirmClose`、`prepareToClose`、`shutdown` 处理状态。

`BottomPluginHost` 切换视图时保留插件实例和终端会话。窗口只管理面板尺寸与选择，
模块不直接操作其他模块的界面。新增底部模块不需要修改 RootView。
原生插件仍编译进应用，不加载外部动态库。独立的 Agent 插件 HMR 使用主对话 `/hmr` 命令，
仅支持显式审阅、校验哈希的本机自包含模块；候选自身验收通过启用，失败回滚，不热替换 Swift。
协议与边界见 `PLUGIN_SPEC.md` 第 9 节。

## 项目与画板

`BoardStore` 保持原来的路径与标识算法。每个远程项目由规范化的 SSH 端点（用户、
HostName、端口）和远程绝对路径共同标识；别名指向同一端点时复用同一个项目。
`RemoteProjects` 在 F 的应用数据目录保存项目描述，不复制远程项目文件。
描述目录是历史会话的稳定 cwd，因此重新打开历史对话时能恢复远程主机、路径和该对话的画板。

每条对话一块画板：`conversations/<boardID>/scene.json`。进入画板时以当前对话为准，
先 flush 旧对话再加载新对话；A→B→A 的快速切换也会废弃 B 的过期回调。
flush 同时校验 WebKit 返回的文档 id 和调用时的磁盘基线，避免读取中途换文档或
覆盖 Agent 新写入的场景。前端按加载代次拒绝过期定时器，切换文档清理撤销历史和图片缓存；
带旧文档 id 的 change 消息一律拒绝。

项目现在是工作文件夹，左栏按文件夹分组。只有当前项目展开会话，文件夹没有折叠箭头。
同项目的多个 ConversationView、RPC 进程、队列、模型、草稿和画板仍彼此独立。

对话画板文件为 `ConversationBoards.sceneFile(project:id:)`，视角、论文选择和中断记录
在同一目录。旧共享项目画板只迁移一次：`legacy-<boardID>-` 前缀的图元回到原对话并
去掉前缀、修正绑定与图片引用；其余图元归最近使用画板的对话；找不到对应对话时把旧文件
移入 `retired/`，界面不再显示。迁移记录在 `conversation-board-migration.json`，
原项目画板文件保留在磁盘上。GUI 与 Agent 写入共用对话租约事务锁，避免旧快照覆盖新图。
`F_BOARD_DIR` 与 `F_CONVERSATION_DIR` 都指向这条对话的目录。

`PromptHistory` 在 F 的偏好设置中按对话保存最近 200 条输入（总文本上限 1 MB，超大单条
不进历史但仍照常发送）。对话和画板共享历史；首行 ↑/末行 ↓ 浏览，回到最新位置恢复草稿，
中文输入法组合、文本选择和普通多行光标移动不被拦截。

加号提供本机文件夹，以及通过 BatchMode 实测连接成功的 config 主机、当前已经登录的主机。
失败主机不进入列表。选择远程主机后可浏览远程目录并建立项目。
`SSHSessions` 管理认证后的主连接；远程项目终端使用独立复用通道进入项目目录，
不会向一个正在执行命令的终端注入 cd。

## 拖入文件夹

把文件夹拖到窗口任意位置或 Dock 图标上，会基于该文件夹新建一条对话：窗口拖放由
`RootView` 的 `NSDraggingDestination` 接收（只接受真实存在的文件夹，文件、链接和其他拖放
内容保持原行为），Dock 拖放由 `AppDelegate.application(_:open:)` 接收，两者共用
`RootView.openDroppedFolder`。新对话和已有对话一样拥有独立 boardID、Agent 和输入
队列，以及自己的画板，不会因为 cwd 相同而复用其他对话。

文件夹列表立即登记，已有会话从 pi 历史加载，未发送首条消息的会话也可显示。`Info.plist` 声明 `public.folder`（Alternate）让 Dock 图标
可以接收文件夹，不改变 Finder 的默认打开方式。

## 窗口级对话框与折叠对话

主对话以外的应用界面（画板、版本、浏览器、Daily Paper、Gmail）共用窗口右下角的
`AgentOverlayDock`：输入框始终停在同一个位置，宽度与主对话一致，模型与思考程度可切换，发送的指令进入
当前对话的同一条队列；在画板里发送时仍附带白板工具提示。输入框上方是一个可开合的框，
折叠时只有一行箭头，不写文字：向上表示展开，向下表示折叠。展开后对话内容和同一个箭头
都在这个框里；点主页面收回一行。回到主对话时隐藏该框，改用对话自己的输入框。

## SSH 登录与底栏停靠区
底部栏固定白色，始终停在窗口底部。没有进程时展开显示已启用功能的单色选择图标；选择后
图标消失，同一块白色面板左侧是一列纵向进程标签，右侧是当前进程页面，高度始终占满面板。
再次收起并展开时，只要还有进程就直接显示标签和页面，不再显示选择页。

停靠区可以同时运行多个 terminal、ssh 和 side agent 进程：标签从上到下显示进程名称，左键
切换；标签本身就是名称输入框，单击已选中的标签或双指按压标签（右键）即可原位改名，
Enter 保存、Esc 放弃，不再弹出重命名对话框；标签上的 × 关闭进程，双指按压标签空白处或
点左下角的 + 可新建任意已启用的底栏插件。进程名称默认是 terminal、ssh、side agent，
重名时自动编号。
关闭底栏只隐藏界面，进程和终端继续运行；关闭最后一个进程后回到选择页。拖动底栏顶边可
调整高度，工作区随之上下伸缩，不会被底栏占用宽度。

`FProcessProvider` 让一个底栏模块创建多个独立实例；未实现该协议的模块仍会自动出现在
选择页和新建菜单中，但只保留一个实例。以后新增的 `.bottom` 插件无需修改 RootView 即可
沿用停靠区。

SSH 登录页为地址输入框与 config 编辑图标，支持 `user@host:port`、`host:port`、`user@host`
和 `host`，IPv6 可使用方括号。省略用户名或端口时由 OpenSSH/config 处理默认值。地址框补全
config 别名；选择补全项不会连接，只有 Enter 才开始连接。

认证需要密码或密钥口令时，切换为白色页面上的安全输入框，Enter 将输入发送至 PTY 后立即
清空。主机指纹确认单独显示。连接成功后只显示终端；收起再展开，选择 SSH 可返回地址输入框。
多个已登录主机会保留连接，不保存密码。

同一端点、同一项目下的多个 SSH 进程各自创建自己的 `TerminalView` 和远程 shell，并通过
`-S` 复用同一个已认证的 ControlMaster；额外的 ssh 进程使用 `ControlMaster=no`，不会新建
master。第一个普通登录面板可以沿用认证终端以保留原有 shell 状态，其余面板必须新建终端，
因此任何两个面板都不会挂载同一个 NSView。新建/切换项目前的确认会遍历注册表插件和停靠区
所有 SSH 进程的浏览器与 config 编辑器，不会只询问注册表中的 SSH 原型。

## Side Agent

side agent 是停靠区里的独立 pi 进程，与主对话分开运行。每次请求都会重新读取主对话最新的
文字记录（`ConversationView.recentTranscript`）作为上下文，并使用当前对话的
`F_BOARD_DIR`，因此可以分析主对话、执行命令、读写项目文件或修改同一块画板。切换项目时
停止旧进程，下一条消息在新项目中重新开始。收起底栏不会停止任务；退出应用时统一释放。

side agent 实现 `FProcessActivity`：只要它仍在执行请求或还有排队消息，
`RootView.canRestartForUpdate` 就保持 false，更新协调器会继续等待，而不会通过
`prepareToClose` 提前停掉正在工作的 side agent。

## 远程 Agent

模型调用、凭据与对话保留在本机。`PiRPC` 为远程项目提供 `F_REMOTE_PROJECT` 连接描述和
对应的 `F_BOARD_DIR`。`pi/agent/modules/fy-remote.ts` 覆盖 read/write/edit/bash/ls/find/grep，
所有项目文件与命令操作通过已认证的 OpenSSH ControlMaster 在远程执行；远程不需要安装 F。
`user_bash` 同样走远程。远程断线会报错，不会回退到本机文件或另开一次密码登录。

远程工具使用 pi 的正式工具工厂保留参数、diff、图片读取及输出截断行为；远程 shell
支持 AbortSignal 和超时，取消时结束对应的远程进程组或子进程树。白板工具继续操作本地
集中存储的真实 Excalidraw 元素。GUI 与当前对话的 Agent 使用同一条对话的画板目录；远程项目描述只标识执行环境。

右侧浏览器保留 2 MB 以内 UTF-8 文本的原子保存与冲突检查；Agent 工具支持更大的文件。
连接由系统 OpenSSH 解析 Host/Match、Include、密钥和 ProxyJump，使用私有控制套接字并
关闭继承的端口转发。参考：[ssh](https://man.openbsd.org/ssh)、
[ssh_config](https://man.openbsd.org/ssh_config)。

## 本机文件面板

`Core/Files/FileBrowser.swift` 保持现有右侧文件面板位置。单击选中、双击打开，Enter 开始重命名，
Enter 提交、Esc 取消；双指按压/右键行菜单支持重命名、复制地址、移到废纸篓和新建，空白菜单覆盖
整个 viewport 并在当前目录新建，目录行在自身内部新建。UTF-8 文本使用原生可编辑 NSTextView。
Cmd+S 由原生文件菜单及 responder chain 处理；编辑和离开文档时保存，失败保留草稿并阻止关闭/切项目/退出。
每文档保留独立编辑器与 UndoManager，关闭文件后重开仍可撤销/重做；列表上的 Cmd+Z 作用于最近编辑文档。
开关文件面板清空本轮 undo/redo，关闭时移除打字焦点并释放缓存，打开时刷新目录/文档。
保存及撤销前校验磁盘基线，拒绝覆盖已发生的外改、链接或无写权限文件；干净缓存发现磁盘新版本时刷新并废弃该文档过时的 undo。
目录重命名同步文档路径，新建文件采用排他写入，避免截断竞争创建的文件。该面板由 FilesPlugin 作为原生服务插件挂载，不是 HMR 插件。

## 页面长按拖动

窗口内任意位置长按约 0.35 秒后再滑动，整个页面跟随指针移动（移动的是窗口本身）。
按下后立即拖动超过 6 点则取消，保留原有交互；文字输入框、按钮、滚动条和可拖动分隔条
（面板边与停靠区灰线）不参与页面拖动。接管拖动时向原来的网页视图补一个抬起事件，
避免画板或对话记录停留在按下状态。实现位于 `Core/RootView.swift` 的 `handleWindowDrag`。

## 构建与验证

`build.sh` 编译 `main.swift`、`Core/` 和 `Plugins/` 下的 Swift 文件，仍使用原 bundle
和稳定的本地签名。测试脚本将模块合并到临时测试入口，以继续检查原有私有状态。
运行方式及覆盖范围见 `tests/README.md`。

`F → plugin` 保存每个注册插件的开关；禁用后入口、应用菜单、底栏选项和相关后台服务同步关闭。
启用时会同步最新项目与主题。顶部 `应用 → 画板` 和未来应用的子菜单由插件命令声明自动生成。
画板关闭后数据保留，轮询停止，并在新 Agent 会话中移除画板工具；重新启用会恢复当前项目。

## 终端渲染与自维护

终端保留原生 PTY 和 SSH 会话，使用随包分发的 xterm.js/fit 插件进行 VT 解析、光标、编辑、补全与屏幕尺寸同步。
终端资源源文件位于 Plugins/Terminal/Web，build-terminal.sh 从锁定的 npm 依赖复制运行时与 MIT 许可证。

F_MAINTENANCE.md 是内置 Agent 的自更新约定，Skills 模块在 F 源码项目任务中自动加载 f-maintenance 并注入该指南。
prepare-update.py 构建隔离制品并运行回归后才发布清单。UpdateCoordinator 等发起更新的对话及停靠区空闲，
为其他对话将原任务、session、模型、草稿、队列和手动暂停状态原子保存到各自画板目录的
`interruptions/<updateID>.json`；等待 abort 确认和 agent_settled 后再次保存，未安全停稳或写盘失败则取消重启，
不以强杀工具来推进更新。随后保存所有对话的 resume.json 并正常退出。外部安装器校验哈希与固定签名，等旧 PID 退出后再替换 Contents，并由新 F
写入启动就绪标记；失败时恢复上一版本。更新清单记录发起更新的项目和 `PI_SESSION_FILE`，
公告限定 100 字，只在该请求对话显示，不跟随用户之后选择的其他项目或同项目其他对话。
重启保存并恢复所有已打开项目的会话位置、模型选择和输入草稿。新版本就绪后按原 session 续接未完成任务，
再按序发送队列；用户手动暂停的队列不自动运行。续接提示要求先核对已保存的工具结果和文件状态，
避免重复外部操作；模型内部未保存的思考与任意 PTY/SSH 的操作系统进程状态无法序列化，不能承诺逐 token 恢复。


## Cordis 微内核与三个 Agent 能力

Agent 的唯一扩展入口为 pi/agent/extensions/fy-harness.ts。它加载签名应用资源内的 Harness 组合，
通过官方 Cordis 服务、inject 和 effect 管理模型、远程工具与画板适配器，以及 Skills/Subagent/Workflow。
原生插件注册表通过 Core/Kernel.swift 挂载 FPlugin；服务依赖缺失时暂停消费者，恢复后重新挂载。
三个无视图能力出现在 F/plugin 开关中，Workflow 依赖 Subagent；开关会使下一次 Agent 会话重新配置。
详细源码边界、上游固定提交、工具协议和验收入口见 ../harness/README.md。
