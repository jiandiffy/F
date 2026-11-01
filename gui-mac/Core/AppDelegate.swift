import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var rootView: RootView?
    private var updateCoordinator: UpdateCoordinator?
    private let settingsController = SettingsWindowController()
    private var appMenu: NSMenu?
    private var pluginMenu: NSMenu?
    private var applicationsMenu: NSMenu?
    /// 启动尚未就绪时从 Dock 图标拖进来的文件夹。
    private var pendingFolders: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        buildMenu()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "F"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.minSize = NSSize(width: 520, height: 340)

        // 隐藏红黄绿按钮，只留下两个侧边栏按钮
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }

        let root = RootView(frame: window.contentLayoutRect)
        rootView = root
        window.contentView = root
        root.onPluginsChanged = { [weak self] in
            self?.rebuildPluginMenus()
            self?.settingsController.refreshPluginVisibility()
        }
        rebuildPluginMenus()

        settingsController.onAppearanceChange = { [weak self] opacity, dark in
            self?.applyAppearance(opacity: opacity, dark: dark)
        }
        settingsController.onBoardStorageChange = { [weak self] in
            self?.rootView?.reloadBoardStorage()
        }
        applyAppearance(opacity: AppearanceStore.opacity, dark: AppearanceStore.dark)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateCoordinator = UpdateCoordinator(host: root)

        // 启动时直接拖到 Dock 图标上的文件夹，等窗口就绪后再建对话。
        if !pendingFolders.isEmpty {
            let folders = pendingFolders
            pendingFolders.removeAll()
            folders.forEach { root.openDroppedFolder($0) }
        }
    }

    /// Dock 图标拖入文件夹：基于该文件夹新建一条对话。
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.compactMap { RootView.droppedFolder(from: [$0]) }
        guard !folders.isEmpty else { return }
        guard let rootView else { pendingFolders.append(contentsOf: folders); return }
        folders.forEach { rootView.openDroppedFolder($0) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { rootView?.flushFileEdits() ?? true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let rootView else { return .terminateNow }
        rootView.confirmPluginClose { allowed in
            guard allowed else { self.updateCoordinator?.cancelQuit(); sender.reply(toApplicationShouldTerminate: false); return }
            var replied = false
            let finish = {
                guard !replied else { return }
                replied = true
                let saved = rootView.flushFileEdits()
                if !saved { self.updateCoordinator?.cancelQuit() }
                sender.reply(toApplicationShouldTerminate: saved)
            }
            DispatchQueue.main.async { rootView.flushWhiteboard(finish) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        PiRPC.stopAll()
        rootView?.shutdownPlugins()
    }

    private func applyAppearance(opacity: CGFloat, dark: Bool) {
        AppearanceStore.opacity = opacity
        AppearanceStore.dark = dark
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let window else { return }
        window.appearance = NSApp.appearance
        window.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(opacity)
        window.invalidateShadow()
        rootView?.applyAppearance(dark: dark)
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func togglePlugin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let rootView else { return }
        rootView.requestPluginEnabled(id, !rootView.plugins.isEnabled(id))
    }
    @objc private func applicationMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String], let id = payload["plugin"], let command = payload["command"] else { return }
        rootView?.performApplicationCommand(id, command: command)
    }
    private func rebuildPluginMenus() {
        guard let registry = rootView?.plugins else { return }
        pluginMenu?.removeAllItems()
        for plugin in registry.plugins {
            let item = NSMenuItem(title: plugin.title, action: #selector(togglePlugin(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = plugin.id
            item.state = registry.isEnabled(plugin.id) ? .on : .off
            pluginMenu?.addItem(item)
        }
        applicationsMenu?.removeAllItems()
        for plugin in registry.applicationPlugins {
            let item = NSMenuItem(title: plugin.title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: plugin.title)
            for command in plugin.menuCommands {
                if command.title.isEmpty { menu.addItem(.separator()); continue }
                let action = NSMenuItem(title: command.title, action: #selector(applicationMenuAction(_:)), keyEquivalent: "")
                action.target = self; action.representedObject = ["plugin": plugin.id, "command": command.id]
                menu.addItem(action)
            }
            item.submenu = menu
            applicationsMenu?.addItem(item)
        }
    }

    @objc private func setOpacityPreset(_ sender: NSMenuItem) {
        let value = sender.representedObject as? Double ?? 0.75
        applyAppearance(opacity: CGFloat(value), dark: AppearanceStore.dark)
    }

    @objc private func toggleDark() {
        applyAppearance(opacity: AppearanceStore.opacity, dark: !AppearanceStore.dark)
    }

    @objc private func openAppearanceSettings() {
        settingsController.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === pluginMenu {
            for item in menu.items { if let id = item.representedObject as? String { item.state = rootView?.plugins.isEnabled(id) == true ? .on : .off } }
            return
        }
        guard menu === appMenu else { return }
        for item in menu.items {
            if item.tag == 2000 {
                item.title = AppearanceStore.dark ? "白色" : "黑色"
                item.state = .off
            }
            guard let submenu = item.submenu else { continue }
            for child in submenu.items where child.tag >= 1000 {
                let percent = CGFloat(child.tag - 1000)
                child.state = abs(AppearanceStore.opacity * 100 - percent) < 0.6 ? .on : .off
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appMenu.delegate = self
        self.appMenu = appMenu

        // 顶部苹果标旁边的 F 菜单：调整透明度或切换黑白外观。
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(title: "透明度")
        for percent in [100, 95, 90, 85, 80, 75, 70, 60, 50] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacityPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 1000 + percent
            item.representedObject = Double(percent) / 100
            opacityMenu.addItem(item)
        }
        opacityMenu.addItem(.separator())
        let custom = NSMenuItem(title: "自定义…", action: #selector(openAppearanceSettings), keyEquivalent: "")
        custom.target = self
        opacityMenu.addItem(custom)
        opacityItem.submenu = opacityMenu
        appMenu.addItem(opacityItem)

        let darkItem = NSMenuItem(title: AppearanceStore.dark ? "白色" : "黑色", action: #selector(toggleDark), keyEquivalent: "")
        darkItem.target = self
        darkItem.tag = 2000
        appMenu.addItem(darkItem)
        appMenu.addItem(.separator())

        let pluginItem = NSMenuItem(title: "plugin", action: nil, keyEquivalent: "")
        let plugins = NSMenu(title: "plugin")
        plugins.delegate = self
        pluginMenu = plugins; pluginItem.submenu = plugins
        appMenu.addItem(pluginItem)
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let applicationsItem = NSMenuItem(title: "应用", action: nil, keyEquivalent: "")
        let applications = NSMenu(title: "应用")
        applicationsItem.submenu = applications
        applicationsMenu = applications
        mainMenu.addItem(applicationsItem)

        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "保存", action: Selector(("saveDocument:")), keyEquivalent: "s")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        editItem.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
