import AppKit

enum FApplicationLifecycle {
    /// AppKit's terminateLater loop cannot drain an already executing main dispatch block.
    /// Begin termination from a run-loop timer so asynchronous plugin saves can finish.
    static func requestTermination() {
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in NSApp.terminate(nil) }
        RunLoop.main.add(timer, forMode: .common)
    }
}
