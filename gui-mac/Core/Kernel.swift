import Foundation

/// Native carrier of Cordis' scoped services, declared dependencies and reversible effects.
/// The Agent process uses upstream Cordis itself; AppKit resources stay in the native process.
final class FPluginScope {
    private weak var kernel: FKernel?
    init(kernel: FKernel? = nil) { self.kernel = kernel }
    func service<T: AnyObject>(_ key: String, as type: T.Type = T.self) -> T? { kernel?.service(key, as: type) }
    private var disposers: [() -> Void] = []
    private(set) var isDisposed = false
    func effect(_ setup: () -> (() -> Void)) {
        precondition(!isDisposed, "Cannot register into a disposed plugin scope")
        disposers.append(setup())
    }
    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        let pending = disposers.reversed()
        disposers.removeAll()
        pending.forEach { $0() }
    }
}

final class FKernel {
    private struct Mount {
        let id: String
        let requires: [String]
        let apply: (FPluginScope) -> Void
        var scope: FPluginScope?
    }
    private var services: [String: AnyObject] = [:]
    private var mounts: [Mount] = []
    private var reconciling = false
    private var dirty = false

    func service<T: AnyObject>(_ key: String, as type: T.Type = T.self) -> T? { services[key] as? T }
    func provide(_ key: String, _ value: AnyObject, in scope: FPluginScope) {
        precondition(services[key] == nil, "Duplicate service: \(key)")
        scope.effect {
            services[key] = value
            return { [weak self, weak value] in
                guard let self, self.services[key] === value else { return }
                self.services.removeValue(forKey: key)
                self.reconcile()
            }
        }
        reconcile()
    }
    func mount(_ id: String, requires: [String] = [], apply: @escaping (FPluginScope) -> Void) {
        precondition(!mounts.contains { $0.id == id }, "Duplicate mount: \(id)")
        mounts.append(Mount(id: id, requires: requires, apply: apply, scope: nil))
        reconcile()
    }
    func unmount(_ id: String) {
        guard let index = mounts.firstIndex(where: { $0.id == id }) else { return }
        let mount = mounts.remove(at: index)
        mount.scope?.dispose()
        reconcile()
    }
    func isMounted(_ id: String) -> Bool { mounts.first { $0.id == id }?.scope != nil }
    private func reconcile() {
        if reconciling { dirty = true; return }
        reconciling = true
        repeat {
            dirty = false
            for index in mounts.indices {
                let available = mounts[index].requires.allSatisfy { services[$0] != nil }
                if available, mounts[index].scope == nil {
                    let scope = FPluginScope(kernel: self)
                    mounts[index].scope = scope
                    mounts[index].apply(scope)
                } else if !available, let scope = mounts[index].scope {
                    mounts[index].scope = nil
                    scope.dispose()
                }
            }
        } while dirty
        reconciling = false
    }
    func shutdown() {
        while let id = mounts.last?.id { unmount(id) }
        services.removeAll()
    }
}
