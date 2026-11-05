import AppKit

/// A native accessible button with a generous hit target, but only an SVG-like ring.
final class VersionNodeButton: NSButton {
    var selected = false { didSet { state = selected ? .on : .off; needsDisplay = true } }
    private(set) var hovered = false
    var onNavigate: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    var ringRadius: CGFloat { 8 * ((selected || hovered || isHighlighted) ? 1.19 : 1) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: onNavigate?(-1)
        case 124, 125: onNavigate?(1)
        case 36, 49: performClick(nil)
        default: super.keyDown(with: event)
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard hypot(local.x - bounds.midX, local.y - bounds.midY) <= 24 else { return nil }
        return super.hitTest(point)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.setStroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: bounds.midX - ringRadius, y: bounds.midY - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
        circle.lineWidth = 1.55; circle.stroke()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
            focus.lineWidth = 1; focus.setLineDash([2, 3], count: 2, phase: 0); focus.stroke()
        }
    }
}

/// Keep a short graph centered in its native scroll viewport without changing long-graph scrolling.
final class VersionGraphScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? VersionGraphView)?.fitViewport(contentSize)
    }
}

/// Deterministic parent-first DAG: first-parent mainline stays centered, forks alternate
/// above/below it. Coordinates depend on topology/IDs, never incoming array order.
final class VersionGraphView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var onSelect: (([String: Any]) -> Void)?
    private(set) var selectedID: String?
    private(set) var orderedIDs: [String] = []
    private var nodes: [String: [String: Any]] = [:]
    private var centers: [String: NSPoint] = [:]
    private var mainline = Set<String>()
    private var naturalSize = NSSize(width: 480, height: 248)
    private var verticalOffset: CGFloat = 0

    func fitViewport(_ size: NSSize) {
        let target = NSSize(width: max(naturalSize.width, size.width), height: max(naturalSize.height, size.height))
        let offset = (target.height - naturalSize.height) / 2, delta = offset - verticalOffset
        if delta != 0 {
            for id in Array(centers.keys) { centers[id]!.y += delta }
            for button in subviews { button.frame.origin.y += delta }
        }
        verticalOffset = offset
        if frame.size != target { frame.size = target }
        needsDisplay = true
    }

    private func parents(_ node: [String: Any]) -> [String] {
        node["parents"] as? [String] ?? (node["parent"] as? String).map { [$0] } ?? []
    }
    func display(_ values: [[String: Any]]) {
        nodes.removeAll(); centers.removeAll(); mainline.removeAll(); orderedIDs = []; verticalOffset = 0
        subviews.forEach { $0.removeFromSuperview() }
        for node in values { if let id = node["id"] as? String, nodes[id] == nil { nodes[id] = node } }
        let sorted = nodes.keys.sorted { lhs, rhs in
            let a = nodes[lhs]?["createdAt"] as? String ?? "", b = nodes[rhs]?["createdAt"] as? String ?? ""
            return a == b ? lhs < rhs : a < b
        }
        var visiting = Set<String>(), done = Set<String>(), depths: [String: Int] = [:]
        func visit(_ id: String) {
            guard !done.contains(id), visiting.insert(id).inserted, let node = nodes[id] else { return }
            for parent in parents(node) where nodes[parent] != nil { visit(parent) }
            visiting.remove(id); done.insert(id)
            depths[id] = (parents(node).compactMap { depths[$0].map { $0 + 1 } }.max() ?? 0)
            orderedIDs.append(id)
        }
        sorted.forEach { visit($0) }
        let tips = orderedIDs.sorted { lhs, rhs in
            let a = depths[lhs, default: 0], b = depths[rhs, default: 0]
            return a == b ? lhs < rhs : a > b
        }
        let mainTip = tips.first { nodes[$0]?["kind"] as? String == "major" || nodes[$0]?["major"] as? Bool == true || nodes[$0]?["isMain"] as? Bool == true } ?? tips.first
        var cursor = mainTip
        while let id = cursor, mainline.insert(id).inserted { cursor = nodes[id].flatMap { parents($0).first }.flatMap { nodes[$0] != nil ? $0 : nil } }
        var lanes: [String: Int] = [:], occupied: [Int: Set<Int>] = [:], branchIndex = 0
        func nextLane() -> Int { branchIndex += 1; return (branchIndex + 1) / 2 * (branchIndex % 2 == 1 ? -1 : 1) }
        for id in orderedIDs {
            let depth = depths[id, default: 0]
            let inherited = parents(nodes[id]!).compactMap { lanes[$0] }.first ?? 0
            var lane = mainline.contains(id) ? 0 : (inherited == 0 ? nextLane() : inherited)
            while occupied[depth, default: []].contains(lane) { lane = nextLane() }
            lanes[id] = lane; occupied[depth, default: []].insert(lane)
        }
        let extent = max(1, lanes.values.map { abs($0) }.max() ?? 0)
        let middle = CGFloat(extent) * 76 + 48
        if selectedID.flatMap({ nodes[$0] }) == nil { selectedID = mainTip ?? orderedIDs.last }
        for id in orderedIDs {
            let node = nodes[id]!, point = NSPoint(x: 48 + CGFloat(depths[id, default: 0]) * 128, y: middle + CGFloat(lanes[id, default: 0]) * 76)
            centers[id] = point
            let button = VersionNodeButton(frame: NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48))
            button.title = ""; button.isBordered = false; button.setButtonType(.momentaryPushIn)
            button.identifier = NSUserInterfaceItemIdentifier(id); button.target = self; button.action = #selector(selectNode(_:))
            button.selected = id == selectedID
            let hash = node["commit"] as? String ?? node["head"] as? String ?? ""
            let label = node["label"] as? String ?? id
            button.toolTip = label + "\n" + hash
            button.setAccessibilityLabel("版本 \(label)，提交 \(hash.prefix(12))")
            button.setAccessibilityHelp("左右方向键选择相邻版本，空格或回车选择；双指横向滚动浏览版本图。")
            button.onNavigate = { [weak self, weak button] offset in
                guard let self, let index = self.orderedIDs.firstIndex(of: id), !self.orderedIDs.isEmpty else { return }
                let next = self.orderedIDs[max(0, min(self.orderedIDs.count - 1, index + offset))]
                if let target = self.subviews.first(where: { $0.identifier?.rawValue == next }) as? NSButton {
                    button?.window?.makeFirstResponder(target); target.performClick(nil)
                }
            }
            addSubview(button)
        }
        naturalSize = NSSize(width: max(480, (centers.values.map(\.x).max() ?? 0) + 64), height: middle * 2)
        fitViewport(enclosingScrollView?.contentSize ?? naturalSize)
    }
    @objc private func selectNode(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let node = nodes[id] else { return }
        selectedID = id
        for case let button as VersionNodeButton in subviews { button.selected = button.identifier?.rawValue == id }
        scrollToVisible(sender.frame.insetBy(dx: -40, dy: -24)); onSelect?(node)
    }
    func selectCurrent() { if let id = selectedID, let node = nodes[id] { onSelect?(node) } }
    var selectedNode: [String: Any]? { selectedID.flatMap { nodes[$0] } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect) // Intentionally transparent; never paint a graph/card background.
        NSColor.labelColor.setStroke()
        for id in orderedIDs {
            guard let node = nodes[id], let child = centers[id] else { continue }
            for parentID in parents(node) {
                guard let parent = centers[parentID], parent.x < child.x else { continue }
                let start = NSPoint(x: parent.x + 12, y: parent.y), end = NSPoint(x: child.x - 13, y: child.y)
                let bend = max(24, (end.x - start.x) * 0.48)
                let path = NSBezierPath(); path.lineWidth = mainline.contains(id) && mainline.contains(parentID) ? 1.8 : 1.55
                path.lineCapStyle = .round; path.move(to: start)
                path.curve(to: end, controlPoint1: NSPoint(x: start.x + bend, y: start.y), controlPoint2: NSPoint(x: end.x - bend, y: end.y)); path.stroke()
                let arrow = NSBezierPath(); arrow.lineWidth = 1.55; arrow.lineCapStyle = .round
                arrow.move(to: NSPoint(x: end.x - 5, y: end.y - 3.4)); arrow.line(to: end)
                arrow.line(to: NSPoint(x: end.x - 5, y: end.y + 3.4)); arrow.stroke()
            }
        }
    }
}
