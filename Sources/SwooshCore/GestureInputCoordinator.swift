import Foundation

public enum GestureInputStatus: String, Codable, Equatable, Sendable {
    case stopped
    case running
    case paused
    case failed
}

public enum GestureInputFailureReason: String, Codable, Equatable, Sendable {
    case permissionDenied
    case captureUnavailable
    case listenerFailed
}

public struct GestureInputResult: Equatable, Sendable {
    public var resolverOutput: GestureResolverOutput
    public var commandResult: WindowCommandResult?

    public init(resolverOutput: GestureResolverOutput, commandResult: WindowCommandResult? = nil) {
        self.resolverOutput = resolverOutput
        self.commandResult = commandResult
    }
}

public final class GestureInputCoordinator {
    private let dispatcher: WindowCommandDispatching
    private var resolver: GestureSequenceResolver
    private var settings: SwooshSettings
    private var status: GestureInputStatus = .stopped
    private var failureReason: GestureInputFailureReason?
    private var lastActionID: String?

    public init(
        settings: SwooshSettings = .defaults,
        dispatcher: WindowCommandDispatching
    ) {
        let normalized = settings.normalized
        self.settings = normalized
        self.dispatcher = dispatcher
        resolver = GestureSequenceResolver(settings: normalized)
    }

    public var currentStatus: GestureInputStatus {
        status
    }

    public var currentFailureReason: GestureInputFailureReason? {
        failureReason
    }

    public func start(permissionReady: Bool, captureReady: Bool) {
        resolver.reset()
        lastActionID = nil
        guard permissionReady else {
            status = .failed
            failureReason = .permissionDenied
            return
        }

        guard captureReady else {
            status = .failed
            failureReason = .captureUnavailable
            return
        }

        status = settings.isPaused ? .paused : .running
        failureReason = nil
    }

    public func updateSettings(_ next: SwooshSettings) {
        settings = next.normalized
        resolver = GestureSequenceResolver(settings: settings)
        if settings.isPaused {
            pause()
        } else if status == .paused {
            status = .running
        }
    }

    public func stop() {
        resolver.reset()
        lastActionID = nil
        status = .stopped
        failureReason = nil
    }

    public func pause() {
        _ = cancel(.paused, at: 0)
        status = .paused
    }

    public func listenerFailed() {
        _ = cancel(.captureFailed, at: 0)
        status = .failed
        failureReason = .listenerFailed
    }

    public func cancel(_ reason: GestureCancelReason, at timestamp: Int) -> GestureInputResult {
        GestureInputResult(resolverOutput: resolver.process(.cancel(reason, timestampMilliseconds: timestamp)))
    }

    public func cancelIfTopologyChanged(currentTopologyToken: String?, at timestamp: Int) -> GestureInputResult {
        GestureInputResult(resolverOutput: resolver.cancelIfTopologyChanged(
            currentTopologyToken: currentTopologyToken,
            timestampMilliseconds: timestamp
        ))
    }

    public func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        (dispatcher as? WindowFullscreenStateProviding)?.isFullscreen(target)
    }

    public func displayMovementPreview(for command: KeyboardCommand, target: WindowTargetIdentity) -> DisplayMovementPreviewContext? {
        (dispatcher as? WindowDisplayMovementPreviewProviding)?.displayMovementPreview(for: command, target: target)
    }

    @discardableResult
    public func handle(_ event: GestureResolverEvent, actionID: String? = nil) -> GestureInputResult {
        guard status == .running, settings.gesturesEnabled else {
            return GestureInputResult(resolverOutput: .passThrough)
        }

        let output = resolver.process(event)
        guard output.kind == .commit, let intent = output.intent else {
            return GestureInputResult(resolverOutput: output)
        }

        if let actionID {
            guard actionID != lastActionID else {
                return GestureInputResult(resolverOutput: .none)
            }
            lastActionID = actionID
        }

        let commandResult = dispatcher.dispatch(intent.command, to: intent.target)
        return GestureInputResult(resolverOutput: output, commandResult: commandResult)
    }

    @discardableResult
    public func dispatch(
        _ command: KeyboardCommand,
        to target: WindowTargetIdentity,
        modifierMode: GestureModifierMode = .unmodified,
        actionID: String? = nil
    ) -> GestureInputResult {
        guard status == .running, settings.gesturesEnabled else {
            return GestureInputResult(resolverOutput: .passThrough)
        }

        if let actionID {
            guard actionID != lastActionID else {
                return GestureInputResult(resolverOutput: .none)
            }
            lastActionID = actionID
        }

        resolver.reset()
        let output = GestureResolverOutput(
            kind: .commit,
            intent: GestureCommandIntent(
                command: command,
                target: target,
                modifierMode: modifierMode
            )
        )
        let commandResult = dispatcher.dispatch(command, to: target)
        return GestureInputResult(resolverOutput: output, commandResult: commandResult)
    }
}
