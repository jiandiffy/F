import AppKit

/// The file panel is a project service; the host chooses where its view lives.
final class FilesPlugin: FPlugin {
    let id = "files"
    let title = "文件"
    let symbol = "doc.text"
    let placement = PluginPlacement.service
    let projectAssociation = PluginProjectAssociation.project
    let view = NSView()
    let browser = FileBrowserView(frame: .zero)
    var sidebarView: NSView? { browser }

    init(project: URL) { projectDidChange(project) }
    func projectDidChange(_ project: URL) {
        browser.rootURL = RemoteProjects.load(project) == nil ? project : nil
    }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        completion(browser.flushPendingEdits())
    }
    func prepareToClose(_ completion: @escaping () -> Void) {
        _ = browser.flushPendingEdits()
        completion()
    }
    func setEnabled(_ enabled: Bool) { _ = browser.panelVisibilityChanged(open: enabled) }
}
