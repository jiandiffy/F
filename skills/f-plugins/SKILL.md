---
name: f-plugins
description: 为 F 新增、修改或测试原生 UI 应用插件，规定素材位置、黑白透明风格、功能接入和生命周期。Workflow/Agent 工具插件使用 f-workflow-plugins。
---

先读取本技能资源根下的 ../../gui-mac/PLUGIN_SPEC.md；该规范是应用插件接口的唯一来源。

## 先定位再修改

查看 `gui-mac/Core/BuiltInPlugins.swift`、`Core/Plugins.swift` 和目标 `Plugins/<Name>/`。
已有同类功能就扩展原插件，保持 id、开关、存储与入口；只有缺少能力才新增插件。
UI 与 Agent 都要用的能力在已有服务层实现，避免复制业务逻辑。
维护 F 自身同时使用 f-maintenance，先备份、申请范围并重读源码。

## 素材与位置

先盘点用户提供的参考截图、交互说明、图标、图片、字体和测试输入。
非关键素材缺失时沿用系统字体和 SF Symbols；品牌素材与许可来源不明时不要伪造。

| 内容 | 位置与处理 |
| --- | --- |
| 原生视图、模型和辅助类 | `gui-mac/Plugins/<Name>/`，构建自动编译 Swift |
| 注册 | `gui-mac/Core/BuiltInPlugins.swift`，复用宿主入口 |
| 单色图标 | 使用 SF Symbol，不为已有系统图标增加 PNG |
| 运行时图片、HTML、JS、CSS | `gui-mac/Resources/<id>-<用途>.<扩展名>`，唯一前缀，从 Bundle 加载 |
| 插件网页源码 | `Plugins/<Name>/Web/`，明确生成并复制到 Resources 的步骤 |
| 素材来源和许可 | 有外部素材时保留在插件目录，交付前核实 |
| 回归夹具 | `gui-mac/tests/`，运行输出放临时目录 |
| 用户配置和业务数据 | `PluginStorage.directory(for:project:)`，禁止写到源码和 Resources |

构建只自动复制 Resources 顶层文件，以及 whiteboard、terminal 既有目录。
新增子目录素材须补构建复制和 self-check，不能只在源码路径验证加载。

## 界面与功能

遵守 PLUGIN_SPEC 第 5 节，使用黑白灰动态系统颜色、透明滚动容器、系统字体和宿主间距。
原生页面让出宿主按钮，按窗口宽度布局；单色按钮有工具提示、可访问名称与禁用状态。
复用现有菜单、侧栏和底栏，不重复创建设置入口；不加装饰卡片、渐变和无用途文案。
文案使用 unslop。根据用户操作补必要的加载、空白、失败和重试状态。

声明稳定身份、服务依赖与作用域，由宿主挂载和卸载。注册、观察、计时器和进程均有释放。
项目 URL 不能代替对话 boardID，画板继续集中存储。异步回调绑定项目/连接，不能回写新实例。
底栏多实例通过 FProcessProvider 接入，不自行接管宿主布局。

## 验证与交付

运行目标原生回归及 `gui-mac/tests/run-plugin-tests.py`，验证开关、菜单、释放和项目隔离。
检查窄窗口、明暗主题、键盘与真实素材加载；网络插件模拟断网、超时、认证失效和恢复。
Agent 能力检查取消、队列和卸载。只删查证无调用者的代码，保留外部边界必要错误处理。
按 f-maintenance 完成隔离构建、完整回归和延迟更新，不把未执行的操作写成通过。
