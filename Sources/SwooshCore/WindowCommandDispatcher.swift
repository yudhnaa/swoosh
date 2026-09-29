import Foundation

public enum WindowCommandStatus: String, Codable, Equatable, Sendable {
    case performed
    case noOp
    case unavailable
    case targetFailure
    case geometryFailed
    case transitioning
}

public struct WindowCommandResult: Equatable, Sendable {
    public var command: KeyboardCommand
    public var status: WindowCommandStatus
    public var target: WindowTargetIdentity?
    public var requestedFrame: GeometryRect?
    public var appliedFrame: GeometryRect?
    public var reason: String?

    public init(
        command: KeyboardCommand,
        status: WindowCommandStatus,
        target: WindowTargetIdentity? = nil,
        requestedFrame: GeometryRect? = nil,
        appliedFrame: GeometryRect? = nil,
        reason: String? = nil
    ) {
        self.command = command
        self.status = status
        self.target = target
        self.requestedFrame = requestedFrame
        self.appliedFrame = appliedFrame
        self.reason = reason
    }
}

public protocol KeyboardTargetResolving {
    func frontmostKeyboardTarget() -> Result<WindowTarget, WindowTargetFailure>
}

extension WindowTargetResolver: KeyboardTargetResolving {}

public protocol WindowCommandDispatching {
    func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) -> WindowCommandResult
}

public final class KeyboardWindowCommandDispatcher {
    private let targetResolver: KeyboardTargetResolving
    private let frameController: WindowFrameControlling
    private let lifecycleController: WindowLifecycleController
    private let geometryEngine: SnapGeometryEngine
    private let history: WindowFrameHistory
    private let displayProvider: () -> DisplayGeometry?
    private let gridSpacingProvider: () -> Int

    public init(
        targetResolver: KeyboardTargetResolving,
        frameController: WindowFrameControlling,
        lifecycleController: WindowLifecycleController,
        history: WindowFrameHistory = WindowFrameHistory(),
        geometryEngine: SnapGeometryEngine = SnapGeometryEngine(),
        displayProvider: @escaping () -> DisplayGeometry?,
        gridSpacingProvider: @escaping () -> Int
    ) {
        self.targetResolver = targetResolver
        self.frameController = frameController
        self.lifecycleController = lifecycleController
        self.history = history
        self.geometryEngine = geometryEngine
        self.displayProvider = displayProvider
        self.gridSpacingProvider = gridSpacingProvider
    }

    public func dispatch(_ command: KeyboardCommand) -> WindowCommandResult {
        guard command.isMVPKeyboardCommand else {
            return WindowCommandResult(
                command: command,
                status: .unavailable,
                reason: "Physical display movement is deferred post-MVP."
            )
        }

        switch targetResolver.frontmostKeyboardTarget() {
        case .failure(let failure):
            return WindowCommandResult(command: command, status: .targetFailure, reason: "\(failure)")
        case .success(let target):
            return dispatch(command, to: target.identity)
        }
    }

    public func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) -> WindowCommandResult {
        if let transition = lifecycleController.guardGeometryCommand(for: target), command.isGeometryCommand {
            return WindowCommandResult(
                command: command,
                status: .transitioning,
                target: target,
                reason: transition.reason
            )
        }

        if let destination = command.snapDestination {
            return performSnap(destination, command: command, target: target)
        }

        if let action = command.centerRestoreAction {
            return performCenterRestore(action, command: command, target: target)
        }

        if let lifecycleAction = command.lifecycleAction {
            let result = lifecycleController.perform(lifecycleAction, for: target)
            return WindowCommandResult(
                command: command,
                status: result.windowCommandStatus,
                target: target,
                reason: result.reason
            )
        }

        return WindowCommandResult(command: command, status: .unavailable, target: target, reason: "No dispatcher mapping exists for command.")
    }

    private func performSnap(_ destination: SnapDestination, command: KeyboardCommand, target: WindowTargetIdentity) -> WindowCommandResult {
        guard let display = displayProvider() else {
            return WindowCommandResult(command: command, status: .unavailable, target: target, reason: "No active display is available.")
        }

        guard let originalFrame = frameController.frame(for: target) else {
            return WindowCommandResult(command: command, status: .geometryFailed, target: target, reason: "Could not read current target frame.")
        }

        let requested = geometryEngine.frame(for: destination, on: display, gridSpacing: gridSpacingProvider())
        guard frameController.setFrame(requested, for: target) else {
            return WindowCommandResult(command: command, status: .geometryFailed, target: target, requestedFrame: requested, reason: "Target rejected the requested frame.")
        }

        let applied = frameController.frame(for: target)
        let result = geometryEngine.evaluateAppliedFrame(requested: requested, applied: applied)
        history.recordSuccessfulSnap(target: target, originalFrame: originalFrame, result: result)

        return WindowCommandResult(
            command: command,
            status: result.status.windowCommandStatus,
            target: target,
            requestedFrame: requested,
            appliedFrame: applied,
            reason: result.reason
        )
    }

    private func performCenterRestore(_ action: CenterRestoreAction, command: KeyboardCommand, target: WindowTargetIdentity) -> WindowCommandResult {
        guard let display = displayProvider() else {
            return WindowCommandResult(command: command, status: .unavailable, target: target, reason: "No active display is available.")
        }

        guard let currentFrame = frameController.frame(for: target) else {
            return WindowCommandResult(command: command, status: .geometryFailed, target: target, reason: "Could not read current target frame.")
        }

        switch history.plan(action, target: target, currentFrame: currentFrame, reachableDisplay: display) {
        case .noOp:
            return WindowCommandResult(command: command, status: .noOp, target: target, reason: "No original frame is available.")
        case .planned(let requested):
            guard frameController.setFrame(requested, for: target) else {
                return WindowCommandResult(command: command, status: .geometryFailed, target: target, requestedFrame: requested, reason: "Target rejected the requested frame.")
            }

            let applied = frameController.frame(for: target)
            let result = geometryEngine.evaluateAppliedFrame(requested: requested, applied: applied)
            history.recordManagedFrame(target: target, result: result)
            return WindowCommandResult(
                command: command,
                status: result.status.windowCommandStatus,
                target: target,
                requestedFrame: requested,
                appliedFrame: applied,
                reason: result.reason
            )
        }
    }
}

extension KeyboardWindowCommandDispatcher: WindowCommandDispatching {}

public extension KeyboardCommand {
    var snapDestination: SnapDestination? {
        switch self {
        case .snapLeft:
            .leftHalf
        case .snapRight:
            .rightHalf
        case .snapTop:
            .topHalf
        case .snapBottom:
            .bottomHalf
        case .snapTopLeft:
            .topLeft
        case .snapTopRight:
            .topRight
        case .snapBottomLeft:
            .bottomLeft
        case .snapBottomRight:
            .bottomRight
        case .maximize:
            .maximize
        default:
            nil
        }
    }

    var centerRestoreAction: CenterRestoreAction? {
        switch self {
        case .center:
            .center
        case .unsnap:
            .unsnap
        case .centerAndUnsnap:
            .centerAndUnsnap
        default:
            nil
        }
    }

    var lifecycleAction: WindowLifecycleAction? {
        switch self {
        case .minimize:
            .minimize
        case .close:
            .requestClose
        case .toggleFullscreen:
            .toggleFullscreen
        default:
            nil
        }
    }

    var isGeometryCommand: Bool {
        snapDestination != nil || centerRestoreAction != nil || self == .moveDisplayLeft || self == .moveDisplayRight || self == .moveDisplayUp || self == .moveDisplayDown
    }
}

private extension GeometryApplyStatus {
    var windowCommandStatus: WindowCommandStatus {
        switch self {
        case .exact, .constrained:
            .performed
        case .unsupported:
            .geometryFailed
        }
    }
}

private extension WindowLifecycleResult {
    var windowCommandStatus: WindowCommandStatus {
        switch status {
        case .performed:
            .performed
        case .transitioning:
            .transitioning
        case .unsupported:
            .unavailable
        case .targetLost:
            .targetFailure
        case .rejected:
            .geometryFailed
        }
    }
}
