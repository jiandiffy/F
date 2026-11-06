import AppKit

/// 主界面应用（画板、版本、浏览器、Daily Paper、Gmail）的工作区容器。
/// 窗口级对话框浮在右下角，会盖住内容；这里在文档末尾留出对话框占用的高度，
/// 内容可以整块上下滚动，把被盖住的部分拉到对话框上方。
/// 窗口很矮时按最低高度排版，原生应用不会被压扁。
final class WorkspaceScrollView: NSScrollView {
    /// 可见高度不足这个值时，内容仍按该高度排版并允许上下滚动。
    static let minimumContentHeight: CGFloat = 520

    /// 对话框占用的高度；0 表示没有遮挡（回到主对话或对话框隐藏）。
    var dialogInset: CGFloat = 0 {
        didSet { if dialogInset != oldValue { needsLayout = true } }
    }

    private let content = FlippedWorkspaceView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        documentView = content
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 主界面应用的视图铺满内容区域。
    func adopt(_ view: NSView) {
        view.frame = content.bounds
        content.addSubview(view)
    }

    override func layout() {
        super.layout()
        syncContent()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncContent()
    }

    /// 按当前可见大小排版内容；宿主改了 frame 或对话框高度后立即生效。
    private func syncContent() {
        let viewport = contentSize
        let size = NSSize(width: max(0, viewport.width),
                          height: max(viewport.height, Self.minimumContentHeight))
        if content.frame.size != size { content.frame = NSRect(origin: .zero, size: size) }
        content.subviews.forEach { $0.frame = content.bounds }

        let inset = max(0, dialogInset)
        if contentInsets.bottom != inset {
            contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
        }
        // 窗口变高或对话框收起后，原来滚到的位置可能超出范围。
        let limit = max(0, content.frame.height + inset - viewport.height)
        if contentView.bounds.origin.y > limit {
            contentView.scroll(to: NSPoint(x: 0, y: limit))
            reflectScrolledClipView(contentView)
        }
    }
}

/// 滚动容器内的坐标从上往下，切换应用时不会从内容底部开始显示。
private final class FlippedWorkspaceView: NSView {
    override var isFlipped: Bool { true }
}
