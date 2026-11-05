import AppKit
import ApplicationServices

enum ComputerControl {
    static func run() -> Int32 {
        do {
            guard let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any], let action = input["action"] as? String else { throw failure("无效操作") }
            let screen = CGDisplayBounds(CGMainDisplayID())
            var result: [String: Any] = ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "width": screen.width, "height": screen.height]
            switch action {
            case "state": break
            case "screenshot":
                guard CGPreflightScreenCaptureAccess(), let file = input["path"] as? String, file.hasPrefix("/") else { throw failure("需要屏幕录制权限和绝对保存路径") }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-t", "png", file]
                process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw failure("屏幕截图失败") }
                result["path"] = file
            case "click", "move":
                guard AXIsProcessTrusted(), let x = input["x"] as? Double, let y = input["y"] as? Double, x.isFinite, y.isFinite, screen.contains(CGPoint(x: x, y: y)) else { throw failure("需要辅助功能权限，坐标须在主屏幕内") }
                let point = CGPoint(x: x, y: y)
                if action == "move" { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap) }
                else {
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            case "type":
                guard AXIsProcessTrusted(), let text = input["text"] as? String, text.utf16.count <= 10000 else { throw failure("需要辅助功能权限，文字最多 10000 字符") }
                let units = Array(text.utf16)
                if units.isEmpty { break }
                let pid = try keyboardTarget()
                var start = 0
                while start < units.count {
                    var end = min(start + 20, units.count)
                    if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                    let chunk = Array(units[start..<end])
                    for down in [true, false] {
                        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 0, keyDown: down) else { throw failure("无法创建键盘事件") }
                        event.flags = []
                        chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!) }
                        event.postToPid(pid)
                    }
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                    start = end
                }
            case "key":
                guard AXIsProcessTrusted(), let code = input["keyCode"] as? Int, (0...127).contains(code) else { throw failure("需要辅助功能权限和有效按键代码") }
                let pid = try keyboardTarget()
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(code), keyDown: down)
                    event?.flags = []; event?.postToPid(pid)
                }
            default: throw failure("不支持的桌面操作")
            }
            if ["click", "move", "type", "key"].contains(action) { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
            print(String(data: try JSONSerialization.data(withJSONObject: ["ok": true, "value": result]), encoding: .utf8)!)
            return 0
        } catch {
            let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])
            print(String(data: data, encoding: .utf8)!); return 1
        }
    }
    private static func keyboardTarget() throws -> pid_t {
        guard let application = NSWorkspace.shared.frontmostApplication, application.processIdentifier > 0 else { throw failure("找不到当前输入应用") }
        return application.processIdentifier
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "F.ComputerUse", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
