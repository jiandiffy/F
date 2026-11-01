import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit


if ProcessInfo.processInfo.arguments.contains("--self-check") {
    let resources = Bundle.main.resourceURL!
    let files = ["conversation.html", "conversation.js", "whiteboard/index.html", "terminal/index.html", "terminal/xterm.js", "terminal/addon-fit.js", "update-helper.py", "harness/src/index.mjs", "harness/dist/upstream.mjs", "harness/dist/THIRD_PARTY_NOTICES.txt"]
    guard files.allSatisfy({ FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path) }) else { fputs("F resources missing\n", stderr); exit(1) }
    print("F self-check passed")
    exit(0)
}

let app = NSApplication.shared
UpdateCoordinator.markBoot()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
