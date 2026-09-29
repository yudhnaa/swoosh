import Foundation
import Testing
@testable import SwooshCore

@Suite
struct WindowLifecycleTests {
    @Test
    func supportedActionsRequireLiveTarget() {
        let target = targetIdentity()
        let client = MockLifecycleClient(liveTargets: [], supported: [.minimize])
        let controller = WindowLifecycleController(client: client)

        #expect(controller.supportedActions(for: target).isEmpty)
    }

    @Test
    func supportedActionDispatchesToClient() {
        let target = targetIdentity()
        let client = MockLifecycleClient(supported: [.minimize])
        let controller = WindowLifecycleController(client: client)

        let result = controller.perform(.minimize, for: target)

        #expect(result.status == .performed)
        #expect(client.performedActions == [.minimize])
    }

    @Test
    func unsupportedActionReportsMeaningfulResult() {
        let target = targetIdentity()
        let client = MockLifecycleClient(supported: [.minimize])
        let controller = WindowLifecycleController(client: client)

        let result = controller.perform(.requestClose, for: target)

        #expect(result.status == .unsupported)
        #expect(result.reason?.contains("requestClose") == true)
        #expect(client.performedActions.isEmpty)
    }

    @Test
    func targetLossRefusesActionBeforeDispatch() {
        let target = targetIdentity()
        let client = MockLifecycleClient(liveTargets: [], supported: [.requestClose])
        let controller = WindowLifecycleController(client: client)

        let result = controller.perform(.requestClose, for: target)

        #expect(result.status == .targetLost)
        #expect(client.performedActions.isEmpty)
    }

    @Test
    func rejectedClientResultPropagatesReason() {
        let target = targetIdentity()
        let client = MockLifecycleClient(
            supported: [.requestClose],
            results: [.requestClose: WindowLifecycleResult(
                action: .requestClose,
                status: .rejected,
                reason: "AXCloseButton returned actionUnsupported."
            )]
        )
        let controller = WindowLifecycleController(client: client)

        let result = controller.perform(.requestClose, for: target)

        #expect(result.status == .rejected)
        #expect(result.reason == "AXCloseButton returned actionUnsupported.")
    }

    @Test
    func fullscreenToggleMarksTransitionAndGuardsGeometryUntilFinished() throws {
        let target = targetIdentity()
        let client = MockLifecycleClient(supported: [.toggleFullscreen])
        let controller = WindowLifecycleController(client: client)

        let toggle = controller.perform(.toggleFullscreen, for: target)

        #expect(toggle.status == .performed)
        let blockedGeometry = try #require(controller.guardGeometryCommand(for: target))
        #expect(blockedGeometry.status == .transitioning)
        #expect(controller.perform(.toggleFullscreen, for: target).status == .transitioning)

        controller.finishFullscreenTransition(for: target)

        #expect(controller.guardGeometryCommand(for: target) == nil)
        #expect(controller.perform(.toggleFullscreen, for: target).status == .performed)
    }

    @Test
    func fullscreenTransitionExpiresAfterBoundedRecovery() throws {
        let target = targetIdentity()
        let client = MockLifecycleClient(supported: [.toggleFullscreen])
        var now: TimeInterval = 100
        let controller = WindowLifecycleController(
            client: client,
            transitionRecoveryInterval: 1.5,
            clock: { now }
        )

        #expect(controller.perform(.toggleFullscreen, for: target).status == .performed)
        #expect(try #require(controller.guardGeometryCommand(for: target)).status == .transitioning)

        now += 1.6

        #expect(controller.guardGeometryCommand(for: target) == nil)
        #expect(controller.perform(.toggleFullscreen, for: target).status == .performed)
    }

    @Test
    func fullscreenTransitionClearsWhenObservedStateChanges() throws {
        let target = targetIdentity()
        let client = MockLifecycleClient(
            supported: [.toggleFullscreen],
            fullscreenStates: [target: false]
        )
        let controller = WindowLifecycleController(client: client)

        #expect(controller.perform(.toggleFullscreen, for: target).status == .performed)
        #expect(try #require(controller.guardGeometryCommand(for: target)).status == .transitioning)

        client.fullscreenStates[target] = true

        #expect(controller.guardGeometryCommand(for: target) == nil)
        #expect(controller.perform(.toggleFullscreen, for: target).status == .performed)
        #expect(client.performedActions == [.toggleFullscreen, .toggleFullscreen])
    }

    @Test
    func fullscreenStateDelegatesToClient() {
        let target = targetIdentity()
        let client = MockLifecycleClient(fullscreenStates: [target: true])
        let controller = WindowLifecycleController(client: client)

        #expect(controller.isFullscreen(target) == true)
        #expect(controller.isFullscreen(targetIdentity(id: "missing")) == nil)
    }

    private func targetIdentity(id: String = "window") -> WindowTargetIdentity {
        WindowTargetIdentity(processIdentifier: 42, elementIdentifier: id)
    }
}

private final class MockLifecycleClient: WindowLifecycleControlling {
    var liveTargets: Set<WindowTargetIdentity>
    var supported: Set<WindowLifecycleAction>
    var results: [WindowLifecycleAction: WindowLifecycleResult]
    var fullscreenStates: [WindowTargetIdentity: Bool]
    var performedActions: [WindowLifecycleAction] = []

    init(
        liveTargets: Set<WindowTargetIdentity>? = nil,
        supported: Set<WindowLifecycleAction> = [],
        results: [WindowLifecycleAction: WindowLifecycleResult] = [:],
        fullscreenStates: [WindowTargetIdentity: Bool] = [:]
    ) {
        let defaultTarget = WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")
        self.liveTargets = liveTargets ?? [defaultTarget]
        self.supported = supported
        self.results = results
        self.fullscreenStates = fullscreenStates
    }

    func isAlive(_ target: WindowTargetIdentity) -> Bool {
        liveTargets.contains(target)
    }

    func supportedActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction> {
        supported
    }

    func perform(_ action: WindowLifecycleAction, for target: WindowTargetIdentity) -> WindowLifecycleResult {
        performedActions.append(action)
        return results[action] ?? WindowLifecycleResult(action: action, status: .performed)
    }

    func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        fullscreenStates[target]
    }
}
