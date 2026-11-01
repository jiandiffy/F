import AppKit

/// Register a module here to add its bottom-panel entry. RootView owns only layout.
enum BuiltInPlugins {
    static func make(project: URL) -> PluginRegistry {
        let registry = PluginRegistry()
        registry.register(WhiteboardPlugin(project: project))
        registry.register(TerminalPlugin(project: project))
        registry.register(SSHPlugin())
        registry.register(SideAgentPlugin(project: project))
        registry.register(FilesPlugin(project: project))
        registry.register(VersionsPlugin(project: project))
        registry.register(AgentCapabilityPlugin(id: "aios", title: "目标编排"))
        registry.register(AgentCapabilityPlugin(id: "datasets", title: "Datasets"))
        registry.register(AgentCapabilityPlugin(id: "skills", title: "Skills"))
        registry.register(AgentCapabilityPlugin(id: "subagent", title: "Subagent"))
        registry.register(AgentCapabilityPlugin(id: "workflow", title: "Workflow", requires: ["plugin.subagent"]))
        return registry
    }
}

/// Headless capabilities participate in the same persisted plugin switches.
final class AgentCapabilityPlugin: FPlugin {
    let id: String
    let title: String
    let requiredServices: [String]
    let symbol = "puzzlepiece.extension"
    let placement = PluginPlacement.service
    let view = NSView()
    init(id: String, title: String, requires: [String] = []) {
        self.id = id; self.title = title; requiredServices = requires
    }
}
