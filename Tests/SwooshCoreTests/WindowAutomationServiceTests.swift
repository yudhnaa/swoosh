import Foundation
import Testing
@testable import SwooshCore

@Suite
struct WindowAutomationServiceTests {
    @Test @MainActor
    func slowSynchronousAutomationDoesNotBlockMainActorHeartbeat() async throws {
        let backend = SlowWindowAutomationBackend(delay: 0.4)
        let service = WindowAutomationService(backend: { backend })
        let startedAt = Date.timeIntervalSinceReferenceDate

        let operation = Task {
            await service.dispatch(.snapLeft)
        }

        try await Task.sleep(for: .milliseconds(40))
        let heartbeatElapsed = Date.timeIntervalSinceReferenceDate - startedAt

        #expect(heartbeatElapsed < 0.25)

        let result = await operation.value
        #expect(result.status == .performed)
        #expect(result.command == .snapLeft)
        #expect(Date.timeIntervalSinceReferenceDate - startedAt >= 0.35)
    }

    @Test
    func automationActorReturnsOnlyValueSnapshotsFromSynchronousBackend() async {
        let backend = SlowWindowAutomationBackend(delay: 0)
        let service = WindowAutomationService(backend: { backend })
        let target = WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")
        let requested = GeometryRect(x: 20, y: 30, width: 400, height: 300)

        #expect(await service.setFrame(requested, for: target))
        #expect(await service.frame(for: target) == requested)
        #expect(await service.supportedLifecycleActions(for: target) == [.minimize])
        #expect(await service.performLifecycleAction(.minimize, for: target).status == .performed)
    }

    @Test
    func suspendedDesktopSpaceDispatchKeepsActorResponsiveAndPreservesFIFO() async {
        let backend = SuspendingWindowAutomationBackend()
        let service = WindowAutomationService(backend: { backend })
        let target = WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")

        let move = Task { await service.dispatch(.moveSpaceLeft, to: target) }
        while !backend.hasPendingDispatch {
            await Task.yield()
        }

        let frameRequest = Task { await service.frame(for: target) }
        await Task.yield()
        #expect(backend.frameCallCount == 0)

        var heartbeatRan = false
        let heartbeat = Task { @MainActor in heartbeatRan = true }
        await heartbeat.value
        #expect(heartbeatRan)

        backend.completeDispatch()
        #expect(await move.value.status == .performed)
        #expect(await frameRequest.value == GeometryRect(x: 1, y: 2, width: 3, height: 4))
        #expect(backend.frameCallCount == 1)
    }
}

private final class SuspendingWindowAutomationBackend: WindowAutomationBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WindowCommandResult, Never>?
    private var recordedFrameCalls = 0

    var hasPendingDispatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    var frameCallCount: Int {
        lock.withLock { recordedFrameCalls }
    }

    func completeDispatch() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: WindowCommandResult(command: .moveSpaceLeft, status: .performed))
    }

    func targetUnderPointer(at point: ScreenPoint, fallingBackToFrontmost fallbackToFrontmost: Bool) -> Result<WindowTarget, WindowTargetFailure> { .failure(.noTarget) }
    func frontmostKeyboardTarget() -> Result<WindowTarget, WindowTargetFailure> { .failure(.noTarget) }
    func frame(for target: WindowTargetIdentity) -> GeometryRect? {
        lock.withLock { recordedFrameCalls += 1 }
        return GeometryRect(x: 1, y: 2, width: 3, height: 4)
    }
    func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool { true }
    func supportedLifecycleActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction> { [] }
    func performLifecycleAction(_ action: WindowLifecycleAction, for target: WindowTargetIdentity) -> WindowLifecycleResult { WindowLifecycleResult(action: action, status: .performed) }
    func finishFullscreenTransition(for target: WindowTargetIdentity) {}
    func isFullscreen(_ target: WindowTargetIdentity) -> Bool? { false }

    func dispatch(_ command: KeyboardCommand) async -> WindowCommandResult {
        await dispatch(command, to: WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window"))
    }

    func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) async -> WindowCommandResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func displayMovementPreview(for command: KeyboardCommand, target: WindowTargetIdentity) -> DisplayMovementPreviewContext? { nil }
}

private final class SlowWindowAutomationBackend: WindowAutomationBackend, @unchecked Sendable {
    private let delay: TimeInterval
    private var frames: [WindowTargetIdentity: GeometryRect] = [:]

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func targetUnderPointer(
        at point: ScreenPoint,
        fallingBackToFrontmost fallbackToFrontmost: Bool
    ) -> Result<WindowTarget, WindowTargetFailure> {
        .failure(.noTarget)
    }

    func frontmostKeyboardTarget() -> Result<WindowTarget, WindowTargetFailure> {
        .failure(.noTarget)
    }

    func frame(for target: WindowTargetIdentity) -> GeometryRect? {
        frames[target]
    }

    func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool {
        frames[target] = frame
        return true
    }

    func supportedLifecycleActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction> {
        [.minimize]
    }

    func performLifecycleAction(
        _ action: WindowLifecycleAction,
        for target: WindowTargetIdentity
    ) -> WindowLifecycleResult {
        WindowLifecycleResult(action: action, status: .performed)
    }

    func finishFullscreenTransition(for target: WindowTargetIdentity) {}

    func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        false
    }

    func dispatch(_ command: KeyboardCommand) async -> WindowCommandResult {
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        return WindowCommandResult(command: command, status: .performed)
    }

    func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) async -> WindowCommandResult {
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        return WindowCommandResult(command: command, status: .performed, target: target)
    }

    func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) -> DisplayMovementPreviewContext? {
        nil
    }
}
