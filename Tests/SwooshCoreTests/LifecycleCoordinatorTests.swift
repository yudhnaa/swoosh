import Testing
@testable import SwooshCore

@Suite
struct LifecycleCoordinatorTests {
    @Test
    func shutdownAllCallsRegisteredResources() {
        let coordinator = LifecycleCoordinator()
        let first = ResourceProbe()
        let second = ResourceProbe()
        coordinator.register(first)
        coordinator.register(second)

        coordinator.shutdownAll()

        #expect(first.shutdownCalls == 1)
        #expect(second.shutdownCalls == 1)
        #expect(coordinator.shutdownCount == 1)
    }

    @Test
    func shutdownAllIsIdempotent() {
        let coordinator = LifecycleCoordinator()
        let resource = ResourceProbe()
        coordinator.register(resource)

        coordinator.shutdownAll()
        coordinator.shutdownAll()

        #expect(resource.shutdownCalls == 1)
        #expect(coordinator.shutdownCount == 1)
    }
}

private final class ResourceProbe: LifecycleResource {
    var shutdownCalls = 0

    func shutdown() {
        shutdownCalls += 1
    }
}
