import Foundation
import CryptoKit
import Darwin

/// Encrypted, per-user local IPC. Cookie material travels in native-message
/// pipes and AES-GCM files; no cookie/token is returned through browser tools.
final class BrowserBridge {
    let directory: URL
    private var timer: Timer?
    private let key = SymmetricKey(size: .bits256)
    private let nonce = UUID().uuidString
    private var pending: Set<String> = []
    private var seen: Set<String> = []
    private var recent: [String] = []
    private var handler: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?
    var hasPendingWork: Bool { !pending.isEmpty }
    init(directory: URL) { self.directory = directory }
    deinit { stop() }
    func start(_ handler: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) throws {
        if timer != nil { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw failure("浏览器 IPC 目录不能为符号链接。") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let endpoint = directory.appendingPathComponent("endpoint.json")
        if let data = try? Data(contentsOf: endpoint), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = old["pid"] as? Int32, old["nonce"] as? String != nonce, Darwin.kill(pid,0) == 0 { throw failure("另一个 F 浏览器实例仍在运行。") }
        for name in ["requests","responses"] { try fm.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        self.handler = handler
        try write(["version":1,"pid":getpid(),"nonce":nonce,"key":key.withUnsafeBytes { Data($0).base64EncodedString() }], to:endpoint)
        let timer = Timer(timeInterval:0.2,repeats:true) { [weak self] _ in self?.poll() }; RunLoop.main.add(timer,forMode:.common); self.timer = timer
    }
    func stop() {
        timer?.invalidate(); timer = nil; handler = nil
        for id in pending { respond(id,["ok":false,"error":"F 浏览器已关闭"] ) }; pending.removeAll()
        let endpoint = directory.appendingPathComponent("endpoint.json")
        if let data = try? Data(contentsOf:endpoint), let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any], value["nonce"] as? String == nonce { try? FileManager.default.removeItem(at:endpoint) }
    }
    private func poll() {
        if let old = FileManager.default.enumerator(at:directory.appendingPathComponent("responses"),includingPropertiesForKeys:[.contentModificationDateKey],options:[.skipsSubdirectoryDescendants]) {
            for _ in 0..<32 { guard let file = old.nextObject() as? URL else { break }; if file.lastPathComponent.range(of:#"^[a-f0-9-]{36}\.json$"#,options:.regularExpression) != nil, let date = try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 120 { try? FileManager.default.removeItem(at:file) } }
        }
        guard let handler, let files = FileManager.default.enumerator(at:directory.appendingPathComponent("requests"),includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsSubdirectoryDescendants]) else { return }
        for _ in 0..<32 {
            guard pending.count < 4, let file = files.nextObject() as? URL else { break }
            guard file.lastPathComponent.range(of:#"^[a-f0-9-]{36}\.json$"#,options:.regularExpression) != nil else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            do {
                let info = try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 1_500_000 else { throw failure("浏览器请求无效。") }
                let data = try Data(contentsOf:file)
                try FileManager.default.removeItem(at:file)
                guard !seen.contains(id) else { continue }
                guard let envelope = try JSONSerialization.jsonObject(with:data) as? [String:Any], envelope["nonce"] as? String == nonce,
                      let cipher = envelope["ciphertext"] as? String, let encoded = Data(base64Encoded:cipher) else { throw failure("浏览器连接已更新，请重试。") }
                let plain = try AES.GCM.open(AES.GCM.SealedBox(combined:encoded),using:key,authenticating:Data(nonce.utf8))
                guard let input = try JSONSerialization.jsonObject(with:plain) as? [String:Any] else { throw failure("浏览器请求格式无效。") }
                seen.insert(id); recent.append(id); if recent.count > 512 { seen.remove(recent.removeFirst()) }
                pending.insert(id)
                handler(input) { [weak self] value in
                    DispatchQueue.main.async { guard let self, self.pending.remove(id) != nil else { return }; self.respond(id,value) }
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+30) { [weak self] in guard let self, self.pending.remove(id) != nil else { return }; self.respond(id,["ok":false,"error":"浏览器操作超时，请读取页面后重试"] ) }
            } catch { try? FileManager.default.removeItem(at:file); respond(id,["ok":false,"error":"浏览器请求未执行：连接或数据校验失败"] ) }
        }
    }
    private func respond(_ id: String, _ result: [String:Any]) { try? write(result,to:directory.appendingPathComponent("responses/"+id+".json")) }
    private func write(_ value: [String:Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(value) else { throw failure("浏览器结果不可序列化。") }
        let data = try JSONSerialization.data(withJSONObject:value); try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func failure(_ message: String) -> NSError { NSError(domain:"F Browser",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    static func install(extensionID: String) throws -> URL {
        guard let resources = Bundle.main.resourceURL,
              let cli = Bundle.main.object(forInfoDictionaryKey:"PiCLIPath") as? String else { throw NSError(domain:"F Browser",code:1,userInfo:[NSLocalizedDescriptionKey:"浏览器连接资源缺失。"] ) }
        let node = URL(fileURLWithPath:cli).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime/node/bin/node")
        let process = Process(), output = Pipe(); process.executableURL = node
        process.arguments = [resources.appendingPathComponent("runtime/harness/src/browser/install-bridge.mjs").path,"--node",node.path,"--extension-id",extensionID]
        process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain:"F Browser",code:2,userInfo:[NSLocalizedDescriptionKey:String(data:data,encoding:.utf8) ?? "Chrome 连接配置失败。"] ) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/F/browser-bridge")
    }
}
