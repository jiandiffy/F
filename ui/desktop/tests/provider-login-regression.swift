extension ProviderLogin {
    var dpWindowForTest: NSWindow? { logins["dp"]?.window }
    var dpTerminalForTest: TerminalView? { logins["dp"]?.terminal }
    var gptWindowForTest: NSWindow? { logins["gpt"]?.window }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func eventually(_ name: String, _ predicate: @escaping () -> Bool, _ done: @escaping () -> Void) {
    let deadline = Date().addingTimeInterval(15)
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        if predicate() { timer?.invalidate(); done() }
        else if Date() > deadline { fputs("FAIL: timeout \(name)\n", stderr); exit(1) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let login = ProviderLogin.shared
var completions = 0
login.ensure("dp", relativeTo: nil) { ok in expect(ok, "successful login should resume selection"); completions += 1 }
login.ensure("dp", relativeTo: nil) { ok in expect(ok, "merged selection should also resume"); completions += 1 }
eventually("one DP terminal", { login.dpTerminalForTest?.renderedText.contains("FIXTURE_READY") == true }) {
    expect(NSApp.windows.filter { $0.title == "DP · 输入 API key" }.count == 1, "do not open duplicate login windows")
    let terminal = login.dpTerminalForTest!
    terminal.send(Data("fixture-key\r".utf8))
    eventually("completion after status validation", { completions == 2 && login.dpWindowForTest == nil }) {
        expect(!terminal.renderedText.contains("fixture-key"), "key must not echo in PTY")
        var cached = false
        login.ensure("dp", relativeTo: nil) { cached = $0 }
        eventually("reuse existing login", { cached }) {
            expect(login.dpWindowForTest == nil, "valid credentials must not open a terminal")
            var cancelled: Bool?
            login.ensure("gpt", relativeTo: nil) { cancelled = $0 }
            eventually("GPT terminal", { login.gptWindowForTest != nil }) {
                login.gptWindowForTest!.performClose(nil)
                eventually("cancel callback", { cancelled != nil }) {
                    expect(cancelled == false, "closing login must not resume a model request")
                    expect(login.gptWindowForTest == nil, "cancel should release login state")
                    print("PASS: missing login terminal, merged selection, hidden PTY entry, credential reuse and cancellation")
                    exit(0)
                }
            }
        }
    }
}
app.run()
