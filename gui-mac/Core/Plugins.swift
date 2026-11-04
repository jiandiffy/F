import AppKit
import CryptoKit

enum PluginPlacement { case workspace, bottom, service }
enum PluginProjectAssociation { case independent, project }
struct PluginMenuCommand {
    let title: String
    let id: String
    static let separator = PluginMenuCommand(title: "", id: "")
}

enum PluginPreferences {
    static let disabledKey = "FDisabledPlugins"
    static func disabledIDs(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: disabledKey) ?? [])
    }
    static func isEnabled(_ id: String) -> Bool { !disabledIDs().contains(id) }
    static var signature: String { disabledIDs().sorted().joined(separator: ",") }
}

/// Application-owned storage. A project-bound plugin gets a separate directory for each stable project URL.
enum PluginStorage {
    static func directory(for id: String, project: URL? = nil) -> URL {
        precondition(id.range(of: #"^[a-z0-9][a-z0-9.-]*$"#, options: .regularExpression) != nil)
        let root = BoardStore.appSupport.appendingPathComponent("applications/" + id, isDirectory: true)
        guard let project else { return root.appendingPathComponent("global", isDirectory: true) }
        let digest = SHA256.hash(data: Data(project.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }
}

/// 底栏模块可以同时运行多个独立进程（terminal、ssh、side agent）。
/// 未实现该协议的底栏模块仍会出现在选择页和新建菜单里，但只保留一个实例。
protocol FProcessProvider: AnyObject {
    /// 新进程的默认名称。
    var processDefaultName: String { get }
    /// 创建独立进程实例；实例拥有自己的视图、进程和资源。
    func makeProcess(project: URL) -> FPlugin
}

/// 需要主对话上下文的停靠区进程（例如 side agent）。
protocol FContextualProcess: AnyObject {
    /// 主对话最近的文字记录；每次请求都会重新读取一次。
    var contextProvider: (() -> String)? { get set }
    /// 当前对话专属的画板目录，让进程和主对话操作同一块画板。
    var boardDirectoryProvider: (() -> URL)? { get set }
}

/// 停靠区进程还有未完成的任务或队列；更新重启必须等它结束。
protocol FProcessActivity: AnyObject {
    var hasPendingWork: Bool { get }
}

protocol FPlugin: AnyObject {
    var id: String { get }
    var requiredServices: [String] { get }
    var providedServices: [String] { get }
    func mount(in scope: FPluginScope)
    var title: String { get }
    var symbol: String { get }
    var placement: PluginPlacement { get }
    var projectAssociation: PluginProjectAssociation { get }
    var menuCommands: [PluginMenuCommand] { get }
    var view: NSView { get }
    /// Optional top row constrained to the workspace and host corner controls.
    var toolbarView: NSView? { get }
    var sidebarView: NSView? { get }
    var onRequestSidebar: (() -> Void)? { get set }
    func performMenuCommand(_ id: String)
    func setEnabled(_ enabled: Bool)
    func activate()
    func reselect()
    func deactivate()
    func projectDidChange(_ project: URL)
    func applyAppearance(dark: Bool)
    func prepareToClose(_ completion: @escaping () -> Void)
    func shutdown()
    func confirmClose(_ completion: @escaping (Bool) -> Void)
}

extension FPlugin {
    var toolbarView: NSView? { nil }
    var requiredServices: [String] { [] }
    var providedServices: [String] { ["plugin." + id] }
    func mount(in scope: FPluginScope) {
        scope.effect {
            setEnabled(true)
            return { [self] in setEnabled(false) }
        }
    }
    var projectAssociation: PluginProjectAssociation { .independent }
    var menuCommands: [PluginMenuCommand] { [PluginMenuCommand(title: "打开", id: "open")] }
    var sidebarView: NSView? { nil }
    var onRequestSidebar: (() -> Void)? { get { nil } set {} }
    func performMenuCommand(_ id: String) {}
    func setEnabled(_ enabled: Bool) { if !enabled { deactivate(); shutdown() } }
    func activate() {}
    func reselect() { activate() }
    func deactivate() {}
    func projectDidChange(_ project: URL) {}
    func applyAppearance(dark: Bool) {}
    func prepareToClose(_ completion: @escaping () -> Void) { completion() }
    func shutdown() {}
    func confirmClose(_ completion: @escaping (Bool) -> Void) { completion(true) }
}

final class PluginRegistry {
    private(set) var plugins: [FPlugin] = []
    let kernel = FKernel()
    private let defaults: UserDefaults
    private var latestProject: URL?
    private var latestAppearance = false
    private var changing: Set<String> = []
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func register(_ plugin: FPlugin) {
        precondition(!plugins.contains { $0.id == plugin.id }, "Duplicate F plugin: \(plugin.id)")
        plugins.append(plugin)
        if isEnabled(plugin.id) { mount(plugin) } else { plugin.setEnabled(false) }
    }
    func isEnabled(_ id: String) -> Bool { !PluginPreferences.disabledIDs(in: defaults).contains(id) }
    private func mount(_ plugin: FPlugin) {
        kernel.mount(plugin.id, requires: plugin.requiredServices) { [weak self] scope in
            guard let self else { return }
            if plugin.projectAssociation == .project, let project = self.latestProject { plugin.projectDidChange(project) }
            plugin.applyAppearance(dark: self.latestAppearance)
            plugin.mount(in: scope)
            for key in plugin.providedServices { self.kernel.provide(key, plugin, in: scope) }
        }
    }
    var enabledPlugins: [FPlugin] { plugins.filter { kernel.isMounted($0.id) } }
    var applicationPlugins: [FPlugin] { enabledPlugins.filter { $0.placement == .workspace } }
    var bottomPlugins: [FPlugin] { enabledPlugins.filter { $0.placement == .bottom } }
    func plugin(_ id: String) -> FPlugin? { plugins.first { $0.id == id } }
    func setEnabled(_ id: String, _ enabled: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let plugin = plugin(id), !changing.contains(id) else { completion(false); return }
        guard isEnabled(id) != enabled else { completion(true); return }
        changing.insert(id)
        let commit = { [weak self] in
            guard let self else { completion(false); return }
            var disabled = PluginPreferences.disabledIDs(in: self.defaults)
            if enabled { disabled.remove(id) } else { disabled.insert(id) }
            self.defaults.set(disabled.sorted(), forKey: PluginPreferences.disabledKey)
            if enabled { self.mount(plugin) } else { self.kernel.unmount(id) }
            self.changing.remove(id)
            self.onChange?()
            completion(true)
        }
        if enabled { commit() }
        else {
            plugin.confirmClose { [weak self] allowed in
                guard allowed else { self?.changing.remove(id); completion(false); return }
                plugin.prepareToClose(commit)
            }
        }
    }
    func projectDidChange(_ project: URL) {
        latestProject = project
        enabledPlugins.filter { $0.projectAssociation == .project }.forEach { $0.projectDidChange(project) }
    }
    func applyAppearance(dark: Bool) { latestAppearance = dark; enabledPlugins.forEach { $0.applyAppearance(dark: dark) } }
    func shutdown() { kernel.shutdown() }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        let active = enabledPlugins
        func check(_ index: Int) {
            guard index < active.count else { completion(true); return }
            active[index].confirmClose { allowed in if allowed { check(index + 1) } else { completion(false) } }
        }
        check(0)
    }
    func prepareToClose(_ completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for plugin in enabledPlugins { group.enter(); plugin.prepareToClose { group.leave() } }
        group.notify(queue: .main, execute: completion)
    }
}
