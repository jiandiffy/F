import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 设置

final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    var onAppearanceChange: ((CGFloat, Bool) -> Void)?
    var onBoardStorageChange: (() -> Void)?

    func show() {
        if window == nil { build() }
        syncAppearanceControls()
        refreshStatus()
        refreshPluginVisibility()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let checkbox = NSButton(checkboxWithTitle: "允许 F 读写本机所有文件夹", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString:
        "需要在「系统设置 → 隐私与安全性 → 完全磁盘访问」中勾选 F。开启后文件浏览与终端可以访问任意位置，修改后建议重新打开 F。"
    )
    private let opacitySlider = NSSlider()
    private let opacityValue = NSTextField(labelWithString: "75%")
    private let themeControl = NSSegmentedControl(
        labels: ["白色", "黑色"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let appearanceHint = NSTextField(labelWithString: "黑白互换，淡灰色分组标题保留。")
    private var boardControls: [NSView] = []
    func refreshPluginVisibility() { boardControls.forEach { $0.isHidden = !PluginPreferences.isEnabled("whiteboard") } }
    private let boardPathLabel = NSTextField(labelWithString: "")
    private let boardHint = NSTextField(labelWithString: "每个项目一块画板，默认存在 F 的软件数据目录。")

    private func build() {
        let height: CGFloat = 430
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "F 设置"
        win.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: height))

        let appearanceTitle = NSTextField(labelWithString: "主对话框")
        appearanceTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        appearanceTitle.frame = NSRect(x: 20, y: 392, width: 200, height: 18)
        content.addSubview(appearanceTitle)

        let opacityLabel = NSTextField(labelWithString: "透明度")
        opacityLabel.font = .systemFont(ofSize: 12)
        opacityLabel.textColor = .secondaryLabelColor
        opacityLabel.frame = NSRect(x: 20, y: 362, width: 70, height: 18)
        content.addSubview(opacityLabel)

        opacitySlider.minValue = 0.25
        opacitySlider.maxValue = 1
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.frame = NSRect(x: 100, y: 358, width: 280, height: 24)
        content.addSubview(opacitySlider)

        opacityValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityValue.textColor = .secondaryLabelColor
        opacityValue.alignment = .right
        opacityValue.frame = NSRect(x: 388, y: 362, width: 48, height: 18)
        content.addSubview(opacityValue)

        let themeLabel = NSTextField(labelWithString: "版本")
        themeLabel.font = .systemFont(ofSize: 12)
        themeLabel.textColor = .secondaryLabelColor
        themeLabel.frame = NSRect(x: 20, y: 326, width: 70, height: 18)
        content.addSubview(themeLabel)

        themeControl.target = self
        themeControl.action = #selector(themeChanged(_:))
        themeControl.frame = NSRect(x: 100, y: 322, width: 180, height: 26)
        content.addSubview(themeControl)

        let reset = NSButton(title: "恢复 75%", target: self, action: #selector(resetAppearance))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: 296, y: 322, width: 92, height: 26)
        content.addSubview(reset)

        appearanceHint.font = .systemFont(ofSize: 11)
        appearanceHint.textColor = .secondaryLabelColor
        appearanceHint.frame = NSRect(x: 100, y: 299, width: 320, height: 16)
        content.addSubview(appearanceHint)

        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = NSRect(x: 20, y: 282, width: 420, height: 1)
        content.addSubview(separator)

        let title = NSTextField(labelWithString: "文件夹权限")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: 250, width: 400, height: 18)
        content.addSubview(title)

        checkbox.target = self
        checkbox.action = #selector(toggleAccess(_:))
        checkbox.frame = NSRect(x: 20, y: 218, width: 400, height: 20)
        checkbox.state = UserDefaults.standard.bool(forKey: "FullDiskAccess") ? .on : .off
        content.addSubview(checkbox)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 20, y: 160, width: 420, height: 48)
        content.addSubview(hintLabel)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 134, width: 300, height: 16)
        content.addSubview(statusLabel)

        // ── 画板存储 ─────────────────────────────────────────────
        let boardSeparator = NSBox()
        boardSeparator.boxType = .separator
        boardSeparator.frame = NSRect(x: 20, y: 127, width: 420, height: 1)
        content.addSubview(boardSeparator)

        let boardTitle = NSTextField(labelWithString: "画板存储")
        boardTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        boardTitle.frame = NSRect(x: 20, y: 105, width: 400, height: 18)
        content.addSubview(boardTitle)

        boardPathLabel.font = .systemFont(ofSize: 11)
        boardPathLabel.textColor = .secondaryLabelColor
        boardPathLabel.lineBreakMode = .byTruncatingMiddle
        boardPathLabel.frame = NSRect(x: 20, y: 84, width: 294, height: 16)
        content.addSubview(boardPathLabel)

        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseBoardRoot))
        choose.bezelStyle = .rounded
        choose.controlSize = .small
        choose.frame = NSRect(x: 320, y: 78, width: 58, height: 24)
        content.addSubview(choose)

        let resetBoard = NSButton(title: "默认", target: self, action: #selector(resetBoardRoot))
        resetBoard.bezelStyle = .rounded
        resetBoard.controlSize = .small
        resetBoard.frame = NSRect(x: 382, y: 78, width: 58, height: 24)
        content.addSubview(resetBoard)

        boardHint.font = .systemFont(ofSize: 11)
        boardHint.textColor = .secondaryLabelColor
        boardHint.lineBreakMode = .byTruncatingTail
        boardHint.frame = NSRect(x: 20, y: 60, width: 420, height: 16)
        content.addSubview(boardHint)

        let button = NSButton(title: "打开系统设置", target: self, action: #selector(openPrivacySettings))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 320, y: 22, width: 120, height: 28)
        content.addSubview(button)

        boardControls = content.subviews.filter { $0.frame.minY >= 57 && $0.frame.maxY <= 129 }
        win.contentView = content
        window = win
        syncAppearanceControls()
    }

    private func syncAppearanceControls() {
        opacitySlider.doubleValue = Double(AppearanceStore.opacity)
        opacityValue.stringValue = "\(Int((AppearanceStore.opacity * 100).rounded()))%"
        themeControl.selectedSegment = AppearanceStore.dark ? 1 : 0
        boardPathLabel.stringValue = BoardStore.displayRoot
        boardPathLabel.toolTip = BoardStore.displayRoot
        boardHint.stringValue = BoardStore.isCustom ? "自定义路径（每个项目一个子目录）" : "默认：软件数据目录（每个项目一个子目录）"
    }

    @objc private func chooseBoardRoot() {
        let panel = NSOpenPanel()
        panel.title = "选择画板保存位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = BoardStore.root
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BoardStore.setRoot(url)
        syncAppearanceControls()
        onBoardStorageChange?()
    }

    @objc private func resetBoardRoot() {
        BoardStore.setRoot(nil)
        syncAppearanceControls()
        onBoardStorageChange?()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue)
        AppearanceStore.opacity = value
        opacityValue.stringValue = "\(Int((value * 100).rounded()))%"
        onAppearanceChange?(value, AppearanceStore.dark)
    }

    @objc private func themeChanged(_ sender: NSSegmentedControl) {
        let dark = sender.selectedSegment == 1
        AppearanceStore.dark = dark
        onAppearanceChange?(AppearanceStore.opacity, dark)
    }

    @objc private func resetAppearance() {
        AppearanceStore.opacity = 0.75
        AppearanceStore.dark = false
        syncAppearanceControls()
        onAppearanceChange?(0.75, false)
    }

    @objc private func toggleAccess(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "FullDiskAccess")
        if sender.state == .on { openPrivacySettings() }
        refreshStatus()
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshStatus() {
        let granted = FileManager.default.isReadableFile(
            atPath: "/Library/Application Support/com.apple.TCC/TCC.db"
        )
        statusLabel.stringValue = granted ? "当前状态：已授权" : "当前状态：未授权"
        statusLabel.textColor = granted ? .systemGreen : .secondaryLabelColor
    }
}

