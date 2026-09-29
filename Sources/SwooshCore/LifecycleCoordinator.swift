import Foundation

public protocol LifecycleResource: AnyObject {
    func shutdown()
}

public final class LifecycleCoordinator {
    private var resources: [LifecycleResource] = []
    private var hasShutdown = false
    public private(set) var shutdownCount = 0

    public init() {}

    public func register(_ resource: LifecycleResource) {
        resources.append(resource)
    }

    public func shutdownAll() {
        guard !hasShutdown else {
            return
        }

        resources.forEach { $0.shutdown() }
        resources.removeAll()
        hasShutdown = true
        shutdownCount += 1
    }
}
