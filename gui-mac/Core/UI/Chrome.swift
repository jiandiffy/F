import AppKit

// MARK: - 顶部浮动按钮占位

/// F 自己有四个悬浮按钮（左栏 / + / 右栏 / 底部面板）固定在最顶部。
/// 内容视图（对话、白板）整体让出这条带，避免文字和 Excalidraw 菜单被压住。
enum FChrome {
    /// 左上 / 右上四个悬浮按钮占用的横向宽度：
    /// 12（边距）+ 32（左栏）+ 8 + 32（+）+ 8 = 92。
    /// 内容左右各让出这么多，就不会再钻到按钮下面；高度不变。
    static let corner: CGFloat = 92

    /// Native applications sit below the host's existing floating controls.
    /// Their content stays transparent so the window supplies the chat backdrop.
    static let toolbarHeight: CGFloat = 52
    static func nativeWorkspaceFrame(in workspace: NSRect) -> NSRect {
        NSRect(x: workspace.minX, y: workspace.minY, width: workspace.width,
               height: max(0, workspace.height - toolbarHeight))
    }

    static func makeTransparent(_ scroll: NSScrollView) {
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
    }

    /// 把占位宽度告诉 web 视图（对话 / 白板共用同一个 CSS 变量）。
    static var cssInjection: String {
        "document.documentElement.style.setProperty('--f-corner', '\(Int(corner))px')"
    }
}

// MARK: - 外观与动态颜色

enum AppearanceStore {
    private static let opacityKey = "FMainDialogOpacity"
    private static let darkKey = "FMainDialogDark"

    static var opacity: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: opacityKey) as? Double
            return CGFloat(min(1, max(0.25, stored ?? 0.75)))
        }
        set { UserDefaults.standard.set(Double(min(1, max(0.25, newValue))), forKey: opacityKey) }
    }

    static var dark: Bool {
        get { UserDefaults.standard.bool(forKey: darkKey) }
        set { UserDefaults.standard.set(newValue, forKey: darkKey) }
    }
}

enum ThemeColors {
    static func isDark(_ appearance: NSAppearance? = nil) -> Bool {
        let resolved = appearance ?? NSApp.effectiveAppearance
        return resolved.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var hover: NSColor {
        NSColor(name: "F.hover") { appearance in
            isDark(appearance)
                ? NSColor.white.withAlphaComponent(0.085)
                : NSColor.black.withAlphaComponent(0.05)
        }
    }

    static var selected: NSColor {
        NSColor(name: "F.selected") { appearance in
            isDark(appearance)
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.09)
        }
    }

    static var pressed: NSColor {
        NSColor(name: "F.pressed") { appearance in
            isDark(appearance)
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.12)
        }
    }

    static var glassBorder: NSColor {
        NSColor(name: "F.glassBorder") { appearance in
            isDark(appearance)
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.white.withAlphaComponent(0.55)
        }
    }

    static var sidebarTint: NSColor {
        NSColor(name: "F.sidebarTint") { appearance in
            isDark(appearance) ? NSColor(calibratedWhite: 0.82, alpha: 0.92)
                               : NSColor(calibratedWhite: 0.22, alpha: 0.9)
        }
    }

    /// 应用 / 项目等分组标题在黑白两种主题下都保持淡灰色。
    static let sectionTitle = NSColor(calibratedWhite: 0.62, alpha: 0.95)
    static let sectionLine = NSColor(calibratedWhite: 0.62, alpha: 0.42)
}

// MARK: - 侧边栏切换按钮（macOS 工具栏风格）

final class SidebarButton: NSButton {
    private var hover = false

    private var tint: NSColor { ThemeColors.sidebarTint }

    var isActive = false {
        didSet { refresh() }
    }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        contentTintColor = tint

        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; refresh() }
    override func mouseExited(with event: NSEvent) { hover = false; refresh() }

    override var isHighlighted: Bool {
        didSet {
            layer?.backgroundColor = isHighlighted
                ? ThemeColors.pressed.cgColor
                : (hover || isActive ? ThemeColors.selected.cgColor
                                     : NSColor.clear.cgColor)
        }
    }

    private func refresh() {
        layer?.backgroundColor = (hover || isActive)
            ? ThemeColors.selected.cgColor
            : NSColor.clear.cgColor
        contentTintColor = isActive ? .labelColor : tint
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}

// MARK: - 液态玻璃

func makeGlassView(cornerRadius: CGFloat, withBorder: Bool = true,
                   material: NSVisualEffectView.Material = .sidebar,
                   blending: NSVisualEffectView.BlendingMode = .withinWindow) -> NSView {
    if #available(macOS 26.0, *) {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        return view
    }
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blending
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = cornerRadius
    view.layer?.masksToBounds = true
    if withBorder {
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = ThemeColors.glassBorder.cgColor
    }
    return view
}

// MARK: - 空的侧边栏面板 / 带内容的侧边栏面板

final class SidebarPanel: NSView {
    var onResize: ((CGFloat) -> Void)?

    private let separator = NSView()
    private let separatorOnRight: Bool
    private let content: NSView?
    private let glass: NSView
    private let handle = ResizeHandle(axis: .horizontal)

    /// 顶部玻璃按钮占用的空间
    private let contentTopInset: CGFloat = 64

    init(separatorOnRight: Bool, content: NSView? = nil) {
        self.separatorOnRight = separatorOnRight
        self.content = content
        glass = makeGlassView(cornerRadius: 0, withBorder: false)
        super.init(frame: .zero)

        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        if let content {
            addSubview(content)
        }

        addSubview(handle)
        handle.onDrag = { [weak self] delta in self?.onResize?(delta) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func layout() {
        super.layout()
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.frame = NSRect(
            x: separatorOnRight ? bounds.width - 1 : 0,
            y: 0,
            width: 1,
            height: bounds.height
        )
        content?.frame = NSRect(
            x: 8,
            y: 8,
            width: max(0, bounds.width - 16),
            height: max(0, bounds.height - contentTopInset - 8)
        )
        handle.frame = NSRect(
            x: separatorOnRight ? bounds.width - 8 : 0,
            y: 0,
            width: 8,
            height: bounds.height
        )
        window?.invalidateCursorRects(for: handle)
    }
}

// MARK: - 边栏拖动边界

final class ResizeHandle: NSView {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    var onDrag: ((CGFloat) -> Void)?

    private var lastLocation = NSPoint.zero

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let delta = axis == .horizontal ? (now.x - lastLocation.x) : (now.y - lastLocation.y)
        lastLocation = now
        if delta != 0 { onDrag?(delta) }
    }
}

// MARK: - 下边栏

final class BottomPanel: NSView {
    /// 底栏始终停在窗口底部：选择页和进程标签共用同一块面板，颜色跟随黑白主题。
    var onResize: ((CGFloat) -> Void)?

    private let glass: NSView
    private let separator = NSView()
    private let handle = ResizeHandle(axis: .vertical)
    private var dark = false

    override init(frame frameRect: NSRect) {
        glass = makeGlassView(cornerRadius: 0, withBorder: false)
        super.init(frame: frameRect)

        wantsLayer = true
        glass.isHidden = true
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        addSubview(handle)
        handle.onDrag = { [weak self] delta in self?.onResize?(delta) }
        applyTheme(dark: AppearanceStore.dark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 黑色模式复用侧边栏那块玻璃（同一材质），底栏和边栏颜色完全一致；
    /// 白色模式保持原来的白色面板。
    func applyTheme(dark: Bool) {
        self.dark = dark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        glass.isHidden = !dark
        layer?.backgroundColor = BottomPanel.background(dark: dark).cgColor
        refreshSeparator()
    }

    /// 深色底栏的内容视图透明，让下面同一块玻璃透出来；白色模式仍是白色面板。
    static func background(dark: Bool) -> NSColor {
        dark ? NSColor.clear : NSColor.white
    }

    private func refreshSeparator() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = BottomPanel.background(dark: dark).cgColor
        refreshSeparator()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        refreshSeparator()
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        handle.frame = NSRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 10)
        window?.invalidateCursorRects(for: handle)
    }
}

