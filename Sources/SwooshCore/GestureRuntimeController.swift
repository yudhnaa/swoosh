import Foundation

public enum GestureRuntimeScheduledTask: Hashable, Sendable {
    case chainTimeout
    case inactivityTimeout
    case pinchTimeout
    case desktopSpacePreviewThreshold
    case captureRefresh
}

@MainActor
public protocol GestureRuntimeScheduling: AnyObject {
    func schedule(
        _ task: GestureRuntimeScheduledTask,
        afterMilliseconds delayMilliseconds: Int,
        action: @escaping @MainActor @Sendable () -> Void
    )
    func cancel(_ task: GestureRuntimeScheduledTask)
    func cancelAll()
}

@MainActor
public final class DispatchGestureRuntimeScheduler: GestureRuntimeScheduling {
    private var workItems: [GestureRuntimeScheduledTask: DispatchWorkItem] = [:]
    private var generations: [GestureRuntimeScheduledTask: Int] = [:]

    public init() {}

    public func schedule(
        _ task: GestureRuntimeScheduledTask,
        afterMilliseconds delayMilliseconds: Int,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel(task)
        let generation = generations[task, default: 0]
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generations[task] == generation else {
                    return
                }
                self.workItems[task] = nil
                action()
            }
        }
        workItems[task] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(max(0, delayMilliseconds)),
            execute: workItem
        )
    }

    public func cancel(_ task: GestureRuntimeScheduledTask) {
        generations[task, default: 0] += 1
        workItems.removeValue(forKey: task)?.cancel()
    }

    public func cancelAll() {
        for task in workItems.keys {
            generations[task, default: 0] += 1
        }
        workItems.values.forEach { $0.cancel() }
        workItems.removeAll()
    }
}

public protocol GestureRuntimeClock: Sendable {
    var nowMilliseconds: Int { get }
}

public protocol GestureDiagnosticsSink: Sendable {
    func write(_ message: String)
}

public struct NoOpGestureDiagnosticsSink: GestureDiagnosticsSink {
    public init() {}
    public func write(_ message: String) {}
}

public struct StandardErrorGestureDiagnosticsSink: GestureDiagnosticsSink {
    private let writeHandler: @Sendable (String) -> Void

    public init(
        writeHandler: @escaping @Sendable (String) -> Void = { message in
            if let data = "[swoosh] \(message)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    ) {
        self.writeHandler = writeHandler
    }

    public func write(_ message: String) {
        writeHandler(message)
    }
}

public final class RecordingGestureDiagnosticsSink: GestureDiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    public init() {}

    public var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessages
    }

    public func write(_ message: String) {
        lock.lock()
        recordedMessages.append(message)
        lock.unlock()
    }
}

public enum GestureDiagnosticsFactory {
    public static let launchFlag = "--enable-gesture-diagnostics"
    public static let fallbackFlags = ["--gesture-diagnostics", "--debug-gestures"]

    public static func defaultSink(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        optInSink: (any GestureDiagnosticsSink)? = nil
    ) -> any GestureDiagnosticsSink {
        if arguments.contains(launchFlag) || fallbackFlags.contains(where: { arguments.contains($0) }) {
            return optInSink ?? StandardErrorGestureDiagnosticsSink()
        }
        return NoOpGestureDiagnosticsSink()
    }
}

public struct SystemGestureRuntimeClock: GestureRuntimeClock {
    public init() {}

    public var nowMilliseconds: Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}

/// Protocol for async target resolution through `WindowAutomationService`.
/// Both production and test code conform to this.
@MainActor
public protocol GestureTargetResolving: AnyObject, Sendable {
    func resolveTarget(
        at point: ScreenPoint,
        fallingBackToFrontmost: Bool
    ) async -> Result<WindowTarget, WindowTargetFailure>

    func isFullscreen(_ target: WindowTargetIdentity) async -> Bool?

    func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) async -> DisplayMovementPreviewContext?

    func dispatch(
        _ command: KeyboardCommand,
        to target: WindowTargetIdentity
    ) async -> WindowCommandResult
}

/// Adapts the `WindowAutomationService` actor to the `GestureTargetResolving` protocol.
@MainActor
public final class WindowAutomationGestureTargetResolver: GestureTargetResolving, @unchecked Sendable {
    private let service: WindowAutomationService

    public init(service: WindowAutomationService) {
        self.service = service
    }

    public func resolveTarget(
        at point: ScreenPoint,
        fallingBackToFrontmost: Bool
    ) async -> Result<WindowTarget, WindowTargetFailure> {
        await service.targetUnderPointer(
            at: point,
            fallingBackToFrontmost: fallingBackToFrontmost
        )
    }

    public func isFullscreen(_ target: WindowTargetIdentity) async -> Bool? {
        await service.isFullscreen(target)
    }

    public func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) async -> DisplayMovementPreviewContext? {
        await service.displayMovementPreview(for: command, target: target)
    }

    public func dispatch(
        _ command: KeyboardCommand,
        to target: WindowTargetIdentity
    ) async -> WindowCommandResult {
        await service.dispatch(command, to: target)
    }
}

@MainActor
public final class GestureRuntimeController: LifecycleResource {
    private let capture: GestureCaptureSource
    private let gestureTargetResolver: any GestureTargetResolving
    private let coordinator: GestureInputCoordinator
    private let scheduler: any GestureRuntimeScheduling
    private let clock: any GestureRuntimeClock
    private let diagnosticsSink: any GestureDiagnosticsSink
    private let topologyTokenProvider: () -> String
    private let onCommandResult: (WindowCommandResult) -> Void
    private let onCaptureDiagnostics: (PrivateCaptureDiagnostics) -> Void
    private let onStatusChanged: (GestureInputStatus, GestureInputFailureReason?) -> Void
    private let onDebugChanged: (String) -> Void
    private let onPreviewChanged: (KeyboardCommand, Bool?, DisplayMovementPreviewContext?, ScreenPoint) -> Void
    private let onPreviewEnded: () -> Void

    // Legacy synchronous resolver kept for backward compatibility with existing tests
    // that use `WindowTargetResolving`. When `legacyTargetResolver` is non-nil, it is used
    // for synchronous target resolution (same codepath as before).
    private let legacyTargetResolver: (any WindowTargetResolving)?

    private var settings = SwooshSettings.defaults
    private var capturedEventCount = 0
    private var titlebarRejectCount = 0
    private var commandCommitCount = 0
    private var lastDebugEvent = "No gesture events yet"
    private var pendingRestoreTap: RestoreTapCandidate?
    private var continuousInwardPinchCount = 0
    private var lastInwardPinchTarget: WindowTargetIdentity?
    private var pendingPinchGesture: PendingPinchGesture?
    private var lastPresentedPreviewLabel: String?
    private var suppressActiveGestureUntilRelease = false
    private let previewLatencyTracker = GesturePreviewLatencyTracker()
    private let captureOwnership = CaptureEventOwnershipGate()
    private let restoreDoubleTapWindowMilliseconds = 450
    private var captureRefreshScheduled = false
    private var captureRecoveryAttempt = 0
    private var lastCaptureDeviceCount = 0
    private var lastStartedCaptureDeviceCount = 0
    private let captureDeviceChangeDebounceMilliseconds = 350
    private let captureRecoveryRetryMilliseconds = 1_000
    private let maximumCaptureRecoveryAttempts = 12

    // ── FIFO Mailbox & Session Revision ─────────────────────────────
    // Events that arrive while an async target lookup is in flight are
    // queued in FIFO order and drained when the lookup completes.
    private var sessionRevision: UInt64 = 0
    private var previewRequestRevision: UInt64 = 0
    private var pendingTargetLookup = false
    private var mailbox: [CapturedGestureEvent] = []

    /// Creates a controller that uses `WindowAutomationService`-backed async
    /// target resolution (production path).
    public init(
        capture: GestureCaptureSource,
        gestureTargetResolver: any GestureTargetResolving,
        coordinator: GestureInputCoordinator,
        scheduler: any GestureRuntimeScheduling = DispatchGestureRuntimeScheduler(),
        clock: any GestureRuntimeClock = SystemGestureRuntimeClock(),
        diagnosticsSink: any GestureDiagnosticsSink = NoOpGestureDiagnosticsSink(),
        topologyTokenProvider: @escaping () -> String,
        onCommandResult: @escaping (WindowCommandResult) -> Void = { _ in },
        onCaptureDiagnostics: @escaping (PrivateCaptureDiagnostics) -> Void = { _ in },
        onStatusChanged: @escaping (GestureInputStatus, GestureInputFailureReason?) -> Void = { _, _ in },
        onDebugChanged: @escaping (String) -> Void = { _ in },
        onPreviewChanged: @escaping (KeyboardCommand, Bool?, DisplayMovementPreviewContext?, ScreenPoint) -> Void = { _, _, _, _ in },
        onPreviewEnded: @escaping () -> Void = {}
    ) {
        self.capture = capture
        self.gestureTargetResolver = gestureTargetResolver
        self.legacyTargetResolver = nil
        self.coordinator = coordinator
        self.scheduler = scheduler
        self.clock = clock
        self.diagnosticsSink = diagnosticsSink
        self.topologyTokenProvider = topologyTokenProvider
        self.onCommandResult = onCommandResult
        self.onCaptureDiagnostics = onCaptureDiagnostics
        self.onStatusChanged = onStatusChanged
        self.onDebugChanged = onDebugChanged
        self.onPreviewChanged = onPreviewChanged
        self.onPreviewEnded = onPreviewEnded
    }

    /// Legacy initializer for backward compatibility with existing tests that use
    /// synchronous `WindowTargetResolving`.
    public init(
        capture: GestureCaptureSource,
        targetResolver: any WindowTargetResolving,
        coordinator: GestureInputCoordinator,
        scheduler: any GestureRuntimeScheduling = DispatchGestureRuntimeScheduler(),
        clock: any GestureRuntimeClock = SystemGestureRuntimeClock(),
        diagnosticsSink: any GestureDiagnosticsSink = NoOpGestureDiagnosticsSink(),
        topologyTokenProvider: @escaping () -> String,
        onCommandResult: @escaping (WindowCommandResult) -> Void = { _ in },
        onCaptureDiagnostics: @escaping (PrivateCaptureDiagnostics) -> Void = { _ in },
        onStatusChanged: @escaping (GestureInputStatus, GestureInputFailureReason?) -> Void = { _, _ in },
        onDebugChanged: @escaping (String) -> Void = { _ in },
        onPreviewChanged: @escaping (KeyboardCommand, Bool?, DisplayMovementPreviewContext?, ScreenPoint) -> Void = { _, _, _, _ in },
        onPreviewEnded: @escaping () -> Void = {}
    ) {
        self.capture = capture
        self.legacyTargetResolver = targetResolver
        // Use a no-op placeholder; won't be called when legacyTargetResolver is set.
        self.gestureTargetResolver = NoOpGestureTargetResolver()
        self.coordinator = coordinator
        self.scheduler = scheduler
        self.clock = clock
        self.diagnosticsSink = diagnosticsSink
        self.topologyTokenProvider = topologyTokenProvider
        self.onCommandResult = onCommandResult
        self.onCaptureDiagnostics = onCaptureDiagnostics
        self.onStatusChanged = onStatusChanged
        self.onDebugChanged = onDebugChanged
        self.onPreviewChanged = onPreviewChanged
        self.onPreviewEnded = onPreviewEnded
    }

    public var resolverSnapshot: GestureResolverSnapshot {
        coordinator.resolverSnapshot
    }

    private func invalidatePreviewRequest() {
        previewRequestRevision &+= 1
    }

    private func endPreview() {
        invalidatePreviewRequest()
        onPreviewEnded()
    }

    /// Applies semantic and presentation settings without touching the native
    /// capture lifecycle. Callers use `apply(settings:permissions:)` only when
    /// capture eligibility or recognizer sensitivity actually changes.
    public func updateSettings(_ settings: SwooshSettings) {
        let normalized = settings.normalized
        guard normalized != self.settings else {
            return
        }

        self.settings = normalized
        scheduler.cancel(.chainTimeout)
        scheduler.cancel(.inactivityTimeout)
        scheduler.cancel(.pinchTimeout)
        scheduler.cancel(.desktopSpacePreviewThreshold)
        previewLatencyTracker.reset()
        invalidatePendingGesture(.gestureCancelled, at: clock.nowMilliseconds)
        coordinator.updateSettings(normalized)
        resetPresentationState()
        resetContinuousPinchState()
        invalidateAsyncWork()
        endPreview()
        updateDebug("gesture settings updated without capture restart")
        publishStatus()
    }

    public func apply(settings: SwooshSettings, permissions: PermissionDiagnostics) {
        self.settings = settings.normalized
        scheduler.cancelAll()
        // `apply` is the explicit capture-reconfiguration boundary (permission,
        // pause, enablement, or sensitivity changes). Stop first so an
        // idempotent capture source still rebuilds recognizers with the exact
        // newly persisted settings.
        capture.stop()
        captureRefreshScheduled = false
        captureRecoveryAttempt = 0
        previewLatencyTracker.reset()
        captureOwnership.reset()
        resetPresentationState()
        resetContinuousPinchState()
        invalidateAsyncWork()
        endPreview()

        coordinator.updateSettings(self.settings)
        let permissionReady = permissions.accessibilityTrusted && permissions.inputMonitoringTrusted
        // Device presence is recoverable (hot-plug / wake). Only framework
        // capability gates arming the capture source.
        let captureReady = permissions.privateMultitouch.frameworkAvailable &&
            permissions.privateMultitouch.requiredSymbolsAvailable
        coordinator.start(permissionReady: permissionReady, captureReady: captureReady)
        updateDebug("startup permissions=\(permissionReady ? "ready" : "missing") capturePrereq=\(captureReady ? "available" : "unavailable")")
        publishStatus()

        guard self.settings.gesturesEnabled, !self.settings.isPaused, permissionReady, captureReady else {
            updateDebug("capture stopped: gestures=\(self.settings.gesturesEnabled) paused=\(self.settings.isPaused) permissions=\(permissionReady) prereq=\(captureReady)")
            return
        }

        switch capture.start(handler: { [weak self] event in
            self?.handle(event)
        }) {
        case .running(let diagnostics):
            handleCaptureRunning(diagnostics, context: "capture running")
        case .failed(let diagnostics):
            onCaptureDiagnostics(diagnostics)
            invalidatePendingGesture(.captureFailed, at: clock.nowMilliseconds)
            coordinator.listenerFailed()
            updateDebug("capture failed: \(diagnostics.reason)")
            publishStatus()
            if diagnostics.frameworkAvailable, diagnostics.requiredSymbolsAvailable {
                scheduleCaptureRecoveryIfNeeded()
            }
        case .stopped:
            updateDebug("capture stopped")
            publishStatus()
        }
    }

    public func captureDevicesDidChange() {
        captureRecoveryAttempt = 0
        scheduleCaptureDeviceRefresh(reason: "device change")
    }

    public func shutdown() {
        scheduler.cancelAll()
        captureRefreshScheduled = false
        captureRecoveryAttempt = 0
        previewLatencyTracker.reset()
        captureOwnership.reset()
        invalidatePendingGesture(.paused, at: clock.nowMilliseconds)
        coordinator.stop()
        capture.stop()
        invalidateAsyncWork()
        endPreview()
        updateDebug("shutdown")
        publishStatus()
    }

    public func suspendForSystemSleep() {
        scheduler.cancelAll()
        captureRefreshScheduled = false
        captureRecoveryAttempt = 0
        previewLatencyTracker.reset()
        captureOwnership.reset()
        invalidatePendingGesture(.gestureCancelled, at: clock.nowMilliseconds)
        capture.stop()
        invalidateAsyncWork()
        endPreview()
        updateDebug("capture stopped: system sleep")
        publishStatus()
    }

    private func handleCaptureRunning(
        _ diagnostics: PrivateCaptureDiagnostics,
        context: String,
        forceDebug: Bool = true
    ) {
        let deviceCountsChanged = diagnostics.deviceCount != lastCaptureDeviceCount ||
            diagnostics.startedDeviceCount != lastStartedCaptureDeviceCount
        lastCaptureDeviceCount = diagnostics.deviceCount
        lastStartedCaptureDeviceCount = diagnostics.startedDeviceCount
        let startedSummary = diagnostics.startedDeviceCount > 0
            ? "\(diagnostics.startedDeviceCount)/\(max(diagnostics.deviceCount, diagnostics.startedDeviceCount))"
            : "\(diagnostics.started)"
        onCaptureDiagnostics(diagnostics)
        if forceDebug || deviceCountsChanged || diagnostics.failedDeviceCount > 0 {
            updateDebug("\(context): devices=\(diagnostics.deviceCount) started=\(startedSummary)")
            publishStatus()
        }
        coordinator.listenerRecovered()
        if diagnostics.failedDeviceCount == 0, diagnostics.startedDeviceCount > 0 {
            captureRecoveryAttempt = 0
        } else if context.hasPrefix("capture refresh") {
            scheduleCaptureRecoveryIfNeeded()
        }
    }

    private func scheduleCaptureRecoveryIfNeeded() {
        guard lastStartedCaptureDeviceCount == 0 || lastStartedCaptureDeviceCount < lastCaptureDeviceCount else {
            captureRecoveryAttempt = 0
            return
        }
        guard captureRecoveryAttempt < maximumCaptureRecoveryAttempts else {
            updateDebug("capture recovery waiting for device change: devices=\(lastCaptureDeviceCount) started=\(lastStartedCaptureDeviceCount)")
            publishStatus()
            return
        }
        captureRecoveryAttempt += 1
        scheduleCaptureDeviceRefresh(
            reason: "device recovery \(captureRecoveryAttempt)/\(maximumCaptureRecoveryAttempts)",
            delayMilliseconds: captureRecoveryRetryMilliseconds
        )
    }

    private func scheduleCaptureDeviceRefresh(reason: String, delayMilliseconds: Int? = nil) {
        guard settings.gesturesEnabled, !settings.isPaused, !captureRefreshScheduled else {
            return
        }
        captureRefreshScheduled = true
        scheduler.schedule(
            .captureRefresh,
            afterMilliseconds: delayMilliseconds ?? captureDeviceChangeDebounceMilliseconds
        ) { [weak self] in
            guard let self, self.settings.gesturesEnabled, !self.settings.isPaused else {
                return
            }
            self.captureRefreshScheduled = false
            switch self.capture.refreshDevices() {
            case .running(let refreshed):
                self.handleCaptureRunning(refreshed, context: "capture refresh: \(reason)", forceDebug: false)
            case .failed(let refreshed):
                self.onCaptureDiagnostics(refreshed)
                self.invalidatePendingGesture(.captureFailed, at: self.clock.nowMilliseconds)
                self.coordinator.listenerFailed()
                self.updateDebug("capture refresh failed after \(reason): \(refreshed.reason)")
                self.publishStatus()
            case .stopped:
                self.updateDebug("capture refresh after \(reason): stopped")
                self.publishStatus()
            }
        }
    }

    // ── FIFO Event Handling ──────────────────────────────────────────

    private func handle(_ event: CapturedGestureEvent) {
        capturedEventCount += 1
        if event.source.isSpecified, event.source.generation != capture.currentGeneration {
            updateDebug("ignored stale capture event from \(event.source.deviceID)")
            publishStatus()
            return
        }
        guard captureOwnership.shouldAccept(event) else {
            updateDebug("ignored competing capture event from \(event.source.deviceID)")
            publishStatus()
            return
        }

        // If an async target lookup is in flight, enqueue and preserve FIFO order.
        if pendingTargetLookup {
            mailbox.append(event)
            return
        }

        processEvent(event)
    }

    /// Processes a single event synchronously (or kicks off an async lookup).
    private func processEvent(_ event: CapturedGestureEvent) {
        if legacyTargetResolver == nil,
           coordinator.resolverSnapshot.lifecycle != .active,
           !pendingTargetLookup {
            switch event {
            case .changed(let progress):
                if case .pinch = progress.kind {
                    beginResolverSession(
                        pointer: progress.pointer,
                        modifiers: progress.modifiers,
                        timestampMilliseconds: progress.timestampMilliseconds,
                        debugPrefix: "late pinch progress begin"
                    )
                    mailbox.insert(event, at: 0)
                    return
                }
            case .strokeEnded(let stroke):
                beginResolverSession(
                    pointer: stroke.pointer,
                    modifiers: stroke.modifiers,
                    timestampMilliseconds: stroke.timestampMilliseconds,
                    debugPrefix: "late stroke begin"
                )
                mailbox.insert(event, at: 0)
                return
            case .pinchEnded(let pinch):
                beginResolverSession(
                    pointer: pinch.pointer,
                    modifiers: pinch.modifiers,
                    timestampMilliseconds: pinch.timestampMilliseconds,
                    debugPrefix: "late pinch begin",
                    fallingBackToFrontmost: pinch.direction == .outward
                )
                mailbox.insert(event, at: 0)
                return
            default:
                break
            }
        }

        switch event {
        case .began(let start):
            beginCapturedGesture(start)
        case .movement(let timestampMilliseconds):
            handleMovement(at: timestampMilliseconds)
        case .deviceMovement(let movement):
            handleMovement(at: movement.timestampMilliseconds)
        case .changed(let progress):
            handleProgress(progress)
        case .strokeEnded(let stroke):
            resetContinuousPinchState()
            handleStrokeEnded(stroke, sourceEvent: event)
        case .pinchEnded(let pinch):
            handlePinchEnded(pinch, sourceEvent: event)
        case .tapEnded(let tap):
            resetContinuousPinchState()
            handleTapEnded(tap, sourceEvent: event)
        case .ended(let timestampMilliseconds):
            handleEnded(at: timestampMilliseconds, sourceEvent: event)
            resetContinuousPinchState()
        case .deviceEnded(let end):
            handleEnded(at: end.timestampMilliseconds, sourceEvent: event)
            resetContinuousPinchState()
        case .cancelled(let reason, let timestampMilliseconds):
            handleCancelled(reason, at: timestampMilliseconds, sourceEvent: event)
            resetContinuousPinchState()
        case .deviceCancelled(let cancellation):
            handleCancelled(cancellation.reason, at: cancellation.timestampMilliseconds, sourceEvent: event)
            resetContinuousPinchState()
        }
        publishStatus()
    }

    /// Drains all events queued during an async lookup.
    private func drainMailbox() {
        pendingTargetLookup = false
        while !pendingTargetLookup, !mailbox.isEmpty {
            let event = mailbox.removeFirst()
            processEvent(event)
        }
    }

    private func invalidateAsyncWork() {
        sessionRevision &+= 1
        invalidatePreviewRequest()
        pendingTargetLookup = false
        mailbox.removeAll()
    }

    // ── Gesture Begin ────────────────────────────────────────────────

    private func beginCapturedGesture(_ start: CapturedGestureStart) {
        cancelGestureDeadlines()
        suppressActiveGestureUntilRelease = false
        resetContinuousPinchState()
        guard coordinator.resolverSnapshot.lifecycle != .active else {
            updateDebug("begin ignored during active chain")
            return
        }
        endPreview()
        beginResolverSession(
            pointer: start.pointer,
            modifiers: start.modifiers,
            timestampMilliseconds: start.timestampMilliseconds,
            debugPrefix: "begin"
        )
    }

    private func handleMovement(at timestampMilliseconds: Int) {
        guard !suppressActiveGestureUntilRelease else { return }
        guard !cancelForTopologyChangeIfNeeded(at: timestampMilliseconds) else { return }
        if coordinator.resolverSnapshot.committableIntent == nil {
            scheduleInactivityTimeout(at: timestampMilliseconds)
        }
    }

    private func handleProgress(_ progress: CapturedGestureProgress) {
        guard !suppressActiveGestureUntilRelease else { return }
        guard !cancelForTopologyChangeIfNeeded(at: progress.timestampMilliseconds) else { return }
        if case .pinch = progress.kind, coordinator.resolverSnapshot.lifecycle != .active {
            beginResolverSession(
                pointer: progress.pointer,
                modifiers: progress.modifiers,
                timestampMilliseconds: progress.timestampMilliseconds,
                debugPrefix: "late pinch progress begin",
                fallingBackToFrontmost: false
            )
        }
        updatePendingPinch(from: progress)
        presentLivePreview(for: progress)
        scheduleDesktopSpacePreviewTransition(for: progress)
    }

    private func handleStrokeEnded(_ stroke: CapturedGestureStroke, sourceEvent event: CapturedGestureEvent) {
        scheduler.cancel(.desktopSpacePreviewThreshold)
        guard !suppressActiveGestureUntilRelease else {
            suppressActiveGestureUntilRelease = false
            updateDebug("stroke \(stroke.direction.rawValue): ignored after inactivity timeout")
            captureOwnership.releaseOwner(for: event)
            return
        }
        pendingRestoreTap = nil
        guard !cancelForTopologyChangeIfNeeded(at: stroke.timestampMilliseconds) else { return }
        if coordinator.resolverSnapshot.lifecycle != .active {
            beginResolverSession(
                pointer: stroke.pointer,
                modifiers: stroke.modifiers,
                timestampMilliseconds: stroke.timestampMilliseconds,
                debugPrefix: "late stroke begin"
            )
        }
        if coordinator.resolverSnapshot.modifierMode != .unmodified {
            endPreview()
        }
        let result = route(.strokeEnded(GestureStroke(
            direction: stroke.direction,
            timestampMilliseconds: stroke.timestampMilliseconds,
            eventID: stroke.eventID,
            modifiers: stroke.modifiers
        )), actionID: stroke.eventID)
        switch result.resolverOutput.kind {
        case .preview:
            scheduleChainTimeout(after: stroke)
            presentResolvedPreview(from: result.resolverOutput, pointer: stroke.pointer, recognizedAt: stroke.timestampMilliseconds)
            updateDebug("stroke \(stroke.direction.rawValue): preview \(result.resolverOutput.intent?.command.displayName ?? "unknown")")
        case .commit, .cancel, .passThrough:
            finishActiveSequence(sourceEvent: event)
            updateDebug("stroke \(stroke.direction.rawValue): \(result.resolverOutput.kind.rawValue)\(result.commandResult.debugSuffix)")
        case .none:
            updateDebug("stroke \(stroke.direction.rawValue): ignored")
        }
    }

    private func handlePinchEnded(_ pinch: CapturedGesturePinch, sourceEvent event: CapturedGestureEvent) {
        cancelGestureDeadlines()
        pendingPinchGesture = nil
        if suppressActiveGestureUntilRelease {
            suppressActiveGestureUntilRelease = false
            updateDebug("pinch \(pinch.direction.rawValue): ignored after inactivity timeout")
            captureOwnership.releaseOwner(for: event)
            return
        }
        pendingRestoreTap = nil
        guard !cancelForTopologyChangeIfNeeded(at: pinch.timestampMilliseconds) else { return }
        let capturedInwardSegmentCount = pinch.direction == .inward ? max(1, pinch.inwardSegmentCount) : 0
        let nextInwardPinchCount = pinch.direction == .inward ? continuousInwardPinchCount + capturedInwardSegmentCount : 0
        if nextInwardPinchCount >= 2, let quitTarget = lastInwardPinchTarget {
            continuousInwardPinchCount = nextInwardPinchCount
            endPreview()
            let result = dispatch(.quit, to: quitTarget, actionID: pinch.eventID)
            finishActiveSequence(sourceEvent: event)
            updateDebug("pinch \(pinch.direction.rawValue): \(result.resolverOutput.kind.rawValue) \(result.resolverOutput.intent?.command.displayName ?? "")\(result.commandResult.debugSuffix)")
            return
        }
        if coordinator.resolverSnapshot.lifecycle != .active {
            beginResolverSession(
                pointer: pinch.pointer,
                modifiers: pinch.modifiers,
                timestampMilliseconds: pinch.timestampMilliseconds,
                debugPrefix: "late pinch begin",
                fallingBackToFrontmost: pinch.direction == .outward
            )
        }
        endPreview()
        let result = route(.pinchEnded(GesturePinch(
            direction: pinch.direction,
            inwardSegmentCount: capturedInwardSegmentCount,
            timestampMilliseconds: pinch.timestampMilliseconds,
            eventID: pinch.eventID,
            isCancelled: pinch.isCancelled,
            modifiers: pinch.modifiers
        )), actionID: pinch.eventID)
        if pinch.direction == .inward,
           result.resolverOutput.kind == .commit,
           result.resolverOutput.intent?.command == .close,
           let target = result.resolverOutput.intent?.target {
            continuousInwardPinchCount = nextInwardPinchCount
            lastInwardPinchTarget = target
        } else {
            resetContinuousPinchState()
        }
        finishActiveSequence(sourceEvent: event, resetContinuousPinch: false)
        updateDebug("pinch \(pinch.direction.rawValue): \(result.resolverOutput.kind.rawValue) \(result.resolverOutput.intent?.command.displayName ?? "")\(result.commandResult.debugSuffix)")
    }

    private func handleTapEnded(_ tap: CapturedGestureTap, sourceEvent event: CapturedGestureEvent) {
        scheduler.cancel(.inactivityTimeout)
        if suppressActiveGestureUntilRelease {
            suppressActiveGestureUntilRelease = false
            updateDebug("tap ignored after inactivity timeout")
            captureOwnership.releaseOwner(for: event)
            return
        }
        handleRestoreTap(tap)
        captureOwnership.releaseOwner(for: event)
    }

    private func handleEnded(at timestampMilliseconds: Int, sourceEvent event: CapturedGestureEvent) {
        cancelGestureDeadlines()
        pendingPinchGesture = nil
        if suppressActiveGestureUntilRelease {
            suppressActiveGestureUntilRelease = false
            updateDebug("ended ignored after inactivity timeout")
            captureOwnership.releaseOwner(for: event)
            return
        }
        guard !cancelForTopologyChangeIfNeeded(at: timestampMilliseconds) else { return }
        endPreview()
        let result = route(.release(timestampMilliseconds: timestampMilliseconds), actionID: "release-\(timestampMilliseconds)")
        captureOwnership.releaseOwner(for: event)
        if result.resolverOutput.kind.isTerminal {
            finishActiveSequence()
        }
        updateDebug("release: \(result.resolverOutput.kind.rawValue) \(result.resolverOutput.intent?.command.displayName ?? "")\(result.commandResult.debugSuffix)")
    }

    private func handleCancelled(_ reason: GestureCancelReason, at timestampMilliseconds: Int, sourceEvent event: CapturedGestureEvent) {
        captureOwnership.releaseOwner(for: event)
        invalidatePendingGesture(reason, at: timestampMilliseconds)
        updateDebug("cancelled: \(reason.rawValue)")
    }

    // ── Target Resolution (async via actor or sync via legacy) ────────

    private func beginResolverSession(
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        debugPrefix: String,
        fallingBackToFrontmost: Bool = false
    ) {
        // If we have a legacy synchronous resolver (used by existing tests),
        // resolve synchronously as before.
        if let legacyTargetResolver {
            let targetResult = legacyTargetResolver.targetUnderPointer(
                at: pointer,
                fallingBackToFrontmost: fallingBackToFrontmost
            )
            let target = try? targetResult.get().identity
            if target == nil {
                titlebarRejectCount += 1
                updateDebug("\(debugPrefix) rejected: \(targetResult.failureDescription)")
            }
            completeResolverSession(
                target: target,
                modifiers: modifiers,
                timestampMilliseconds: timestampMilliseconds,
                debugPrefix: debugPrefix
            )
            return
        }

        // Async path: resolve through the WindowAutomationService actor.
        sessionRevision &+= 1
        let capturedRevision = sessionRevision
        pendingTargetLookup = true

        Task { @MainActor [weak self, gestureTargetResolver] in
            let targetResult = await gestureTargetResolver.resolveTarget(
                at: pointer,
                fallingBackToFrontmost: fallingBackToFrontmost
            )
            guard let self else { return }

            // Stale completion: a newer session has started.
            guard capturedRevision == self.sessionRevision else {
                return
            }

            self.pendingTargetLookup = false

            let target = try? targetResult.get().identity
            if target == nil {
                self.titlebarRejectCount += 1
                self.updateDebug("\(debugPrefix) rejected: \(targetResult.failureDescription)")
            }

            self.completeResolverSession(
                target: target,
                modifiers: modifiers,
                timestampMilliseconds: timestampMilliseconds,
                debugPrefix: debugPrefix
            )

            // Drain any events that queued while we were waiting.
            self.drainMailbox()
        }
    }

    private func completeResolverSession(
        target: WindowTargetIdentity?,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        debugPrefix: String
    ) {
        let result = route(.begin(GestureSessionStart(
            target: target,
            modifiers: modifiers,
            timestampMilliseconds: timestampMilliseconds,
            topologyToken: topologyTokenProvider()
        )), actionID: nil)
        if coordinator.resolverSnapshot.lifecycle == .active {
            lastPresentedPreviewLabel = nil
            scheduleInactivityTimeout(at: timestampMilliseconds)
            updateDebug("\(debugPrefix) accepted: modifiers=\(modifiers.debugNames)")
        } else if result.resolverOutput.kind == .passThrough {
            suppressActiveGestureUntilRelease = true
            finishActiveSequence(clearSuppression: false)
        }
    }

    @discardableResult
    private func route(_ event: GestureResolverEvent, actionID: String?) -> GestureInputResult {
        let performsEffectsSynchronously = legacyTargetResolver != nil
        let result = coordinator.handle(
            event,
            actionID: actionID,
            performEffects: performsEffectsSynchronously
        )
        if let commandResult = result.commandResult {
            commandCommitCount += 1
            onCommandResult(commandResult)
            updateDebug(commandResult.debugSummary)
        } else if !performsEffectsSynchronously,
                  result.resolverOutput.kind == .commit,
                  let intent = result.resolverOutput.intent {
            dispatchEffect(intent.command, to: intent.target)
        }
        return result
    }

    @discardableResult
    private func dispatch(
        _ command: KeyboardCommand,
        to target: WindowTargetIdentity,
        actionID: String?
    ) -> GestureInputResult {
        let performsEffectsSynchronously = legacyTargetResolver != nil
        let result = coordinator.dispatch(
            command,
            to: target,
            actionID: actionID,
            performEffects: performsEffectsSynchronously
        )
        if let commandResult = result.commandResult {
            commandCommitCount += 1
            onCommandResult(commandResult)
            updateDebug(commandResult.debugSummary)
        } else if !performsEffectsSynchronously, result.resolverOutput.kind == .commit {
            dispatchEffect(command, to: target)
        }
        return result
    }

    private func dispatchEffect(_ command: KeyboardCommand, to target: WindowTargetIdentity) {
        let capturedRevision = sessionRevision
        let capturedGeneration = capture.currentGeneration
        commandCommitCount += 1
        Task { @MainActor [weak self, gestureTargetResolver] in
            let result = await gestureTargetResolver.dispatch(command, to: target)
            guard let self,
                  capturedRevision == self.sessionRevision,
                  capturedGeneration == self.capture.currentGeneration else {
                return
            }
            self.onCommandResult(result)
            self.updateDebug(result.debugSummary)
        }
    }

    private func cancelForTopologyChangeIfNeeded(at timestampMilliseconds: Int) -> Bool {
        let result = coordinator.cancelIfTopologyChanged(
            currentTopologyToken: topologyTokenProvider(),
            at: timestampMilliseconds
        )
        guard result.resolverOutput.kind == .cancel else { return false }
        finishActiveSequence(resetContinuousPinch: true)
        updateDebug("topology changed: cancelled preview")
        publishStatus()
        return true
    }

    private func invalidatePendingGesture(_ reason: GestureCancelReason, at timestampMilliseconds: Int) {
        _ = coordinator.cancel(reason, at: timestampMilliseconds)
        finishActiveSequence(resetContinuousPinch: true)
    }

    private func handleRestoreTap(_ tap: CapturedGestureTap) {
        scheduler.cancel(.chainTimeout)
        if coordinator.resolverSnapshot.lifecycle == .active {
            _ = coordinator.cancel(.gestureCancelled, at: tap.timestampMilliseconds)
            resetPresentationState(clearPendingTap: false)
            endPreview()
        }

        // Restore taps use the legacy synchronous resolver when available,
        // otherwise fall through to async.
        if let legacyTargetResolver {
            let targetResult = legacyTargetResolver.targetUnderPointer(at: tap.pointer)
            guard let target = try? targetResult.get().identity else {
                titlebarRejectCount += 1
                resetPresentationState()
                endPreview()
                updateDebug("tap rejected: \(targetResult.failureDescription)")
                return
            }
            completeRestoreTap(tap, target: target)
        } else {
            sessionRevision &+= 1
            let capturedRevision = sessionRevision
            pendingTargetLookup = true
            Task { @MainActor [weak self, gestureTargetResolver] in
                let targetResult = await gestureTargetResolver.resolveTarget(
                    at: tap.pointer,
                    fallingBackToFrontmost: false
                )
                guard let self, capturedRevision == self.sessionRevision else { return }
                self.pendingTargetLookup = false
                guard let target = try? targetResult.get().identity else {
                    self.titlebarRejectCount += 1
                    self.resetPresentationState()
                    self.endPreview()
                    self.updateDebug("tap rejected: \(targetResult.failureDescription)")
                    self.drainMailbox()
                    return
                }
                self.completeRestoreTap(tap, target: target)
                self.drainMailbox()
            }
        }
    }

    private func completeRestoreTap(_ tap: CapturedGestureTap, target: WindowTargetIdentity) {
        guard let previous = pendingRestoreTap,
              previous.target == target,
              previous.source == tap.source,
              previous.modifiers == tap.modifiers,
              tap.timestampMilliseconds - previous.timestampMilliseconds <= restoreDoubleTapWindowMilliseconds
        else {
            pendingRestoreTap = RestoreTapCandidate(
                source: tap.source,
                target: target,
                modifiers: tap.modifiers,
                timestampMilliseconds: tap.timestampMilliseconds
            )
            updateDebug("tap waiting second: modifiers=\(tap.modifiers.debugNames)")
            return
        }
        pendingRestoreTap = nil
        let command = settings.centerBehavior.keyboardCommand
        endPreview()
        let result = dispatch(command, to: target, actionID: tap.eventID)
        updateDebug("double tap restore: \(result.resolverOutput.kind.rawValue) \(command.displayName)")
    }

    private func presentLivePreview(for progress: CapturedGestureProgress) {
        let snapshot = coordinator.resolverSnapshot
        guard settings.previewsEnabled,
              settings.overlayPreviewSize != .off,
              snapshot.lifecycle == .active,
              snapshot.target != nil,
              let command = previewCommand(for: progress, snapshot: snapshot)
        else {
            if !settings.previewsEnabled || settings.overlayPreviewSize == .off {
                endPreview()
            }
            return
        }
        let label = command.displayName
        lastPresentedPreviewLabel = label
        presentPreview(command, pointer: progress.pointer, recognizedAt: progress.timestampMilliseconds)
        updateDebug("live preview: \(label)")
    }

    private func fullscreenState(for command: KeyboardCommand) -> Bool? {
        guard command == .toggleFullscreen, let target = coordinator.resolverSnapshot.target else { return nil }
        return coordinator.isFullscreen(target)
    }

    private func displayMovementPreview(for command: KeyboardCommand) -> DisplayMovementPreviewContext? {
        guard command.displayMoveDirection != nil, let target = coordinator.resolverSnapshot.target else { return nil }
        return coordinator.displayMovementPreview(for: command, target: target)
    }

    private func recordPreviewLatency(recognizedAt timestamp: Int) {
        _ = previewLatencyTracker.record(recognizedAt: timestamp, presentedAt: clock.nowMilliseconds)
    }

    private func updatePendingPinch(from progress: CapturedGestureProgress) {
        guard case .pinch(let direction) = progress.kind,
              coordinator.resolverSnapshot.modifierMode == .unmodified
        else {
            pendingPinchGesture = nil
            scheduler.cancel(.pinchTimeout)
            return
        }
        let previousInwardSegments = pendingPinchGesture?.inwardSegmentCount ?? 0
        let inwardSegmentCount = direction == .inward
            ? max(previousInwardSegments, progress.inwardSegmentCount, 1)
            : max(previousInwardSegments, progress.inwardSegmentCount)
        let pending = PendingPinchGesture(
            direction: inwardSegmentCount > 0 ? .inward : direction,
            inwardSegmentCount: inwardSegmentCount,
            pointer: progress.pointer,
            modifiers: progress.modifiers,
            timestampMilliseconds: progress.timestampMilliseconds
        )
        pendingPinchGesture = pending
        schedulePinchTimeout(for: pending)
    }

    private func previewCommand(for progress: CapturedGestureProgress, snapshot: GestureResolverSnapshot) -> KeyboardCommand? {
        switch progress.kind {
        case .stroke(let direction):
            let strokes = snapshot.modifierMode == .unmodified ? snapshot.strokes + [direction] : [direction]
            return GestureSequenceResolver.command(
                for: strokes,
                modifierMode: snapshot.modifierMode,
                startedAt: snapshot.startedAtMilliseconds,
                timestampMilliseconds: progress.timestampMilliseconds,
                configuration: GestureResolverConfiguration(settings: settings)
            )
        case .pinch(let direction):
            guard snapshot.modifierMode == .unmodified else { return nil }
            let inwardSegments = max(progress.inwardSegmentCount, pendingPinchGesture?.inwardSegmentCount ?? 0)
            if direction == .inward, continuousInwardPinchCount > 0 || inwardSegments >= 2 {
                return .quit
            }
            return direction == .inward ? .close : .toggleFullscreen
        }
    }

    private func schedulePinchTimeout(for pending: PendingPinchGesture) {
        let delay = min(settings.chainTimeoutMilliseconds, settings.gestureIdleTimeoutMilliseconds)
        let timeoutTimestamp = pending.timestampMilliseconds + delay
        scheduler.schedule(.pinchTimeout, afterMilliseconds: delay) { [weak self] in
            guard let self, self.pendingPinchGesture?.timestampMilliseconds == pending.timestampMilliseconds else { return }
            guard !self.cancelForTopologyChangeIfNeeded(at: timeoutTimestamp) else { return }
            _ = self.coordinator.cancel(.gestureCancelled, at: timeoutTimestamp)
            self.suppressActiveGestureUntilRelease = true
            self.finishActiveSequence(clearSuppression: false, resetContinuousPinch: true)
            self.updateDebug("pinch timeout: cancelled")
            self.publishStatus()
        }
    }

    private func hasReachedDesktopSpaceHoldThreshold(at timestampMilliseconds: Int, snapshot: GestureResolverSnapshot) -> Bool {
        guard let startedAt = snapshot.startedAtMilliseconds else { return false }
        return timestampMilliseconds - startedAt >= GestureResolverConfiguration(settings: settings).desktopSpaceMovementHoldMilliseconds
    }

    private func scheduleDesktopSpacePreviewTransition(for progress: CapturedGestureProgress) {
        let snapshot = coordinator.resolverSnapshot
        guard settings.previewsEnabled,
              settings.overlayPreviewSize != .off,
              snapshot.lifecycle == .active,
              snapshot.modifierMode == .unmodified,
              snapshot.strokes.isEmpty,
              let target = snapshot.target,
              let startedAt = snapshot.startedAtMilliseconds,
              case .stroke(let direction) = progress.kind,
              direction.isHorizontal
        else {
            scheduler.cancel(.desktopSpacePreviewThreshold)
            return
        }

        let thresholdTimestamp = startedAt + GestureResolverConfiguration(settings: settings).desktopSpaceMovementHoldMilliseconds
        let remaining = thresholdTimestamp - progress.timestampMilliseconds
        guard remaining > 0 else {
            scheduler.cancel(.desktopSpacePreviewThreshold)
            return
        }

        let capturedRevision = sessionRevision
        let capturedGeneration = capture.currentGeneration
        scheduler.schedule(.desktopSpacePreviewThreshold, afterMilliseconds: remaining) { [weak self] in
            guard let self,
                  capturedRevision == self.sessionRevision,
                  capturedGeneration == self.capture.currentGeneration
            else { return }
            let current = self.coordinator.resolverSnapshot
            guard current.lifecycle == .active,
                  current.target == target,
                  current.modifierMode == .unmodified,
                  current.strokes.isEmpty,
                  !self.cancelForTopologyChangeIfNeeded(at: thresholdTimestamp)
            else { return }

            var thresholdProgress = progress
            thresholdProgress.timestampMilliseconds = thresholdTimestamp
            self.presentLivePreview(for: thresholdProgress)
        }
    }

    private func presentResolvedPreview(from output: GestureResolverOutput, pointer: ScreenPoint, recognizedAt timestampMilliseconds: Int) {
        guard settings.previewsEnabled,
              settings.overlayPreviewSize != .off,
              let command = output.intent?.command
        else {
            endPreview()
            return
        }
        lastPresentedPreviewLabel = command.displayName
        presentPreview(command, pointer: pointer, recognizedAt: timestampMilliseconds)
    }

    private func presentPreview(
        _ command: KeyboardCommand,
        pointer: ScreenPoint,
        recognizedAt timestampMilliseconds: Int
    ) {
        guard let target = coordinator.resolverSnapshot.target else { return }
        invalidatePreviewRequest()
        let capturedPreviewRevision = previewRequestRevision

        if legacyTargetResolver != nil {
            onPreviewChanged(command, fullscreenState(for: command), displayMovementPreview(for: command), pointer)
            recordPreviewLatency(recognizedAt: timestampMilliseconds)
            return
        }

        // Present the semantic command immediately. Optional metadata may
        // enrich it later, but must never gate the base overlay.
        onPreviewChanged(command, nil, nil, pointer)
        recordPreviewLatency(recognizedAt: timestampMilliseconds)

        guard command == .toggleFullscreen || command.displayMoveDirection != nil else {
            return
        }

        let capturedRevision = sessionRevision
        let capturedGeneration = capture.currentGeneration
        Task { @MainActor [weak self, gestureTargetResolver] in
            let fullscreen = command == .toggleFullscreen
                ? await gestureTargetResolver.isFullscreen(target)
                : nil
            let movementPreview = command.displayMoveDirection != nil
                ? await gestureTargetResolver.displayMovementPreview(for: command, target: target)
                : nil
            guard let self,
                  capturedRevision == self.sessionRevision,
                  capturedPreviewRevision == self.previewRequestRevision,
                  capturedGeneration == self.capture.currentGeneration,
                  self.coordinator.resolverSnapshot.target == target,
                  self.settings.previewsEnabled,
                  self.settings.overlayPreviewSize != .off else {
                return
            }
            self.onPreviewChanged(command, fullscreen, movementPreview, pointer)
            self.recordPreviewLatency(recognizedAt: timestampMilliseconds)
        }
    }

    private func scheduleChainTimeout(after stroke: CapturedGestureStroke) {
        scheduler.cancel(.inactivityTimeout)
        let delay = settings.chainTimeoutMilliseconds
        let timeoutTimestamp = stroke.timestampMilliseconds + delay
        scheduler.schedule(.chainTimeout, afterMilliseconds: delay) { [weak self] in
            guard let self else { return }
            guard !self.cancelForTopologyChangeIfNeeded(at: timeoutTimestamp) else { return }
            let result = self.route(.timeout(timestampMilliseconds: timeoutTimestamp), actionID: "timeout-\(stroke.eventID)")
            if result.resolverOutput.kind.isTerminal {
                self.finishActiveSequence()
            }
            self.updateDebug("timeout: \(result.resolverOutput.kind.rawValue) \(result.resolverOutput.intent?.command.displayName ?? "")")
            self.publishStatus()
        }
    }

    private func scheduleInactivityTimeout(at timestampMilliseconds: Int) {
        guard coordinator.resolverSnapshot.committableIntent == nil else { return }
        let delay = settings.gestureIdleTimeoutMilliseconds
        let cancelTimestamp = timestampMilliseconds + delay
        scheduler.schedule(.inactivityTimeout, afterMilliseconds: delay) { [weak self] in
            guard let self,
                  self.coordinator.resolverSnapshot.lifecycle == .active,
                  self.coordinator.resolverSnapshot.committableIntent == nil
            else { return }
            _ = self.coordinator.cancel(.gestureCancelled, at: cancelTimestamp)
            self.suppressActiveGestureUntilRelease = true
            self.finishActiveSequence(clearSuppression: false)
            self.updateDebug("inactivity timeout after \(delay)ms")
            self.publishStatus()
        }
    }

    private func cancelGestureDeadlines() {
        scheduler.cancel(.chainTimeout)
        scheduler.cancel(.inactivityTimeout)
        scheduler.cancel(.pinchTimeout)
        scheduler.cancel(.desktopSpacePreviewThreshold)
    }

    private func finishActiveSequence(
        sourceEvent: CapturedGestureEvent? = nil,
        clearSuppression: Bool = true,
        resetContinuousPinch: Bool = false
    ) {
        cancelGestureDeadlines()
        if let sourceEvent {
            if sourceEvent.endsContactSequence {
                captureOwnership.releaseOwner(for: sourceEvent)
            } else {
                captureOwnership.drainOwnerUntilTerminal()
            }
        } else {
            captureOwnership.drainOwnerUntilTerminal()
        }
        resetPresentationState(clearSuppression: clearSuppression)
        if resetContinuousPinch { self.resetContinuousPinchState() }
        endPreview()
    }

    private func publishStatus() {
        onStatusChanged(coordinator.currentStatus, coordinator.currentFailureReason)
    }

    private func updateDebug(_ event: String) {
        lastDebugEvent = event
        let latency = previewLatencyTracker.summary
        let previewSummary = latency.p95Milliseconds.map { "previewP95=\($0)ms/\(latency.count)" } ?? "previewP95=none/0"
        let summary = "events=\(capturedEventCount), titlebarRejects=\(titlebarRejectCount), commands=\(commandCommitCount), \(previewSummary), last=\(lastDebugEvent)"
        onDebugChanged(summary)
        diagnosticsSink.write(summary)
    }

    private func resetPresentationState(clearPendingTap: Bool = true, clearSuppression: Bool = true) {
        invalidatePreviewRequest()
        pendingPinchGesture = nil
        if clearPendingTap { pendingRestoreTap = nil }
        if clearSuppression { suppressActiveGestureUntilRelease = false }
        lastPresentedPreviewLabel = nil
    }

    private func resetContinuousPinchState() {
        continuousInwardPinchCount = 0
        lastInwardPinchTarget = nil
    }
}

/// No-op placeholder used when the legacy `WindowTargetResolving` init is used.
@MainActor
private final class NoOpGestureTargetResolver: GestureTargetResolving, @unchecked Sendable {
    func resolveTarget(
        at point: ScreenPoint,
        fallingBackToFrontmost: Bool
    ) async -> Result<WindowTarget, WindowTargetFailure> {
        .failure(.noTarget)
    }
    func isFullscreen(_ target: WindowTargetIdentity) async -> Bool? { nil }
    func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) async -> DisplayMovementPreviewContext? { nil }
    func dispatch(
        _ command: KeyboardCommand,
        to target: WindowTargetIdentity
    ) async -> WindowCommandResult {
        WindowCommandResult(command: command, status: .unavailable, target: target)
    }
}

private struct RestoreTapCandidate {
    var source: CapturedGestureSource
    var target: WindowTargetIdentity
    var modifiers: Set<ModifierRole>
    var timestampMilliseconds: Int
}

private struct PendingPinchGesture: Equatable {
    var direction: GesturePinchDirection
    var inwardSegmentCount: Int
    var pointer: ScreenPoint
    var modifiers: Set<ModifierRole>
    var timestampMilliseconds: Int
}

private extension CenterBehavior {
    var keyboardCommand: KeyboardCommand {
        switch self {
        case .centerAndUnsnap: .centerAndUnsnap
        case .center: .center
        case .unsnap: .unsnap
        }
    }
}

private extension GestureDirection {
    var isHorizontal: Bool { self == .left || self == .right }
}

private extension GestureResolverOutputKind {
    var isTerminal: Bool {
        self == .commit || self == .cancel || self == .passThrough
    }
}

private extension Result where Success == WindowTarget, Failure == WindowTargetFailure {
    var failureDescription: String {
        switch self {
        case .success: "none"
        case .failure(let failure): "\(failure)"
        }
    }
}

private extension Set where Element == ModifierRole {
    var debugNames: String {
        isEmpty ? "none" : map(\.rawValue).sorted().joined(separator: "+")
    }
}

private extension WindowCommandResult {
    var debugSummary: String {
        if let reason, !reason.isEmpty {
            return "command result: \(command.displayName) \(status.rawValue) - \(reason)"
        }
        return "command result: \(command.displayName) \(status.rawValue)"
    }
}

private extension Optional where Wrapped == WindowCommandResult {
    var debugSuffix: String {
        guard let result = self else { return "" }
        return "; \(result.debugSummary)"
    }
}
