import Foundation
import Testing
@testable import SwooshCore

// MARK: - Async Runtime Stabilization Tests

@MainActor
@Suite
struct AsyncGestureRuntimeTests {

    @Test
    func newerPreviewWinsWhenAsyncPreviewLookupsCompleteOutOfOrder() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()
        harness.capture.emit(.began(start(at: 0, modifiers: [.command])))
        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        harness.capture.emit(.changed(progress(.left, at: 10, modifiers: [.command])))
        harness.capture.emit(.changed(progress(.right, at: 20, modifiers: [.command])))
        await settle()
        #expect(harness.asyncResolver.pendingPreviewCommands == [.moveDisplayLeft, .moveDisplayRight])

        harness.asyncResolver.completePreview(at: 1)
        await settle()
        #expect(harness.presentedCommands == [.moveDisplayLeft, .moveDisplayRight, .moveDisplayRight])

        harness.asyncResolver.completePreview(at: 0)
        await settle()
        #expect(harness.presentedCommands == [.moveDisplayLeft, .moveDisplayRight, .moveDisplayRight])
    }

    @Test
    func previewCompletionAfterPreviewEndedIsIgnored() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()
        harness.capture.emit(.began(start(at: 0, modifiers: [.command])))
        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        harness.capture.emit(.changed(progress(.left, at: 10, modifiers: [.command])))
        await settle()
        #expect(harness.asyncResolver.pendingPreviewCommands == [.moveDisplayLeft])
        #expect(harness.presentedCommands == [.moveDisplayLeft])

        harness.capture.emit(.ended(timestampMilliseconds: 20))
        harness.asyncResolver.completePreview(at: 0)
        await settle()
        #expect(harness.presentedCommands == [.moveDisplayLeft])
    }

    @Test
    func livePreviewAppearsBeforeReleaseAndEndsImmediatelyOnCompletion() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()
        harness.capture.emit(.began(start(at: 0)))
        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        harness.capture.emit(.changed(progress(.up, at: 10, modifiers: [])))
        await settle()
        #expect(harness.presentedCommands == [.maximize])
        let endCountBeforeRelease = harness.previewEndCount

        harness.capture.emit(.strokeEnded(stroke(.up, at: 20, id: "maximize")))
        harness.capture.emit(.ended(timestampMilliseconds: 21))
        await settle()

        #expect(harness.dispatcher.commands == [.maximize])
        #expect(harness.previewEndCount > endCountBeforeRelease)
    }

    @Test
    func gestureDiagnosticsAreOffByDefaultAndRequireExplicitOptIn() {
        #expect(GestureDiagnosticsFactory.defaultSink(arguments: []) is NoOpGestureDiagnosticsSink)
        #expect(GestureDiagnosticsFactory.defaultSink(arguments: [GestureDiagnosticsFactory.launchFlag]) is StandardErrorGestureDiagnosticsSink)

        let recorder = RecordingGestureDiagnosticsSink()
        let harness = AsyncRuntimeHarness(settings: configuredSettings(), diagnosticsSink: recorder)
        harness.start()
        #expect(!recorder.messages.isEmpty)
    }

    // ── Slow Target Resolution Ordering (FIFO Mailbox) ──────────────

    @Test
    func eventsQueuedDuringSlowTargetLookupAreProcessedInFIFOOrder() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        // Begin triggers async target lookup; pendingTargetLookup is set synchronously.
        harness.capture.emit(.began(start(at: 0)))

        // Queue a stroke and release while the lookup is pending.
        harness.capture.emit(.strokeEnded(stroke(.left, at: 50, id: "left")))
        harness.capture.emit(.ended(timestampMilliseconds: 80))

        // Nothing dispatched yet — still waiting for the lookup.
        #expect(harness.dispatcher.commands.isEmpty)

        // Let the spawned Task reach the continuation.
        await Task.yield()
        #expect(harness.asyncResolver.pendingCount == 1)

        // Complete the target lookup.
        harness.asyncResolver.completeAllPending()
        // Let the continuation resume and the drainMailbox run.
        await settle()

        // FIFO processing: begin → stroke → release.
        // The stroke should preview, and release should commit.
        #expect(harness.dispatcher.commands == [.snapLeft])
    }

    @Test
    func multipleEventsQueuedDuringLookupPreserveFIFOOrder() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))

        // Queue two strokes and a release.
        harness.capture.emit(.strokeEnded(stroke(.left, at: 50, id: "stroke1")))
        harness.capture.emit(.strokeEnded(stroke(.up, at: 80, id: "stroke2")))
        harness.capture.emit(.ended(timestampMilliseconds: 100))

        #expect(harness.dispatcher.commands.isEmpty)

        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        // left+up → .snapTopLeft
        #expect(harness.dispatcher.commands == [.snapTopLeft])
    }

    // ── Stale Completion Suppression ────────────────────────────────

    @Test
    func staleAsyncCompletionIsIgnoredAfterSettingsReset() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        // First begin — starts an async lookup.
        harness.capture.emit(.began(start(at: 0)))
        await Task.yield()
        #expect(harness.asyncResolver.pendingCount == 1)

        // Settings update increments session revision and drains the mailbox.
        var next = configuredSettings()
        next.chainTimeoutMilliseconds = 300
        harness.controller.updateSettings(next)

        // Complete the lookup — should be discarded since revision changed.
        harness.asyncResolver.completeAllPending()
        await settle()

        // No session should be active because the stale completion was dropped.
        // Lifecycle is terminal from the settings-triggered cancel.
        #expect(harness.controller.resolverSnapshot.lifecycle == .idle)
        #expect(harness.dispatcher.commands.isEmpty)
    }

    @Test
    func staleCompletionAfterShutdownIsIgnored() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))
        await Task.yield()
        #expect(harness.asyncResolver.pendingCount == 1)

        // Shutdown while lookup is pending.
        harness.controller.shutdown()

        // Complete the lookup — should be discarded because revision changed.
        harness.asyncResolver.completeAllPending()
        await settle()

        #expect(harness.controller.resolverSnapshot.lifecycle == .idle)
        #expect(harness.dispatcher.commands.isEmpty)
    }

    @Test
    func staleCompletionAfterApplyIsIgnored() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))
        await Task.yield()
        #expect(harness.asyncResolver.pendingCount == 1)

        // Re-apply settings + permissions, which resets everything.
        harness.controller.apply(settings: configuredSettings(), permissions: .readyForAsyncTests)

        // Complete the old lookup — should be discarded.
        harness.asyncResolver.completeAllPending()
        await settle()

        // No gesture should be active from the stale completion.
        #expect(harness.dispatcher.commands.isEmpty)
    }

    // ── Release Before Resolution ───────────────────────────────────

    @Test
    func releaseBeforeTargetLookupCompletesStillCommits() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))

        // Stroke and release arrive before target is resolved.
        harness.capture.emit(.strokeEnded(stroke(.right, at: 50, id: "right")))
        harness.capture.emit(.ended(timestampMilliseconds: 70))

        #expect(harness.dispatcher.commands.isEmpty)

        // Now complete the lookup — queued events should drain and commit.
        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        #expect(harness.dispatcher.commands == [.snapRight])
    }

    @Test
    func cancellationDuringPendingLookupPreventsDispatch() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))

        // Queue stroke and cancellation while lookup is pending.
        harness.capture.emit(.strokeEnded(stroke(.left, at: 50, id: "left")))
        harness.capture.emit(.cancelled(.gestureCancelled, timestampMilliseconds: 60))

        #expect(harness.dispatcher.commands.isEmpty)

        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        // The cancellation in the mailbox should prevent any dispatch.
        #expect(harness.dispatcher.commands.isEmpty)
    }

    // ── Exactly-Once Action-ID Dispatch ─────────────────────────────

    @Test
    func exactlyOnceDispatchPreservedThroughAsyncMailbox() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))

        // Queue two strokes with the same eventID — only the first should dispatch.
        harness.capture.emit(.strokeEnded(stroke(.left, at: 50, id: "same-id")))
        harness.capture.emit(.strokeEnded(stroke(.left, at: 70, id: "same-id")))
        harness.capture.emit(.ended(timestampMilliseconds: 90))

        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        // Only one commit should have happened (the second stroke has
        // the same eventID and produces an overlong chain anyway).
        #expect(harness.dispatcher.commands.count == 1)
        #expect(harness.dispatcher.commands == [.snapLeft])
    }

    @Test
    func duplicateActionIDsAcrossChainTimeoutAndReleaseDispatchOnce() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        // Resolve the begin first.
        harness.capture.emit(.began(start(at: 0)))
        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        // Now stroke arrives with begin already resolved.
        harness.capture.emit(.strokeEnded(stroke(.left, at: 100, id: "left")))
        #expect(harness.controller.resolverSnapshot.committableIntent?.command == .snapLeft)

        // Timeout fires.
        harness.scheduler.run(.chainTimeout)
        await settle()
        #expect(harness.dispatcher.commands == [.snapLeft])

        // Release arrives — should not re-dispatch.
        harness.capture.emit(.ended(timestampMilliseconds: 400))
        await settle()
        #expect(harness.dispatcher.commands == [.snapLeft])
    }

    // ── Settings/Lifecycle Clear Mailbox ─────────────────────────────

    @Test
    func settingsUpdateDrainsMailbox() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.left, at: 50, id: "left")))

        // Update settings while lookup is pending — should clear mailbox.
        var updated = configuredSettings()
        updated.chainTimeoutMilliseconds = 300
        harness.controller.updateSettings(updated)

        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        // The queued stroke should have been cleared by the settings update.
        #expect(harness.dispatcher.commands.isEmpty)
    }

    @Test
    func suspendForSystemSleepDrainsMailbox() async {
        let harness = AsyncRuntimeHarness(settings: configuredSettings())
        harness.start()

        harness.capture.emit(.began(start(at: 0)))
        harness.capture.emit(.strokeEnded(stroke(.left, at: 50, id: "left")))

        harness.controller.suspendForSystemSleep()

        await Task.yield()
        harness.asyncResolver.completeAllPending()
        await settle()

        #expect(harness.dispatcher.commands.isEmpty)
        #expect(harness.capture.snapshot.status == .stopped)
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private func configuredSettings() -> SwooshSettings {
        var settings = SwooshSettings.defaults
        settings.chainTimeoutMilliseconds = 200
        settings.gestureIdleTimeoutMilliseconds = 1_000
        return settings
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
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

    private func progress(
        _ direction: GestureDirection,
        at timestamp: Int,
        modifiers: Set<ModifierRole>
    ) -> CapturedGestureProgress {
        CapturedGestureProgress(
            kind: .stroke(direction),
            pointer: ScreenPoint(x: 20, y: 10),
            modifiers: modifiers,
            timestampMilliseconds: timestamp
        )
    }
}

// MARK: - Test Infrastructure for Async Path

/// A `GestureTargetResolving` implementation that defers target resolution
/// until explicitly completed, simulating slow async AX lookups.
@MainActor
final class DeferredGestureTargetResolver: GestureTargetResolving, @unchecked Sendable {
    private var target: WindowTarget
    private var completions: [CheckedContinuation<Result<WindowTarget, WindowTargetFailure>, Never>] = []
    private var previewCompletions: [(KeyboardCommand, CheckedContinuation<DisplayMovementPreviewContext?, Never>)] = []
    private(set) var commands: [KeyboardCommand] = []

    var pendingCount: Int { completions.count }
    var pendingPreviewCommands: [KeyboardCommand] { previewCompletions.map(\.0) }

    init(target: WindowTarget) {
        self.target = target
    }

    func resolveTarget(
        at point: ScreenPoint,
        fallingBackToFrontmost: Bool
    ) async -> Result<WindowTarget, WindowTargetFailure> {
        await withCheckedContinuation { continuation in
            completions.append(continuation)
        }
    }

    func isFullscreen(_ target: WindowTargetIdentity) async -> Bool? {
        nil
    }

    func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) async -> DisplayMovementPreviewContext? {
        await withCheckedContinuation { continuation in
            previewCompletions.append((command, continuation))
        }
    }

    func dispatch(
        _ command: KeyboardCommand,
        to target: WindowTargetIdentity
    ) async -> WindowCommandResult {
        commands.append(command)
        return WindowCommandResult(command: command, status: .performed, target: target)
    }

    /// Completes all pending lookups with the configured target.
    func completeAllPending() {
        let pending = completions
        completions.removeAll()
        for continuation in pending {
            continuation.resume(returning: .success(target))
        }
    }

    /// Completes all pending lookups with a failure.
    func failAllPending(_ failure: WindowTargetFailure = .noTarget) {
        let pending = completions
        completions.removeAll()
        for continuation in pending {
            continuation.resume(returning: .failure(failure))
        }
    }

    func completePreview(at index: Int) {
        let (_, continuation) = previewCompletions.remove(at: index)
        continuation.resume(returning: nil)
    }
}

@MainActor
private final class AsyncRuntimeHarness {
    let settings: SwooshSettings
    let capture = MockRuntimeCapture()
    let scheduler = ManualGestureRuntimeScheduler()
    let asyncResolver: DeferredGestureTargetResolver
    let controller: GestureRuntimeController
    private let previewRecorder = PreviewCommandRecorder()
    var presentedCommands: [KeyboardCommand] { previewRecorder.commands }
    var previewEndCount: Int { previewRecorder.endCount }
    var dispatcher: DeferredGestureTargetResolver { asyncResolver }

    init(
        settings: SwooshSettings,
        diagnosticsSink: any GestureDiagnosticsSink = NoOpGestureDiagnosticsSink()
    ) {
        self.settings = settings
        let target = WindowTarget(
            identity: WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window"),
            source: .pointerTitlebar,
            rolePath: ["AXWindow"],
            availableActions: []
        )
        let resolver = DeferredGestureTargetResolver(target: target)
        asyncResolver = resolver
        let coordinator = GestureInputCoordinator(settings: settings)
        controller = GestureRuntimeController(
            capture: capture,
            gestureTargetResolver: resolver,
            coordinator: coordinator,
            scheduler: scheduler,
            clock: FixedGestureRuntimeClock(nowMilliseconds: 5_000),
            diagnosticsSink: diagnosticsSink,
            topologyTokenProvider: { "topology-a" },
            onPreviewChanged: { [previewRecorder] command, _, _, _ in
                previewRecorder.record(command)
            },
            onPreviewEnded: { [previewRecorder] in previewRecorder.recordEnd() }
        )
    }

    func start() {
        controller.apply(settings: settings, permissions: .readyForAsyncTests)
    }
}

private final class PreviewCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KeyboardCommand] = []
    private var endStorage = 0

    var commands: [KeyboardCommand] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var endCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return endStorage
    }

    func record(_ command: KeyboardCommand) {
        lock.lock()
        storage.append(command)
        lock.unlock()
    }

    func recordEnd() {
        lock.lock()
        endStorage += 1
        lock.unlock()
    }
}

private final class RecordingGestureDiagnosticsSink: GestureDiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func write(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }
}

// Reuse test doubles — defined privately for this test file.

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
    var refreshResult: GestureCaptureSourceStatus = .running(.readyForAsyncTests)
    private var handler: (@MainActor @Sendable (CapturedGestureEvent) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (CapturedGestureEvent) -> Void) -> GestureCaptureSourceStatus {
        let generation = snapshot.generation + 1
        self.handler = handler
        let status = GestureCaptureSourceStatus.running(.readyForAsyncTests)
        snapshot = GestureCaptureSnapshot(status: status, generation: generation)
        return status
    }

    func refreshDevices() -> GestureCaptureSourceStatus {
        snapshot = GestureCaptureSnapshot(status: refreshResult, generation: snapshot.generation)
        return refreshResult
    }

    func stop() {
        snapshot = GestureCaptureSnapshot(status: .stopped, generation: snapshot.generation + 1)
        handler = nil
    }

    func emit(_ event: CapturedGestureEvent) {
        handler?(event)
    }
}

private extension PermissionDiagnostics {
    static var readyForAsyncTests: PermissionDiagnostics {
        PermissionDiagnostics(
            accessibilityTrusted: true,
            inputMonitoringTrusted: true,
            privateMultitouch: .readyForAsyncTests
        )
    }
}

private extension PrivateCaptureDiagnostics {
    static var readyForAsyncTests: PrivateCaptureDiagnostics {
        PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: 1,
            startedDeviceCount: 1,
            started: true,
            reason: "ready"
        )
    }
}
