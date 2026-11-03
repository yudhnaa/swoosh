import Foundation

protocol WindowAutomationBackend: Sendable {
    func targetUnderPointer(
        at point: ScreenPoint,
        fallingBackToFrontmost fallbackToFrontmost: Bool
    ) -> Result<WindowTarget, WindowTargetFailure>
    func frontmostKeyboardTarget() -> Result<WindowTarget, WindowTargetFailure>
    func frame(for target: WindowTargetIdentity) -> GeometryRect?
    func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool
    func supportedLifecycleActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction>
    func performLifecycleAction(
        _ action: WindowLifecycleAction,
        for target: WindowTargetIdentity
    ) -> WindowLifecycleResult
    func finishFullscreenTransition(for target: WindowTargetIdentity)
    func isFullscreen(_ target: WindowTargetIdentity) -> Bool?
    func dispatch(_ command: KeyboardCommand) async -> WindowCommandResult
    func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) async -> WindowCommandResult
    func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) -> DisplayMovementPreviewContext?
}

private final class DefaultWindowAutomationBackend: WindowAutomationBackend, @unchecked Sendable {
    private let targetResolver: WindowTargetResolver
    private let frameController: WindowFrameControlling
    private let lifecycleController: WindowLifecycleController
    private let commandDispatcher: KeyboardWindowCommandDispatcher

    init(
        permissionState: PermissionStateService,
        displayProvider: @escaping @Sendable () -> DisplayGeometry?,
        displayListProvider: @escaping @Sendable () -> [DisplayGeometry],
        gridSpacingProvider: @escaping @Sendable () -> Int,
        desktopSpaceMover: (any DesktopSpaceMoving)? = nil
    ) {
        let resolver = WindowTargetResolver(
            permissions: permissionState,
            client: SystemAccessibilityTargetClient()
        )
        let frames = SystemWindowFrameController()
        let lifecycle = WindowLifecycleController(client: SystemAccessibilityLifecycleClient())

        targetResolver = resolver
        frameController = frames
        lifecycleController = lifecycle
        commandDispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: resolver,
            frameController: frames,
            lifecycleController: lifecycle,
            desktopSpaceMover: desktopSpaceMover ?? MissionControlDesktopSpaceMover(),
            displayProvider: displayProvider,
            displayListProvider: displayListProvider,
            gridSpacingProvider: gridSpacingProvider
        )
    }

    func targetUnderPointer(
        at point: ScreenPoint,
        fallingBackToFrontmost fallbackToFrontmost: Bool
    ) -> Result<WindowTarget, WindowTargetFailure> {
        targetResolver.targetUnderPointer(
            at: point,
            fallingBackToFrontmost: fallbackToFrontmost
        )
    }

    func frontmostKeyboardTarget() -> Result<WindowTarget, WindowTargetFailure> {
        targetResolver.frontmostKeyboardTarget()
    }

    func frame(for target: WindowTargetIdentity) -> GeometryRect? {
        frameController.frame(for: target)
    }

    func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool {
        frameController.setFrame(frame, for: target)
    }

    func supportedLifecycleActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction> {
        lifecycleController.supportedActions(for: target)
    }

    func performLifecycleAction(
        _ action: WindowLifecycleAction,
        for target: WindowTargetIdentity
    ) -> WindowLifecycleResult {
        lifecycleController.perform(action, for: target)
    }

    func finishFullscreenTransition(for target: WindowTargetIdentity) {
        lifecycleController.finishFullscreenTransition(for: target)
    }

    func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        lifecycleController.isFullscreen(target)
    }

    func dispatch(_ command: KeyboardCommand) async -> WindowCommandResult {
        await commandDispatcher.dispatch(command)
    }

    func dispatch(_ command: KeyboardCommand, to target: WindowTargetIdentity) async -> WindowCommandResult {
        await commandDispatcher.dispatch(command, to: target)
    }

    func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) -> DisplayMovementPreviewContext? {
        commandDispatcher.displayMovementPreview(for: command, target: target)
    }
}

/// Serializes all synchronous Accessibility work away from UI isolation.
/// Only Sendable value snapshots and results cross this actor boundary.
public actor WindowAutomationService {
    public typealias DisplayProvider = @Sendable () -> DisplayGeometry?
    public typealias DisplayListProvider = @Sendable () -> [DisplayGeometry]
    public typealias GridSpacingProvider = @Sendable () -> Int

    private let makeBackend: @Sendable () -> any WindowAutomationBackend
    private var storedBackend: (any WindowAutomationBackend)?
    private var automationTurnInFlight = false
    private var automationTurnWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        permissionState: PermissionStateService,
        displayProvider: @escaping DisplayProvider = { SystemDisplayProvider().mainDisplay() },
        displayListProvider: @escaping DisplayListProvider = { SystemDisplayProvider().displays() },
        gridSpacingProvider: @escaping GridSpacingProvider = { 0 }
    ) {
        makeBackend = {
            DefaultWindowAutomationBackend(
                permissionState: permissionState,
                displayProvider: displayProvider,
                displayListProvider: displayListProvider,
                gridSpacingProvider: gridSpacingProvider
            )
        }
    }

    init(backend: @escaping @Sendable () -> any WindowAutomationBackend) {
        makeBackend = backend
    }

    public func targetUnderPointer(
        at point: ScreenPoint,
        fallingBackToFrontmost fallbackToFrontmost: Bool = false
    ) async -> Result<WindowTarget, WindowTargetFailure> {
        await withAutomationTurn {
            backend.targetUnderPointer(
                at: point,
                fallingBackToFrontmost: fallbackToFrontmost
            )
        }
    }

    public func frontmostKeyboardTarget() async -> Result<WindowTarget, WindowTargetFailure> {
        await withAutomationTurn { backend.frontmostKeyboardTarget() }
    }

    public func frame(for target: WindowTargetIdentity) async -> GeometryRect? {
        await withAutomationTurn { backend.frame(for: target) }
    }

    @discardableResult
    public func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) async -> Bool {
        await withAutomationTurn { backend.setFrame(frame, for: target) }
    }

    public func supportedLifecycleActions(
        for target: WindowTargetIdentity
    ) async -> Set<WindowLifecycleAction> {
        await withAutomationTurn { backend.supportedLifecycleActions(for: target) }
    }

    public func performLifecycleAction(
        _ action: WindowLifecycleAction,
        for target: WindowTargetIdentity
    ) async -> WindowLifecycleResult {
        await withAutomationTurn { backend.performLifecycleAction(action, for: target) }
    }

    public func finishFullscreenTransition(for target: WindowTargetIdentity) async {
        await withAutomationTurn { backend.finishFullscreenTransition(for: target) }
    }

    public func isFullscreen(_ target: WindowTargetIdentity) async -> Bool? {
        await withAutomationTurn { backend.isFullscreen(target) }
    }

    public func dispatch(_ command: KeyboardCommand) async -> WindowCommandResult {
        await withAutomationTurn { await backend.dispatch(command) }
    }

    public func dispatch(
        _ command: KeyboardCommand,
        to target: WindowTargetIdentity
    ) async -> WindowCommandResult {
        await withAutomationTurn { await backend.dispatch(command, to: target) }
    }

    public func displayMovementPreview(
        for command: KeyboardCommand,
        target: WindowTargetIdentity
    ) async -> DisplayMovementPreviewContext? {
        await withAutomationTurn { backend.displayMovementPreview(for: command, target: target) }
    }

    private func withAutomationTurn<T: Sendable>(_ operation: () async -> T) async -> T {
        await acquireAutomationTurn()
        defer { releaseAutomationTurn() }
        return await operation()
    }

    private func acquireAutomationTurn() async {
        guard automationTurnInFlight else {
            automationTurnInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            automationTurnWaiters.append(continuation)
        }
    }

    private func releaseAutomationTurn() {
        guard !automationTurnWaiters.isEmpty else {
            automationTurnInFlight = false
            return
        }
        automationTurnWaiters.removeFirst().resume()
    }

    private var backend: any WindowAutomationBackend {
        if let storedBackend {
            return storedBackend
        }

        let backend = makeBackend()
        storedBackend = backend
        return backend
    }
}
