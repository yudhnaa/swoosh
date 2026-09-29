import Testing
@testable import SwooshCore

@Suite
struct GestureInputCoordinatorTests {
    @Test
    func startExposesPermissionAndCaptureFailures() {
        let permission = coordinator()
        permission.start(permissionReady: false, captureReady: true)
        #expect(permission.currentStatus == .failed)
        #expect(permission.currentFailureReason == .permissionDenied)

        let capture = coordinator()
        capture.start(permissionReady: true, captureReady: false)
        #expect(capture.currentStatus == .failed)
        #expect(capture.currentFailureReason == .captureUnavailable)
    }

    @Test
    func eligibleUnmodifiedSwipeDispatchesLatchedTargetOnceAfterTimeout() {
        let dispatcher = MockGestureDispatcher()
        let coordinator = coordinator(dispatcher: dispatcher)
        coordinator.start(permissionReady: true, captureReady: true)

        #expect(coordinator.handle(.begin(start())).resolverOutput == .none)
        #expect(coordinator.handle(.strokeEnded(stroke(.left, at: 100))).resolverOutput.kind == .preview)

        let committed = coordinator.handle(.timeout(timestampMilliseconds: 900), actionID: "left-1")

        #expect(committed.resolverOutput.kind == .commit)
        #expect(committed.resolverOutput.intent?.command == .snapLeft)
        #expect(committed.commandResult?.status == .performed)
        #expect(dispatcher.commands == [.snapLeft])
        #expect(dispatcher.targets == [target])
    }

    @Test
    func newBeginAfterCommitStartsAnotherGestureSession() {
        let dispatcher = MockGestureDispatcher()
        let coordinator = coordinator(dispatcher: dispatcher)
        coordinator.start(permissionReady: true, captureReady: true)

        _ = coordinator.handle(.begin(start()))
        _ = coordinator.handle(.strokeEnded(stroke(.left, at: 100)))
        _ = coordinator.handle(.timeout(timestampMilliseconds: 900), actionID: "first")

        _ = coordinator.handle(.begin(start()))
        _ = coordinator.handle(.pinchEnded(pinch(.outward, at: 1_000)), actionID: "second")

        #expect(dispatcher.commands == [.snapLeft, .toggleFullscreen])
    }

    @Test
    func duplicateActionIdentifiersSuppressRepeatedDispatch() {
        let dispatcher = MockGestureDispatcher()
        let coordinator = coordinator(dispatcher: dispatcher)
        coordinator.start(permissionReady: true, captureReady: true)

        _ = coordinator.handle(.begin(start()))
        _ = coordinator.handle(.pinchEnded(pinch(.inward, at: 100)), actionID: "same")
        _ = coordinator.handle(.begin(start()))
        let duplicate = coordinator.handle(.pinchEnded(pinch(.outward, at: 200)), actionID: "same")
        _ = coordinator.handle(.begin(start()))
        _ = coordinator.handle(.pinchEnded(pinch(.outward, at: 300)), actionID: "different")

        #expect(duplicate.resolverOutput == .none)
        #expect(dispatcher.commands == [.close, .toggleFullscreen])
    }

    @Test
    func directDispatchUsesTargetAndSuppressesDuplicateActionIdentifiers() {
        let dispatcher = MockGestureDispatcher()
        let coordinator = coordinator(dispatcher: dispatcher)
        coordinator.start(permissionReady: true, captureReady: true)

        let first = coordinator.dispatch(.centerAndUnsnap, to: target, actionID: "tap-1")
        let duplicate = coordinator.dispatch(.center, to: target, actionID: "tap-1")

        #expect(first.resolverOutput.kind == .commit)
        #expect(first.resolverOutput.intent?.command == .centerAndUnsnap)
        #expect(first.commandResult?.status == .performed)
        #expect(duplicate.resolverOutput == .none)
        #expect(dispatcher.commands == [.centerAndUnsnap])
        #expect(dispatcher.targets == [target])
    }

    @Test
    func pausedDisabledMissingTargetAndUnsupportedModifiersPassThroughWithoutDispatch() {
        var disabledSettings = SwooshSettings.defaults
        disabledSettings.gesturesEnabled = false
        let disabledDispatcher = MockGestureDispatcher()
        let disabled = coordinator(settings: disabledSettings, dispatcher: disabledDispatcher)
        disabled.start(permissionReady: true, captureReady: true)
        #expect(disabled.handle(.begin(start())).resolverOutput.kind == .passThrough)
        #expect(disabledDispatcher.commands.isEmpty)

        var pausedSettings = SwooshSettings.defaults
        pausedSettings.isPaused = true
        let pausedDispatcher = MockGestureDispatcher()
        let paused = coordinator(settings: pausedSettings, dispatcher: pausedDispatcher)
        paused.start(permissionReady: true, captureReady: true)
        #expect(paused.currentStatus == .paused)
        #expect(paused.handle(.begin(start())).resolverOutput.kind == .passThrough)

        let missingDispatcher = MockGestureDispatcher()
        let missing = coordinator(dispatcher: missingDispatcher)
        missing.start(permissionReady: true, captureReady: true)
        #expect(missing.handle(.begin(GestureSessionStart(target: nil, timestampMilliseconds: 0))).resolverOutput.kind == .passThrough)

        let unsupportedDispatcher = MockGestureDispatcher()
        let unsupported = coordinator(dispatcher: unsupportedDispatcher)
        unsupported.start(permissionReady: true, captureReady: true)
        #expect(unsupported.handle(.begin(start(modifiers: [.shift]))).resolverOutput.kind == .passThrough)

        #expect(pausedDispatcher.commands.isEmpty)
        #expect(missingDispatcher.commands.isEmpty)
        #expect(unsupportedDispatcher.commands.isEmpty)
    }

    @Test
    func cancellationAndListenerFailurePreventPendingCommit() {
        let cancelledDispatcher = MockGestureDispatcher()
        let cancelled = coordinator(dispatcher: cancelledDispatcher)
        cancelled.start(permissionReady: true, captureReady: true)

        _ = cancelled.handle(.begin(start()))
        _ = cancelled.handle(.strokeEnded(stroke(.down, at: 100)))
        let cancel = cancelled.cancel(.targetLost, at: 150)
        let afterCancel = cancelled.handle(.timeout(timestampMilliseconds: 900), actionID: "late")

        #expect(cancel.resolverOutput.kind == .cancel)
        #expect(cancel.resolverOutput.reason == .targetLost)
        #expect(afterCancel.resolverOutput == .none)
        #expect(cancelledDispatcher.commands.isEmpty)

        let failedDispatcher = MockGestureDispatcher()
        let failed = coordinator(dispatcher: failedDispatcher)
        failed.start(permissionReady: true, captureReady: true)
        _ = failed.handle(.begin(start()))
        failed.listenerFailed()

        #expect(failed.currentStatus == .failed)
        #expect(failed.currentFailureReason == .listenerFailed)
        #expect(failed.handle(.pinchEnded(pinch(.inward, at: 200)), actionID: "failed").resolverOutput.kind == .passThrough)
        #expect(failedDispatcher.commands.isEmpty)
    }

    @Test
    func topologyChangesCancelPreviewAndPreventStaleCommit() {
        let dispatcher = MockGestureDispatcher()
        let coordinator = coordinator(dispatcher: dispatcher)
        coordinator.start(permissionReady: true, captureReady: true)

        _ = coordinator.handle(.begin(start()))
        let preview = coordinator.handle(.strokeEnded(stroke(.left, at: 100)))
        let cancel = coordinator.cancelIfTopologyChanged(currentTopologyToken: "topology-b", at: 150)
        let release = coordinator.handle(.release(timestampMilliseconds: 180), actionID: "release-after-topology-change")

        #expect(preview.resolverOutput.kind == .preview)
        #expect(cancel.resolverOutput.kind == .cancel)
        #expect(cancel.resolverOutput.reason == .topologyChanged)
        #expect(release.resolverOutput == .none)
        #expect(dispatcher.commands.isEmpty)
    }

    @Test
    func matchingTopologyKeepsPreviewCommitEligible() {
        let dispatcher = MockGestureDispatcher()
        let coordinator = coordinator(dispatcher: dispatcher)
        coordinator.start(permissionReady: true, captureReady: true)

        _ = coordinator.handle(.begin(start()))
        _ = coordinator.handle(.strokeEnded(stroke(.right, at: 100)))
        let noCancel = coordinator.cancelIfTopologyChanged(currentTopologyToken: "topology-a", at: 150)
        let release = coordinator.handle(.release(timestampMilliseconds: 180), actionID: "release-same-topology")

        #expect(noCancel.resolverOutput == .none)
        #expect(release.resolverOutput.kind == .commit)
        #expect(release.commandResult?.status == .performed)
        #expect(dispatcher.commands == [.snapRight])
    }

    @Test
    func settingsUpdatesRebuildTimeoutAndPauseState() {
        var settings = SwooshSettings.defaults
        settings.chainTimeoutMilliseconds = 200
        let dispatcher = MockGestureDispatcher()
        let coordinator = coordinator(settings: settings, dispatcher: dispatcher)
        coordinator.start(permissionReady: true, captureReady: true)

        _ = coordinator.handle(.begin(start()))
        _ = coordinator.handle(.strokeEnded(stroke(.right, at: 100)))
        #expect(coordinator.handle(.timeout(timestampMilliseconds: 299), actionID: "early").resolverOutput == .none)
        #expect(coordinator.handle(.timeout(timestampMilliseconds: 300), actionID: "right").commandResult?.status == .performed)

        settings.isPaused = true
        coordinator.updateSettings(settings)
        #expect(coordinator.currentStatus == .paused)
        #expect(coordinator.handle(.begin(start())).resolverOutput.kind == .passThrough)
    }

    private var target: WindowTargetIdentity {
        WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")
    }

    private func coordinator(
        settings: SwooshSettings = .defaults,
        dispatcher: MockGestureDispatcher = MockGestureDispatcher()
    ) -> GestureInputCoordinator {
        GestureInputCoordinator(settings: settings, dispatcher: dispatcher)
    }

    private func start(
        modifiers: Set<ModifierRole> = [],
        at timestamp: Int = 0
    ) -> GestureSessionStart {
        GestureSessionStart(
            target: target,
            modifiers: modifiers,
            timestampMilliseconds: timestamp,
            topologyToken: "topology-a"
        )
    }

    private func stroke(
        _ direction: GestureDirection,
        at timestamp: Int,
        id: String? = nil
    ) -> GestureStroke {
        GestureStroke(direction: direction, timestampMilliseconds: timestamp, eventID: id)
    }

    private func pinch(
        _ direction: GesturePinchDirection,
        at timestamp: Int,
        id: String? = nil
    ) -> GesturePinch {
        GesturePinch(direction: direction, timestampMilliseconds: timestamp, eventID: id)
    }
}

private final class MockGestureDispatcher: WindowCommandDispatching {
    private(set) var commands: [KeyboardCommand] = []
    private(set) var targets: [WindowTargetIdentity] = []

    func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) -> WindowCommandResult {
        commands.append(command)
        targets.append(target)
        return WindowCommandResult(command: command, status: .performed, target: target)
    }
}
