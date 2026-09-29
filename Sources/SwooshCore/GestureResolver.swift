import Foundation

public enum GestureDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum GesturePinchDirection: String, Codable, Equatable, Sendable {
    case inward
    case outward
}

public enum GestureModifierMode: String, Codable, Equatable, Sendable {
    case unmodified
    case general
    case screen
    case unsupported
}

public enum GestureCancelReason: String, Codable, Equatable, Sendable {
    case escape
    case gestureCancelled
    case invalidChain
    case overlongChain
    case permissionLost
    case targetLost
    case topologyChanged
    case paused
    case captureFailed
}

public enum GestureResolverOutputKind: String, Codable, Equatable, Sendable {
    case none
    case passThrough
    case preview
    case commit
    case cancel
}

public struct GestureCommandIntent: Equatable, Sendable {
    public var command: KeyboardCommand
    public var target: WindowTargetIdentity
    public var modifierMode: GestureModifierMode

    public init(command: KeyboardCommand, target: WindowTargetIdentity, modifierMode: GestureModifierMode) {
        self.command = command
        self.target = target
        self.modifierMode = modifierMode
    }
}

public struct GestureResolverOutput: Equatable, Sendable {
    public var kind: GestureResolverOutputKind
    public var intent: GestureCommandIntent?
    public var reason: GestureCancelReason?

    public init(
        kind: GestureResolverOutputKind,
        intent: GestureCommandIntent? = nil,
        reason: GestureCancelReason? = nil
    ) {
        self.kind = kind
        self.intent = intent
        self.reason = reason
    }

    public static var none: GestureResolverOutput {
        GestureResolverOutput(kind: .none)
    }

    public static var passThrough: GestureResolverOutput {
        GestureResolverOutput(kind: .passThrough)
    }
}

public struct GestureResolverConfiguration: Equatable, Sendable {
    public var chainTimeoutMilliseconds: Int
    public var generalModifier: ModifierRole
    public var screenModifier: ModifierRole

    public init(
        chainTimeoutMilliseconds: Int = SwooshSettings.defaultChainTimeoutMilliseconds,
        generalModifier: ModifierRole = .control,
        screenModifier: ModifierRole = .command
    ) {
        self.chainTimeoutMilliseconds = chainTimeoutMilliseconds.clamped(to: SwooshSettings.chainTimeoutRange)
        self.generalModifier = generalModifier
        self.screenModifier = screenModifier
    }

    public init(settings: SwooshSettings) {
        let normalized = settings.normalized
        self.init(
            chainTimeoutMilliseconds: normalized.chainTimeoutMilliseconds,
            generalModifier: normalized.generalModifier,
            screenModifier: normalized.screenModifier
        )
    }
}

public struct GestureSessionStart: Equatable, Sendable {
    public var target: WindowTargetIdentity?
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var topologyToken: String?

    public init(
        target: WindowTargetIdentity?,
        modifiers: Set<ModifierRole> = [],
        timestampMilliseconds: Int,
        topologyToken: String? = nil
    ) {
        self.target = target
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
        self.topologyToken = topologyToken
    }
}

public struct GestureStroke: Equatable, Sendable {
    public var direction: GestureDirection
    public var timestampMilliseconds: Int
    public var eventID: String?
    public var modifiers: Set<ModifierRole>

    public init(
        direction: GestureDirection,
        timestampMilliseconds: Int,
        eventID: String? = nil,
        modifiers: Set<ModifierRole> = []
    ) {
        self.direction = direction
        self.timestampMilliseconds = timestampMilliseconds
        self.eventID = eventID
        self.modifiers = modifiers
    }
}

public struct GesturePinch: Equatable, Sendable {
    public var direction: GesturePinchDirection
    public var timestampMilliseconds: Int
    public var eventID: String?
    public var isCancelled: Bool
    public var modifiers: Set<ModifierRole>

    public init(
        direction: GesturePinchDirection,
        timestampMilliseconds: Int,
        eventID: String? = nil,
        isCancelled: Bool = false,
        modifiers: Set<ModifierRole> = []
    ) {
        self.direction = direction
        self.timestampMilliseconds = timestampMilliseconds
        self.eventID = eventID
        self.isCancelled = isCancelled
        self.modifiers = modifiers
    }
}

public enum GestureResolverEvent: Equatable, Sendable {
    case begin(GestureSessionStart)
    case strokeEnded(GestureStroke)
    case pinchEnded(GesturePinch)
    case release(timestampMilliseconds: Int)
    case timeout(timestampMilliseconds: Int)
    case momentum(timestampMilliseconds: Int)
    case cancel(GestureCancelReason, timestampMilliseconds: Int)
}

public final class GestureSequenceResolver {
    private let configuration: GestureResolverConfiguration
    private var session: GestureSession?
    private var completed = false
    private var processedEventIDs: Set<String> = []

    public init(configuration: GestureResolverConfiguration = GestureResolverConfiguration()) {
        self.configuration = configuration
    }

    public convenience init(settings: SwooshSettings) {
        self.init(configuration: GestureResolverConfiguration(settings: settings))
    }

    public var activeTopologyToken: String? {
        session?.topologyToken
    }

    public func process(_ event: GestureResolverEvent) -> GestureResolverOutput {
        if completed, case .begin = event {
            reset()
        }

        guard !completed else {
            return .none
        }

        switch event {
        case .begin(let start):
            reset()
            guard let target = start.target else {
                completed = true
                return .passThrough
            }

            let modifierMode = mode(for: start.modifiers)
            guard modifierMode != .unsupported else {
                completed = true
                return .passThrough
            }

            session = GestureSession(
                target: target,
                modifierMode: modifierMode,
                startedAt: start.timestampMilliseconds,
                topologyToken: start.topologyToken
            )
            return .none

        case .strokeEnded(let stroke):
            guard markEvent(stroke.eventID), var active = session else {
                return .none
            }

            switch active.modifierMode {
            case .unmodified:
                active.strokes.append(stroke.direction)
                active.lastEndedAt = stroke.timestampMilliseconds
                session = active
                return previewOrCancel(for: active)
            case .general:
                guard let command = generalCommand(for: stroke.direction) else {
                    return finish(.passThrough)
                }
                return commit(command, target: active.target, modifierMode: active.modifierMode)
            case .screen:
                return commit(screenCommand(for: stroke.direction), target: active.target, modifierMode: active.modifierMode)
            case .unsupported:
                return finish(.passThrough)
            }

        case .pinchEnded(let pinch):
            guard markEvent(pinch.eventID), let active = session else {
                return .none
            }

            guard !pinch.isCancelled else {
                return cancel(.gestureCancelled)
            }

            guard active.modifierMode == .unmodified else {
                return finish(.passThrough)
            }

            let command: KeyboardCommand = pinch.direction == .inward ? .close : .toggleFullscreen
            return commit(command, target: active.target, modifierMode: active.modifierMode)

        case .release:
            guard let active = session,
                  active.modifierMode == .unmodified,
                  let command = command(for: active.strokes)
            else {
                return .none
            }

            return commit(command, target: active.target, modifierMode: active.modifierMode)

        case .timeout(let timestamp):
            guard let active = session,
                  active.modifierMode == .unmodified,
                  let lastEndedAt = active.lastEndedAt,
                  timestamp - lastEndedAt >= configuration.chainTimeoutMilliseconds,
                  let command = command(for: active.strokes)
            else {
                return .none
            }

            return commit(command, target: active.target, modifierMode: active.modifierMode)

        case .momentum:
            return .none

        case .cancel(let reason, _):
            guard session != nil else {
                return .none
            }
            return cancel(reason)
        }
    }

    public func reset() {
        session = nil
        completed = false
        processedEventIDs.removeAll()
    }

    public func cancelIfTopologyChanged(currentTopologyToken: String?, timestampMilliseconds: Int) -> GestureResolverOutput {
        guard let session, session.topologyToken != currentTopologyToken else {
            return .none
        }

        return process(.cancel(.topologyChanged, timestampMilliseconds: timestampMilliseconds))
    }

    private func previewOrCancel(for session: GestureSession) -> GestureResolverOutput {
        if session.strokes.count > 2 {
            return cancel(.overlongChain)
        }

        guard let command = command(for: session.strokes) else {
            return cancel(.invalidChain)
        }

        return GestureResolverOutput(
            kind: .preview,
            intent: GestureCommandIntent(
                command: command,
                target: session.target,
                modifierMode: session.modifierMode
            )
        )
    }

    private func command(for strokes: [GestureDirection]) -> KeyboardCommand? {
        switch strokes {
        case [.left]:
            .snapLeft
        case [.right]:
            .snapRight
        case [.up]:
            .maximize
        case [.down]:
            .minimize
        case [.up, .up]:
            .snapTop
        case [.down, .down]:
            .snapBottom
        case [.left, .up], [.up, .left]:
            .snapTopLeft
        case [.right, .up], [.up, .right]:
            .snapTopRight
        case [.left, .down], [.down, .left]:
            .snapBottomLeft
        case [.right, .down], [.down, .right]:
            .snapBottomRight
        default:
            nil
        }
    }

    private func generalCommand(for direction: GestureDirection) -> KeyboardCommand? {
        direction == .down ? .close : nil
    }

    private func screenCommand(for direction: GestureDirection) -> KeyboardCommand {
        switch direction {
        case .left:
            .moveDisplayLeft
        case .right:
            .moveDisplayRight
        case .up:
            .moveDisplayUp
        case .down:
            .moveDisplayDown
        }
    }

    private func mode(for modifiers: Set<ModifierRole>) -> GestureModifierMode {
        if modifiers.isEmpty {
            return .unmodified
        }

        if modifiers == [configuration.generalModifier] {
            return .general
        }

        if modifiers == [configuration.screenModifier] {
            return .screen
        }

        return .unsupported
    }

    private func commit(_ command: KeyboardCommand, target: WindowTargetIdentity, modifierMode: GestureModifierMode) -> GestureResolverOutput {
        finish(GestureResolverOutput(
            kind: .commit,
            intent: GestureCommandIntent(command: command, target: target, modifierMode: modifierMode)
        ))
    }

    private func cancel(_ reason: GestureCancelReason) -> GestureResolverOutput {
        finish(GestureResolverOutput(kind: .cancel, reason: reason))
    }

    private func finish(_ output: GestureResolverOutput) -> GestureResolverOutput {
        completed = true
        session = nil
        return output
    }

    private func markEvent(_ eventID: String?) -> Bool {
        guard let eventID else {
            return true
        }

        return processedEventIDs.insert(eventID).inserted
    }
}

private struct GestureSession {
    var target: WindowTargetIdentity
    var modifierMode: GestureModifierMode
    var startedAt: Int
    var topologyToken: String?
    var strokes: [GestureDirection] = []
    var lastEndedAt: Int?
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
