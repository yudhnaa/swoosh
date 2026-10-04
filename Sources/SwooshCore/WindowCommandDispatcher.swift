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

public protocol WindowFullscreenStateProviding {
    func isFullscreen(_ target: WindowTargetIdentity) -> Bool?
}

public struct DisplayMovementPreviewContext: Equatable, Sendable {
    public var displays: [DisplayGeometry]
    public var currentDisplayID: String?
    public var highlightedDisplayID: String?

    public init(
        displays: [DisplayGeometry],
        currentDisplayID: String?,
        highlightedDisplayID: String?
    ) {
        self.displays = displays
        self.currentDisplayID = currentDisplayID
        self.highlightedDisplayID = highlightedDisplayID
    }
}

public protocol WindowDisplayMovementPreviewProviding {
    func displayMovementPreview(for command: KeyboardCommand, target: WindowTargetIdentity) -> DisplayMovementPreviewContext?
}

public final class KeyboardWindowCommandDispatcher {
    private let targetResolver: KeyboardTargetResolving
    private let frameController: WindowFrameControlling
    private let lifecycleController: WindowLifecycleController
    private let desktopSpaceMover: DesktopSpaceMoving
    private let geometryEngine: SnapGeometryEngine
    private let history: WindowFrameHistory
    private let displayProvider: () -> DisplayGeometry?
    private let displayListProvider: () -> [DisplayGeometry]
    private let gridSpacingProvider: () -> Int

    public init(
        targetResolver: KeyboardTargetResolving,
        frameController: WindowFrameControlling,
        lifecycleController: WindowLifecycleController,
        desktopSpaceMover: DesktopSpaceMoving = MissionControlDesktopSpaceMover(),
        history: WindowFrameHistory = WindowFrameHistory(),
        geometryEngine: SnapGeometryEngine = SnapGeometryEngine(),
        displayProvider: @escaping () -> DisplayGeometry?,
        displayListProvider: @escaping () -> [DisplayGeometry] = { [] },
        gridSpacingProvider: @escaping () -> Int
    ) {
        self.targetResolver = targetResolver
        self.frameController = frameController
        self.lifecycleController = lifecycleController
        self.desktopSpaceMover = desktopSpaceMover
        self.history = history
        self.geometryEngine = geometryEngine
        self.displayProvider = displayProvider
        self.displayListProvider = displayListProvider
        self.gridSpacingProvider = gridSpacingProvider
    }

    public func dispatch(_ command: KeyboardCommand) -> WindowCommandResult {
        guard command.isMVPKeyboardCommand else {
            return WindowCommandResult(
                command: command,
                status: .unavailable,
                reason: "Command is not available in this build."
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

        if let direction = command.displayMoveDirection {
            return performDisplayMove(direction, command: command, target: target)
        }

        if let direction = command.desktopSpaceMoveDirection {
            return performDesktopSpaceMove(direction, command: command, target: target)
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

    public func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        lifecycleController.isFullscreen(target)
    }

    public func displayMovementPreview(for command: KeyboardCommand, target: WindowTargetIdentity) -> DisplayMovementPreviewContext? {
        guard let direction = command.displayMoveDirection else {
            return nil
        }

        let displays = activeDisplays()
        guard !displays.isEmpty,
              let currentFrame = frameController.frame(for: target)
        else {
            return nil
        }

        let planner = DisplayMovementPlanner(snapEngine: geometryEngine)
        let sourceDisplay = planner.display(containing: currentFrame, in: displays)
        let destinationDisplay = sourceDisplay.flatMap {
            planner.neighbor(from: $0, direction: direction, displays: displays)
        }

        return DisplayMovementPreviewContext(
            displays: displays.sorted { $0.id < $1.id },
            currentDisplayID: sourceDisplay?.id,
            highlightedDisplayID: destinationDisplay?.id ?? sourceDisplay?.id
        )
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
        guard let currentFrame = frameController.frame(for: target) else {
            return WindowCommandResult(command: command, status: .geometryFailed, target: target, reason: "Could not read current target frame.")
        }

        let displays = activeDisplays()
        guard !displays.isEmpty else {
            return WindowCommandResult(command: command, status: .unavailable, target: target, reason: "No active display is available.")
        }

        switch history.plan(action, target: target, currentFrame: currentFrame, displays: displays) {
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

    private func performDisplayMove(
        _ direction: DisplayMoveDirection,
        command: KeyboardCommand,
        target: WindowTargetIdentity
    ) -> WindowCommandResult {
        let displays = activeDisplays()

        guard !displays.isEmpty else {
            return WindowCommandResult(command: command, status: .unavailable, target: target, reason: "No active display is available.")
        }

        guard let currentFrame = frameController.frame(for: target) else {
            return WindowCommandResult(command: command, status: .geometryFailed, target: target, reason: "Could not read current target frame.")
        }

        let planner = DisplayMovementPlanner(snapEngine: geometryEngine)
        let placement = currentPlacement(for: currentFrame, displays: displays, gridSpacing: gridSpacingProvider())
        let plan = planner.planMove(
            frame: currentFrame,
            placement: placement,
            direction: direction,
            displays: displays,
            gridSpacing: gridSpacingProvider()
        )

        guard plan.status == .planned, let requested = plan.frame else {
            return WindowCommandResult(
                command: command,
                status: plan.status.windowCommandStatus,
                target: target,
                reason: plan.reason
            )
        }

        let staged = StagedWindowOperation(target: target, frame: requested, displays: displays)
        guard staged.validate(currentDisplays: activeDisplays()) == .planned else {
            return WindowCommandResult(
                command: command,
                status: .unavailable,
                target: target,
                requestedFrame: requested,
                reason: "Display topology changed before the move could be applied."
            )
        }

        guard frameController.setFrame(requested, for: target) else {
            return WindowCommandResult(
                command: command,
                status: .geometryFailed,
                target: target,
                requestedFrame: requested,
                reason: "Target rejected the requested frame."
            )
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

    private func performDesktopSpaceMove(
        _ direction: DesktopSpaceMoveDirection,
        command: KeyboardCommand,
        target: WindowTargetIdentity
    ) -> WindowCommandResult {
        guard let currentFrame = frameController.frame(for: target) else {
            return WindowCommandResult(command: command, status: .geometryFailed, target: target, reason: "Could not read current target frame.")
        }

        let displays = activeDisplays()
        guard let desktopTopY = displays.map(\.frame.maxY).max() else {
            return WindowCommandResult(command: command, status: .unavailable, target: target, reason: "No active display is available.")
        }

        let result = desktopSpaceMover.moveWindow(
            target: target,
            frame: currentFrame,
            direction: direction,
            desktopTopY: desktopTopY
        )

        return WindowCommandResult(
            command: command,
            status: result.status.windowCommandStatus,
            target: target,
            reason: result.reason
        )
    }

    private func activeDisplays() -> [DisplayGeometry] {
        let displays = displayListProvider()
        if !displays.isEmpty {
            return displays
        }

        if let display = displayProvider() {
            return [display]
        }

        return []
    }

    private func currentPlacement(
        for frame: GeometryRect,
        displays: [DisplayGeometry],
        gridSpacing: Int
    ) -> WindowLayoutPlacement {
        let planner = DisplayMovementPlanner(snapEngine: geometryEngine)
        guard let display = planner.display(containing: frame, in: displays) else {
            return .unsnapped
        }

        for destination in SnapDestination.allCases {
            let snappedFrame = geometryEngine.frame(for: destination, on: display, gridSpacing: gridSpacing)
            if frame.isWithin(SnapGeometryEngine.frameTolerance, of: snappedFrame) {
                return .snapped(destination)
            }
        }

        return .unsnapped
    }
}

extension KeyboardWindowCommandDispatcher: WindowCommandDispatching {}
extension KeyboardWindowCommandDispatcher: WindowFullscreenStateProviding {}
extension KeyboardWindowCommandDispatcher: WindowDisplayMovementPreviewProviding {}

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

    var displayMoveDirection: DisplayMoveDirection? {
        switch self {
        case .moveDisplayLeft:
            .left
        case .moveDisplayRight:
            .right
        case .moveDisplayUp:
            .up
        case .moveDisplayDown:
            .down
        default:
            nil
        }
    }

    var desktopSpaceMoveDirection: DesktopSpaceMoveDirection? {
        switch self {
        case .moveSpaceLeft:
            .left
        case .moveSpaceRight:
            .right
        case .moveSpaceUp:
            .up
        case .moveSpaceDown:
            .down
        default:
            nil
        }
    }

    var isGeometryCommand: Bool {
        snapDestination != nil || centerRestoreAction != nil || displayMoveDirection != nil || desktopSpaceMoveDirection != nil
    }
}

private extension DisplayMovementStatus {
    var windowCommandStatus: WindowCommandStatus {
        switch self {
        case .planned:
            .performed
        case .unavailable, .topologyChanged:
            .unavailable
        }
    }
}

private extension DesktopSpaceMovementStatus {
    var windowCommandStatus: WindowCommandStatus {
        switch self {
        case .performed:
            .performed
        case .unavailable:
            .unavailable
        case .failed:
            .geometryFailed
        }
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
