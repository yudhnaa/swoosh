import Testing
@testable import SwooshCore

@MainActor
@Suite
struct GestureRuntimeControllerTests {
    @Test
    func chainTimeoutCommitsOnceAndLaterReleaseCannotDispatchAgain() {
        let harness = makeHarness()
        harness.start()

        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.left, at: 100, id: "left")))

        #expect(harness.scheduler.delay(for: .chainTimeout) == 200)
        #expect(!harness.scheduler.contains(.inactivityTimeout))
        #expect(harness.controller.resolverSnapshot.committableIntent?.command == .snapLeft)

        harness.scheduler.run(.chainTimeout)
        harness.capture.emit(.ended(timestampMilliseconds: 400))

        #expect(harness.dispatcher.commands == [.snapLeft])
        #expect(harness.controller.resolverSnapshot.lifecycle == .terminal)
        #expect(harness.controller.resolverSnapshot.terminalOutput?.kind == .commit)
    }

    @Test
    func releaseBeforeTimeoutCommitsOnceAndCancelsDeadline() {
        let harness = makeHarness()
        harness.start()

        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.right, at: 100, id: "right")))
        harness.capture.emit(.ended(timestampMilliseconds: 150))

        #expect(harness.dispatcher.commands == [.snapRight])
        #expect(!harness.scheduler.contains(.chainTimeout))

        harness.scheduler.run(.chainTimeout)
        #expect(harness.dispatcher.commands == [.snapRight])
    }

    @Test
    func horizontalPreviewTransitionsFromSnapToDesktopSpaceAtHoldThresholdWithoutMovement() {
        let harness = makeHarness()
        harness.start()
        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.changed(CapturedGestureProgress(
            kind: .stroke(.left),
            pointer: ScreenPoint(x: 20, y: 10),
            modifiers: [],
            timestampMilliseconds: 100
        )))

        #expect(harness.previewedCommands.last == .snapLeft)
        #expect(harness.scheduler.delay(for: .desktopSpacePreviewThreshold) == 400)

        harness.scheduler.run(.desktopSpacePreviewThreshold)

        #expect(harness.previewedCommands.last == .moveSpaceLeft)
    }

    @Test
    func disabledPreviewUIStillUsesChainTimeoutAndCommits() {
        var settings = configuredSettings()
        settings.previewsEnabled = false
        settings.overlayPreviewSize = .off
        let harness = makeHarness(settings: settings)
        harness.start()

        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.up, at: 100, id: "up")))

        #expect(harness.previewedCommands.isEmpty)
        #expect(harness.scheduler.contains(.chainTimeout))

        harness.scheduler.run(.chainTimeout)
        #expect(harness.dispatcher.commands == [.maximize])
    }

    @Test
    func settingsPauseInvalidatesPendingDeadline() {
        let harness = makeHarness()
        harness.start()
        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.down, at: 100, id: "down")))

        var paused = harness.settings
        paused.isPaused = true
        harness.controller.apply(settings: paused, permissions: .readyForGestureTests)

        #expect(!harness.scheduler.contains(.chainTimeout))
        #expect(harness.controller.resolverSnapshot.lifecycle == .idle)
        harness.scheduler.run(.chainTimeout)
        #expect(harness.dispatcher.commands.isEmpty)
    }

    @Test
    func topologyChangeCancelsPendingCommit() {
        let topology = MutableTopologyToken("topology-a")
        let harness = makeHarness(topologyTokenProvider: { topology.value })
        harness.start()
        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.left, at: 100, id: "left")))

        topology.value = "topology-b"
        harness.capture.emit(.movement(timestampMilliseconds: 120))

        #expect(harness.controller.resolverSnapshot.terminalOutput?.reason == .topologyChanged)
        #expect(!harness.scheduler.contains(.chainTimeout))
        harness.scheduler.run(.chainTimeout)
        #expect(harness.dispatcher.commands.isEmpty)
    }

    @Test
    func captureRefreshFailureInvalidatesPendingCommit() {
        let harness = makeHarness()
        harness.start()
        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.right, at: 100, id: "right")))
        harness.capture.refreshResult = .failed(.failedForGestureTests)

        harness.controller.captureDevicesDidChange()
        harness.scheduler.run(.captureRefresh)

        #expect(harness.controller.resolverSnapshot.terminalOutput?.reason == .captureFailed)
        #expect(harness.controllerStatus == .failed)
        #expect(!harness.scheduler.contains(.chainTimeout))
        #expect(harness.dispatcher.commands.isEmpty)
    }

    @Test
    func staleCaptureGenerationIsIgnoredAfterRestart() {
        let harness = makeHarness()
        harness.start()
        let staleSource = CapturedGestureSource(
            deviceID: "multitouch-1",
            generation: harness.capture.snapshot.generation
        )

        harness.controller.apply(settings: harness.settings, permissions: .readyForGestureTests)
        let currentSource = CapturedGestureSource(
            deviceID: "multitouch-1",
            generation: harness.capture.snapshot.generation
        )
        harness.capture.emit(.began(start(at: 10, source: staleSource)))

        #expect(harness.controller.resolverSnapshot.lifecycle == .idle)
        #expect(!harness.scheduler.contains(.inactivityTimeout))

        harness.capture.emit(.began(start(at: 20, source: currentSource)))
        #expect(harness.controller.resolverSnapshot.lifecycle == .active)
    }

    @Test
    func nonterminalCommitDrainsPhysicalOwnerBeforeAnotherDeviceCanAcquire() {
        let harness = makeHarness()
        harness.start()
        let generation = harness.capture.snapshot.generation
        let first = CapturedGestureSource(deviceID: "multitouch-1", generation: generation)
        let second = CapturedGestureSource(deviceID: "multitouch-2", generation: generation)
        let modifiers: Set<ModifierRole> = [harness.settings.generalModifier]

        harness.capture.emit(.began(start(at: 0, source: first, modifiers: modifiers)))
        harness.capture.emit(.strokeEnded(stroke(.down, at: 100, id: "close", source: first, modifiers: modifiers)))

        #expect(harness.dispatcher.commands == [.close])
        #expect(harness.controller.resolverSnapshot.lifecycle == .terminal)

        harness.capture.emit(.began(start(at: 110, source: second)))
        #expect(harness.controller.resolverSnapshot.lifecycle == .terminal)

        harness.capture.emit(.deviceEnded(CapturedGestureEnd(source: first, timestampMilliseconds: 120)))
        harness.capture.emit(.deviceEnded(CapturedGestureEnd(source: second, timestampMilliseconds: 130)))
        harness.capture.emit(.began(start(at: 140, source: second)))

        #expect(harness.controller.resolverSnapshot.lifecycle == .active)
        #expect(harness.dispatcher.commands == [.close])
    }

    @Test
    func inactivityTimeoutCancelsAndDrainsUntilPhysicalRelease() {
        let harness = makeHarness()
        harness.start()
        let source = CapturedGestureSource(
            deviceID: "multitouch-1",
            generation: harness.capture.snapshot.generation
        )

        harness.capture.emit(.began(start(at: 0, source: source)))
        #expect(harness.scheduler.delay(for: .inactivityTimeout) == 1_000)

        harness.scheduler.run(.inactivityTimeout)

        #expect(harness.controller.resolverSnapshot.lifecycle == .terminal)
        #expect(harness.controller.resolverSnapshot.terminalOutput?.reason == .gestureCancelled)
        #expect(harness.dispatcher.commands.isEmpty)

        harness.capture.emit(.began(start(at: 1_010, source: source)))
        #expect(harness.controller.resolverSnapshot.lifecycle == .terminal)

        harness.capture.emit(.deviceEnded(CapturedGestureEnd(source: source, timestampMilliseconds: 1_020)))
        harness.capture.emit(.began(start(at: 1_030, source: source)))
        #expect(harness.controller.resolverSnapshot.lifecycle == .active)
    }

    @Test
    func systemSleepCancelsPendingGestureAndStopsCapture() {
        let harness = makeHarness()
        harness.start()
        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.left, at: 100, id: "left")))
        #expect(harness.scheduler.contains(.chainTimeout))

        harness.controller.suspendForSystemSleep()

        #expect(harness.capture.snapshot.status == .stopped)
        #expect(harness.controller.resolverSnapshot.lifecycle == .terminal)
        #expect(harness.controller.resolverSnapshot.terminalOutput?.reason == .gestureCancelled)
        #expect(harness.scheduler.isEmpty)
        #expect(harness.dispatcher.commands.isEmpty)
    }

    @Test
    func wakeRefreshRestartsCaptureAfterSystemSleep() {
        let harness = makeHarness()
        harness.start()
        harness.controller.suspendForSystemSleep()
        let sleepingGeneration = harness.capture.currentGeneration

        harness.controller.apply(
            settings: harness.settings,
            permissions: .readyForGestureTests
        )

        guard case .running = harness.capture.snapshot.status else {
            Issue.record("Expected capture to restart after the forced wake refresh")
            return
        }
        #expect(harness.capture.currentGeneration > sleepingGeneration)
        #expect(harness.controllerStatus == .running)
    }

    @Test
    func shutdownCancelsDeadlinesStopsCaptureAndResetsCoordinator() {
        let harness = makeHarness()
        harness.start()
        harness.capture.emit(.began(start(at: 0)))
        #expect(harness.scheduler.contains(.inactivityTimeout))

        harness.controller.shutdown()

        #expect(harness.capture.snapshot.status == .stopped)
        #expect(harness.controller.resolverSnapshot.lifecycle == .idle)
        #expect(harness.controllerStatus == .stopped)
        #expect(harness.scheduler.isEmpty)
        #expect(harness.dispatcher.commands.isEmpty)
    }

    private func makeHarness(
        settings: SwooshSettings? = nil,
        topologyTokenProvider: @escaping () -> String = { "topology-a" }
    ) -> RuntimeHarness {
        RuntimeHarness(
            settings: settings ?? configuredSettings(),
            topologyTokenProvider: topologyTokenProvider
        )
    }

    private func configuredSettings() -> SwooshSettings {
        var settings = SwooshSettings.defaults
        settings.chainTimeoutMilliseconds = 200
        settings.gestureIdleTimeoutMilliseconds = 1_000
        return settings
    }

    private func start(
        at timestamp: Int,
        source: CapturedGestureSource = .unspecified,
        modifiers: Set<ModifierRole> = []
    ) -> CapturedGestureStart {
        CapturedGestureStart(
            source: source,
            pointer: ScreenPoint(x: 20, y: 10),
            modifiers: modifiers,
            timestampMilliseconds: timestamp
        )
    }

    private func stroke(
        _ direction: GestureDirection,
        at timestamp: Int,
        id: String,
        source: CapturedGestureSource = .unspecified,
        modifiers: Set<ModifierRole> = []
    ) -> CapturedGestureStroke {
        CapturedGestureStroke(
            source: source,
            direction: direction,
            pointer: ScreenPoint(x: 20, y: 10),
            modifiers: modifiers,
            timestampMilliseconds: timestamp,
            eventID: id
        )
    }
}

@MainActor
private final class RuntimeHarness {
    let settings: SwooshSettings
    let capture = MockRuntimeCapture()
    let scheduler = ManualGestureRuntimeScheduler()
    let dispatcher = RuntimeGestureDispatcher()
    private let callbacks = RuntimeCallbackRecorder()
    let controller: GestureRuntimeController

    var previewedCommands: [KeyboardCommand] { callbacks.previewedCommands }
    var controllerStatus: GestureInputStatus? { callbacks.controllerStatus }

    init(settings: SwooshSettings, topologyTokenProvider: @escaping () -> String) {
        self.settings = settings
        let target = WindowTarget(
            identity: WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window"),
            source: .pointerTitlebar,
            rolePath: ["AXWindow"],
            availableActions: []
        )
        let targetResolver = RuntimeTargetResolver(target: target)
        let coordinator = GestureInputCoordinator(settings: settings, dispatcher: dispatcher)
        controller = GestureRuntimeController(
            capture: capture,
            targetResolver: targetResolver,
            coordinator: coordinator,
            scheduler: scheduler,
            clock: FixedGestureRuntimeClock(nowMilliseconds: 5_000),
            topologyTokenProvider: topologyTokenProvider,
            onStatusChanged: { [callbacks] status, _ in callbacks.controllerStatus = status },
            onPreviewChanged: { [callbacks] command, _, _, _ in callbacks.previewedCommands.append(command) }
        )
    }

    func start() {
        controller.apply(settings: settings, permissions: .readyForGestureTests)
    }
}

@MainActor
private final class RuntimeCallbackRecorder {
    var previewedCommands: [KeyboardCommand] = []
    var controllerStatus: GestureInputStatus?
}

@MainActor
private final class ManualGestureRuntimeScheduler: GestureRuntimeScheduling {
    private var actions: [GestureRuntimeScheduledTask: @MainActor @Sendable () -> Void] = [:]
    private var delays: [GestureRuntimeScheduledTask: Int] = [:]

    func schedule(
        _ task: GestureRuntimeScheduledTask,
        afterMilliseconds delayMilliseconds: Int,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        actions[task] = action
        delays[task] = delayMilliseconds
    }

    func cancel(_ task: GestureRuntimeScheduledTask) {
        actions[task] = nil
        delays[task] = nil
    }

    func cancelAll() {
        actions.removeAll()
        delays.removeAll()
    }

    func contains(_ task: GestureRuntimeScheduledTask) -> Bool {
        actions[task] != nil
    }

    func delay(for task: GestureRuntimeScheduledTask) -> Int? {
        delays[task]
    }

    var isEmpty: Bool {
        actions.isEmpty && delays.isEmpty
    }

    func run(_ task: GestureRuntimeScheduledTask) {
        let action = actions.removeValue(forKey: task)
        delays[task] = nil
        action?()
    }
}

private struct FixedGestureRuntimeClock: GestureRuntimeClock {
    var nowMilliseconds: Int
}

private final class MockRuntimeCapture: GestureCaptureSource, @unchecked Sendable {
    private(set) var snapshot: GestureCaptureSnapshot = .stopped
    var refreshResult: GestureCaptureSourceStatus = .running(.readyForGestureTests)
    private var handler: (@MainActor @Sendable (CapturedGestureEvent) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (CapturedGestureEvent) -> Void) -> GestureCaptureSourceStatus {
        if self.handler != nil, case .running = snapshot.status {
            return snapshot.status
        }
        let generation = snapshot.generation + 1
        self.handler = handler
        let status = GestureCaptureSourceStatus.running(.readyForGestureTests)
        snapshot = GestureCaptureSnapshot(status: status, generation: generation)
        return status
    }

    func refreshDevices() -> GestureCaptureSourceStatus {
        snapshot = GestureCaptureSnapshot(status: refreshResult, generation: snapshot.generation)
        return refreshResult
    }

    func stop() {
        guard handler != nil || snapshot.status != .stopped else {
            return
        }
        snapshot = GestureCaptureSnapshot(status: .stopped, generation: snapshot.generation + 1)
        handler = nil
    }

    func emit(_ event: CapturedGestureEvent) {
        handler?(event)
    }
}

private struct RuntimeTargetResolver: WindowTargetResolving {
    var target: WindowTarget

    func targetUnderPointer(at point: ScreenPoint) -> Result<WindowTarget, WindowTargetFailure> {
        .success(target)
    }

    func targetUnderPointer(
        at point: ScreenPoint,
        fallingBackToFrontmost fallbackToFrontmost: Bool
    ) -> Result<WindowTarget, WindowTargetFailure> {
        .success(target)
    }
}

private final class RuntimeGestureDispatcher: WindowCommandDispatching {
    private(set) var commands: [KeyboardCommand] = []

    func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) -> WindowCommandResult {
        commands.append(command)
        return WindowCommandResult(command: command, status: .performed, target: target)
    }
}

private final class MutableTopologyToken: @unchecked Sendable {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

private extension PermissionDiagnostics {
    static var readyForGestureTests: PermissionDiagnostics {
        PermissionDiagnostics(
            accessibilityTrusted: true,
            inputMonitoringTrusted: true,
            privateMultitouch: .readyForGestureTests
        )
    }
}

private extension PrivateCaptureDiagnostics {
    static var readyForGestureTests: PrivateCaptureDiagnostics {
        PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: 1,
            startedDeviceCount: 1,
            started: true,
            reason: "ready"
        )
    }

    static var failedForGestureTests: PrivateCaptureDiagnostics {
        PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: 1,
            startedDeviceCount: 0,
            failedDeviceCount: 1,
            started: false,
            reason: "failed"
        )
    }
}
