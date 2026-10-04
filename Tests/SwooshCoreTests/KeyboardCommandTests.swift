import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import SwooshCore

@Suite
struct KeyboardCommandTests {
    private let display = DisplayGeometry(
        id: "main",
        frame: GeometryRect(x: 0, y: 0, width: 1512, height: 982),
        usableFrame: GeometryRect(x: 0, y: 38, width: 1512, height: 944),
        scaleFactor: 2
    )
    private let externalDisplay = DisplayGeometry(
        id: "external",
        frame: GeometryRect(x: 1512, y: -120, width: 1920, height: 1080),
        usableFrame: GeometryRect(x: 1512, y: -80, width: 1920, height: 1040),
        scaleFactor: 1
    )

    @Test
    func defaultsLeaveShortcutsUnassigned() {
        #expect(SwooshSettings.defaults.keyboardBindings.isEmpty)
    }

    @Test
    func bindingValidatorRejectsDuplicateReservedAndMalformedCommands() {
        var settings = SwooshSettings.defaults
        settings.keyboardBindings = [
            .snapLeft: "Option + Command + Left",
            .snapRight: "Command + Option + Left",
            .close: "Command + Q",
            .center: "F13",
            .unsnap: "A",
            .moveDisplayLeft: "Control + Option + Left",
            .moveSpaceDown: "Control + Option + Down"
        ]

        let issues = KeyboardBindingValidator().issues(for: settings)

        #expect(issues.contains { $0.command == .snapRight && $0.reason == .duplicate })
        #expect(issues.contains { $0.command == .close && $0.reason == .reservedSystemShortcut })
        #expect(issues.contains { $0.command == .center && $0.reason == .unsupportedKey })
        #expect(issues.contains { $0.command == .unsnap && $0.reason == .missingModifier })
        #expect(issues.contains { $0.command == .moveSpaceDown && $0.reason == .unsupportedCommand })
        #expect(!issues.contains { $0.command == .moveDisplayLeft })
    }

    @Test
    func settingsStoreRejectsInvalidBindings() throws {
        let fixture = UserDefaultsFixture()
        defer { fixture.cleanup() }
        let store = UserDefaultsSettingsStore(defaults: fixture.defaults)
        var settings = SwooshSettings.defaults
        settings.keyboardBindings = [.close: "command+q"]

        do {
            try store.save(settings)
            Issue.record("Expected invalid binding error")
        } catch SettingsStoreError.invalidKeyboardBindings(let issues) {
            #expect(issues.count == 1)
            #expect(issues[0].reason == .reservedSystemShortcut)
        }
    }

    @Test
    func shortcutCoordinatorRegistersUpdatesClearsAndReleasesOnPause() {
        let registrar = MockShortcutRegistrar()
        let coordinator = KeyboardShortcutCoordinator(registrar: registrar)
        var settings = SwooshSettings.defaults
        settings.keyboardBindings = [.snapLeft: "control+left"]

        let first = coordinator.apply(settings)
        settings.keyboardBindings = [.snapLeft: "control+right"]
        let changed = coordinator.apply(settings)
        settings.keyboardBindings = [:]
        let cleared = coordinator.apply(settings)
        settings.keyboardBindings = [.snapLeft: "control+left"]
        _ = coordinator.apply(settings)
        settings.isPaused = true
        let paused = coordinator.apply(settings)

        #expect(first.map(\.status) == [.registered])
        #expect(changed.map(\.status) == [.released, .registered])
        #expect(cleared.map(\.status) == [.released])
        #expect(paused.map(\.status) == [.released])
    }

    @Test
    func shortcutCoordinatorSurfacesRegistrationFailure() {
        let registrar = MockShortcutRegistrar(failBindings: ["control+left"])
        let coordinator = KeyboardShortcutCoordinator(registrar: registrar)
        var settings = SwooshSettings.defaults
        settings.keyboardBindings = [.snapLeft: "control+left"]

        let records = coordinator.apply(settings)

        #expect(records.count == 1)
        #expect(records[0].status == .failed)
        #expect(records[0].reason == "mockFailure")
    }

    @Test
    func displayMovementShortcutRegistersThroughExistingCoordinator() {
        let registrar = MockShortcutRegistrar()
        let coordinator = KeyboardShortcutCoordinator(registrar: registrar)
        var settings = SwooshSettings.defaults
        settings.keyboardBindings = [.moveDisplayRight: "control+option+right"]

        let records = coordinator.apply(settings)

        #expect(records.count == 1)
        #expect(records[0].command == .moveDisplayRight)
        #expect(records[0].binding == "option+control+right")
        #expect(records[0].status == .registered)
    }

    @Test
    func dispatcherRunsAllSnapAndCenterRestoreCommands() throws {
        let target = targetIdentity()
        let resolver = MockKeyboardTargetResolver(target: target)
        let frames = MockWindowFrameController(initialFrames: [target: GeometryRect(x: 40, y: 80, width: 900, height: 600)])
        let lifecycle = WindowLifecycleController(client: MockLifecycleClient())
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: resolver,
            frameController: frames,
            lifecycleController: lifecycle,
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        let snapCommands: [KeyboardCommand] = [
            .snapLeft,
            .snapRight,
            .snapTop,
            .snapBottom,
            .snapTopLeft,
            .snapTopRight,
            .snapBottomLeft,
            .snapBottomRight,
            .maximize
        ]
        for command in snapCommands {
            #expect(dispatcher.dispatch(command).status == .performed)
        }

        let centered = dispatcher.dispatch(.center)
        let centerAndRestore = dispatcher.dispatch(.centerAndUnsnap)
        let restore = dispatcher.dispatch(.unsnap)

        #expect(centered.status == .performed)
        #expect(centerAndRestore.status == .performed)
        #expect(restore.status == .performed)
        #expect(frames.frames[target] == GeometryRect(x: 40, y: 80, width: 900, height: 600))
    }

    @Test
    func dispatcherRunsLifecycleAgainstFrontmostTarget() {
        let target = targetIdentity()
        let lifecycleClient = MockLifecycleClient(supported: [.minimize])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: MockWindowFrameController(initialFrames: [target: GeometryRect(x: 40, y: 80, width: 900, height: 600)]),
            lifecycleController: WindowLifecycleController(client: lifecycleClient),
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.minimize)

        #expect(result.status == .performed)
        #expect(lifecycleClient.performedActions == [.minimize])
    }

    @Test
    func dispatcherRejectsGeometryDuringFullscreenTransitionButAllowsLifecycle() {
        let target = targetIdentity()
        let lifecycleClient = MockLifecycleClient(supported: [.toggleFullscreen, .minimize])
        let lifecycle = WindowLifecycleController(client: lifecycleClient)
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: MockWindowFrameController(initialFrames: [target: GeometryRect(x: 40, y: 80, width: 900, height: 600)]),
            lifecycleController: lifecycle,
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        #expect(dispatcher.dispatch(.toggleFullscreen).status == .performed)
        #expect(dispatcher.dispatch(.snapLeft).status == .transitioning)
        #expect(dispatcher.dispatch(.minimize).status == .transitioning)
        lifecycle.finishFullscreenTransition(for: target)
        #expect(dispatcher.dispatch(.snapLeft).status == .performed)
    }

    @Test
    func dispatcherReturnsTargetFailureAndDisplayMoveUnavailable() {
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(failure: .noTarget),
            frameController: MockWindowFrameController(initialFrames: [:]),
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        #expect(dispatcher.dispatch(.snapLeft).status == .targetFailure)
        #expect(dispatcher.dispatch(.moveDisplayLeft).status == .targetFailure)
    }

    @Test
    func keyboardAndGestureDisplayCommandsShareDispatcherSemantics() {
        let target = targetIdentity()
        let frames = MockWindowFrameController(initialFrames: [target: GeometryRect(x: 120, y: 200, width: 640, height: 480)])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        let keyboardResult = dispatcher.dispatch(.moveDisplayRight)
        let gestureResult = dispatcher.dispatch(.moveDisplayRight, to: target)

        #expect(keyboardResult.status == .unavailable)
        #expect(gestureResult.status == .unavailable)
        #expect(keyboardResult.reason == gestureResult.reason)
    }

    @Test
    func dispatcherMovesSnappedWindowToAdjacentDisplayPreservingLayout() {
        let target = targetIdentity()
        let initialFrame = SnapGeometryEngine().frame(for: .leftHalf, on: display, gridSpacing: 0)
        let frames = MockWindowFrameController(initialFrames: [target: initialFrame])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display, externalDisplay] },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.moveDisplayRight, to: target)
        let expected = SnapGeometryEngine().frame(for: .leftHalf, on: externalDisplay, gridSpacing: 0)

        #expect(result.status == .performed)
        #expect(result.requestedFrame == expected)
        #expect(frames.frames[target] == expected)
    }

    @Test
    func dispatcherMovesUnsnappedWindowToAdjacentDisplayAndRetainsSizeWherePossible() {
        let target = targetIdentity()
        let initialFrame = GeometryRect(x: 120, y: 200, width: 640, height: 480)
        let frames = MockWindowFrameController(initialFrames: [target: initialFrame])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display, externalDisplay] },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.moveDisplayRight, to: target)

        #expect(result.status == .performed)
        #expect(result.requestedFrame?.width == initialFrame.width)
        #expect(result.requestedFrame?.height == initialFrame.height)
        #expect(result.requestedFrame?.x ?? 0 >= externalDisplay.usableFrame.x)
        #expect(result.requestedFrame?.maxX ?? 0 <= externalDisplay.usableFrame.maxX)
    }

    @Test
    func displayMovementPreviewReportsCurrentAndDirectionalDestinationDisplays() throws {
        let target = targetIdentity()
        let frames = MockWindowFrameController(initialFrames: [target: GeometryRect(x: 120, y: 200, width: 640, height: 480)])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display, externalDisplay] },
            gridSpacingProvider: { 0 }
        )

        let preview = try #require(dispatcher.displayMovementPreview(for: .moveDisplayRight, target: target))

        #expect(preview.displays.map(\.id) == ["external", "main"])
        #expect(preview.currentDisplayID == "main")
        #expect(preview.highlightedDisplayID == "external")
    }

    @Test
    func displayMovementPreviewFallsBackToCurrentDisplayWhenNoNeighborExists() throws {
        let target = targetIdentity()
        let frames = MockWindowFrameController(initialFrames: [target: GeometryRect(x: 120, y: 200, width: 640, height: 480)])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        let preview = try #require(dispatcher.displayMovementPreview(for: .moveDisplayRight, target: target))

        #expect(preview.displays.map(\.id) == ["main"])
        #expect(preview.currentDisplayID == "main")
        #expect(preview.highlightedDisplayID == "main")
    }

    @Test
    func dispatcherReportsUnavailableWhenNoAdjacentDisplayExists() {
        let target = targetIdentity()
        let frames = MockWindowFrameController(initialFrames: [target: GeometryRect(x: 120, y: 200, width: 640, height: 480)])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.moveDisplayRight, to: target)

        #expect(result.status == .unavailable)
        #expect(result.reason == "No active display is available in the requested direction.")
    }

    @Test
    func dispatcherReportsGeometryFailureWhenDisplayMoveWriteIsRejected() {
        let target = targetIdentity()
        let frames = MockWindowFrameController(
            initialFrames: [target: GeometryRect(x: 120, y: 200, width: 640, height: 480)],
            rejectedTargets: [target]
        )
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display, externalDisplay] },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.moveDisplayRight, to: target)

        #expect(result.status == .geometryFailed)
        #expect(result.reason == "Target rejected the requested frame.")
    }

    @Test
    func dispatcherMovesWindowBetweenDesktopSpacesThroughInjectedMover() {
        let target = targetIdentity()
        let frame = GeometryRect(x: 120, y: 200, width: 640, height: 480)
        let frames = MockWindowFrameController(initialFrames: [target: frame])
        let spaces = MockDesktopSpaceMover()
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            desktopSpaceMover: spaces,
            displayProvider: { display },
            displayListProvider: { [display, externalDisplay] },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.moveSpaceLeft, to: target)

        #expect(result.status == .performed)
        #expect(spaces.requests == [
            DesktopSpaceMoveRequest(
                target: target,
                frame: frame,
                direction: .left,
                desktopTopY: display.frame.maxY
            )
        ])
    }

    @Test
    func dispatcherReportsUnavailableForUnsupportedDesktopSpaceDirection() {
        let target = targetIdentity()
        let frame = GeometryRect(x: 120, y: 200, width: 640, height: 480)
        let frames = MockWindowFrameController(initialFrames: [target: frame])
        let spaces = MockDesktopSpaceMover(results: [.down: DesktopSpaceMovementResult(
            status: .unavailable,
            reason: "Desktop Spaces movement supports left and right directions only."
        )])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            desktopSpaceMover: spaces,
            displayProvider: { display },
            displayListProvider: { [display] },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.moveSpaceDown, to: target)

        #expect(result.status == .unavailable)
        #expect(result.reason == "Desktop Spaces movement supports left and right directions only.")
        #expect(spaces.requests.map(\.direction) == [.down])
    }

    @Test
    func missionControlSpaceMoverPlansGestureTargetControlArrowSequence() {
        let activator = MockDesktopSpaceTargetActivator()
        let mover = MissionControlDesktopSpaceMover(targetActivator: activator)
        let target = targetIdentity(id: "pointer-window")
        let frame = GeometryRect(x: 120, y: 200, width: 640, height: 480)

        let result = mover.moveWindow(
            target: target,
            frame: frame,
            direction: .right,
            desktopTopY: display.frame.maxY
        )

        #expect(result.status == .performed)
        #expect(result.reason == nil)
        #expect(activator.activatedTargets == [target])

        let left = mover.eventPlan(forAppKitFrame: frame, desktopTopY: display.frame.maxY, direction: .left)
        let right = mover.eventPlan(forAppKitFrame: frame, desktopTopY: display.frame.maxY, direction: .right)
        #expect(left.mouseDownPoint == CGPoint(x: 440, y: 312))
        #expect(right.mouseDownPoint == CGPoint(x: 440, y: 312))
        #expect(left.dragPoint == left.mouseDownPoint)
        #expect(right.dragPoint == right.mouseDownPoint)
        #expect(left.keyCode == CGKeyCode(kVK_LeftArrow))
        #expect(right.keyCode == CGKeyCode(kVK_RightArrow))
        #expect(left.controlKeyCode == CGKeyCode(kVK_Control))
        #expect(right.controlKeyCode == CGKeyCode(kVK_Control))
        #expect(left.eventSourceStateID == .hidSystemState)
        #expect(right.eventSourceStateID == .hidSystemState)
        #expect(left.eventTap == .cghidEventTap)
        #expect(right.eventTap == .cghidEventTap)
        #expect(left.controlEventFlags == .maskControl)
        #expect(right.controlEventFlags == .maskControl)
        #expect(left.arrowEventFlags == [.maskControl, .maskSecondaryFn, .maskNumericPad])
        #expect(right.arrowEventFlags == [.maskControl, .maskSecondaryFn, .maskNumericPad])
        #expect(left.mouseDownToDragDelaySeconds > 0)
        #expect(left.dragToKeyDelaySeconds > 0)
        #expect(left.controlToArrowDelaySeconds > 0)
        #expect(left.keyToMouseUpDelaySeconds >= 0.3)
    }

    @Test
    func missionControlSpaceMoverReportsUnavailableWhenTargetCannotActivate() {
        let activator = MockDesktopSpaceTargetActivator(result: .failed("mock activation failed"))
        let mover = MissionControlDesktopSpaceMover(targetActivator: activator)
        let target = targetIdentity(id: "pointer-window")

        let result = mover.moveWindow(
            target: target,
            frame: GeometryRect(x: 120, y: 200, width: 640, height: 480),
            direction: .right,
            desktopTopY: display.frame.maxY
        )

        #expect(result.status == .unavailable)
        #expect(result.reason == "mock activation failed")
        #expect(activator.activatedTargets == [target])
    }

    @Test
    func centerRestoreUsesCurrentWindowDisplayAfterManualCrossDisplayMove() {
        let target = targetIdentity()
        let originalOnExternal = GeometryRect(x: 1_800, y: 160, width: 640, height: 480)
        let manualOnMain = GeometryRect(x: 120, y: 180, width: 640, height: 480)
        let frames = MockWindowFrameController(initialFrames: [target: originalOnExternal])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { externalDisplay },
            displayListProvider: { [display, externalDisplay] },
            gridSpacingProvider: { 0 }
        )

        #expect(dispatcher.dispatch(.snapLeft, to: target).status == .performed)
        frames.frames[target] = manualOnMain

        let result = dispatcher.dispatch(.centerAndUnsnap, to: target)

        #expect(result.status == .performed)
        #expect(result.requestedFrame == manualOnMain.centered(in: display.usableFrame))
        #expect(frames.frames[target] == manualOnMain.centered(in: display.usableFrame))
    }

    @Test
    func dispatcherRejectsDisplayMoveWhenTopologyChangesBeforeCommit() {
        let target = targetIdentity()
        let frames = MockWindowFrameController(initialFrames: [target: GeometryRect(x: 120, y: 200, width: 640, height: 480)])
        var calls = 0
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: {
                calls += 1
                return calls == 1 ? [display, externalDisplay] : [display]
            },
            gridSpacingProvider: { 0 }
        )

        let result = dispatcher.dispatch(.moveDisplayRight, to: target)

        #expect(result.status == .unavailable)
        #expect(result.reason == "Display topology changed before the move could be applied.")
        #expect(frames.frames[target] == GeometryRect(x: 120, y: 200, width: 640, height: 480))
    }

    @Test
    func displayMoveAfterSnapPreservesOriginalFrameForRestore() {
        let target = targetIdentity()
        let original = GeometryRect(x: 120, y: 200, width: 640, height: 480)
        let frames = MockWindowFrameController(initialFrames: [target: original])
        let dispatcher = KeyboardWindowCommandDispatcher(
            targetResolver: MockKeyboardTargetResolver(target: target),
            frameController: frames,
            lifecycleController: WindowLifecycleController(client: MockLifecycleClient()),
            displayProvider: { display },
            displayListProvider: { [display, externalDisplay] },
            gridSpacingProvider: { 0 }
        )

        #expect(dispatcher.dispatch(.snapLeft, to: target).status == .performed)
        #expect(dispatcher.dispatch(.moveDisplayRight, to: target).status == .performed)
        #expect(dispatcher.dispatch(.unsnap, to: target).status == .performed)

        #expect(frames.frames[target] == original)
    }

    private func targetIdentity(id: String = "window") -> WindowTargetIdentity {
        WindowTargetIdentity(processIdentifier: 42, elementIdentifier: id)
    }
}

private final class MockShortcutRegistrar: KeyboardShortcutRegistering {
    var failBindings: Set<String>

    init(failBindings: Set<String> = []) {
        self.failBindings = failBindings
    }

    func register(_ binding: String, command: KeyboardCommand) -> KeyboardRegistrationRecord {
        if failBindings.contains(binding) {
            return KeyboardRegistrationRecord(command: command, binding: binding, status: .failed, reason: "mockFailure")
        }
        return KeyboardRegistrationRecord(command: command, binding: binding, status: .registered)
    }

    func unregister(_ binding: String, command: KeyboardCommand) -> KeyboardRegistrationRecord {
        KeyboardRegistrationRecord(command: command, binding: binding, status: .released)
    }

    func unregisterAll() -> [KeyboardRegistrationRecord] {
        []
    }
}

private struct UserDefaultsFixture {
    let suiteName = "SwooshCoreTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private struct MockKeyboardTargetResolver: KeyboardTargetResolving {
    var target: WindowTargetIdentity?
    var failure: WindowTargetFailure?

    init(target: WindowTargetIdentity? = nil, failure: WindowTargetFailure? = nil) {
        self.target = target
        self.failure = failure
    }

    func frontmostKeyboardTarget() -> Result<WindowTarget, WindowTargetFailure> {
        if let failure {
            return .failure(failure)
        }

        let target = target ?? WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")
        return .success(WindowTarget(
            identity: target,
            source: .frontmostKeyboard,
            rolePath: ["AXWindow", "AXApplication"],
            availableActions: []
        ))
    }
}

private final class MockWindowFrameController: WindowFrameControlling {
    var frames: [WindowTargetIdentity: GeometryRect]
    var rejectedTargets: Set<WindowTargetIdentity>

    init(
        initialFrames: [WindowTargetIdentity: GeometryRect],
        rejectedTargets: Set<WindowTargetIdentity> = []
    ) {
        frames = initialFrames
        self.rejectedTargets = rejectedTargets
    }

    func frame(for target: WindowTargetIdentity) -> GeometryRect? {
        frames[target]
    }

    func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool {
        guard frames[target] != nil, !rejectedTargets.contains(target) else {
            return false
        }

        frames[target] = frame
        return true
    }
}

private struct DesktopSpaceMoveRequest: Equatable {
    var target: WindowTargetIdentity
    var frame: GeometryRect
    var direction: DesktopSpaceMoveDirection
    var desktopTopY: Double
}

private final class MockDesktopSpaceMover: DesktopSpaceMoving {
    var results: [DesktopSpaceMoveDirection: DesktopSpaceMovementResult]
    private(set) var requests: [DesktopSpaceMoveRequest] = []

    init(results: [DesktopSpaceMoveDirection: DesktopSpaceMovementResult] = [:]) {
        self.results = results
    }

    func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) -> DesktopSpaceMovementResult {
        requests.append(DesktopSpaceMoveRequest(
            target: target,
            frame: frame,
            direction: direction,
            desktopTopY: desktopTopY
        ))
        return results[direction] ?? DesktopSpaceMovementResult(status: .performed)
    }
}

private final class MockDesktopSpaceTargetActivator: DesktopSpaceTargetActivating {
    var result: DesktopSpaceTargetActivationResult
    private(set) var activatedTargets: [WindowTargetIdentity] = []

    init(result: DesktopSpaceTargetActivationResult = .success) {
        self.result = result
    }

    func activate(_ target: WindowTargetIdentity) -> DesktopSpaceTargetActivationResult {
        activatedTargets.append(target)
        return result
    }
}

private final class MockLifecycleClient: WindowLifecycleControlling {
    var liveTargets: Set<WindowTargetIdentity>
    var supported: Set<WindowLifecycleAction>
    var results: [WindowLifecycleAction: WindowLifecycleResult]
    var fullscreenStates: [WindowTargetIdentity: Bool]
    var performedActions: [WindowLifecycleAction] = []

    init(
        liveTargets: Set<WindowTargetIdentity>? = nil,
        supported: Set<WindowLifecycleAction> = [],
        results: [WindowLifecycleAction: WindowLifecycleResult] = [:],
        fullscreenStates: [WindowTargetIdentity: Bool] = [:]
    ) {
        let defaultTarget = WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")
        self.liveTargets = liveTargets ?? [defaultTarget]
        self.supported = supported
        self.results = results
        self.fullscreenStates = fullscreenStates
    }

    func isAlive(_ target: WindowTargetIdentity) -> Bool {
        liveTargets.contains(target)
    }

    func supportedActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction> {
        supported
    }

    func perform(_ action: WindowLifecycleAction, for target: WindowTargetIdentity) -> WindowLifecycleResult {
        performedActions.append(action)
        return results[action] ?? WindowLifecycleResult(action: action, status: .performed)
    }

    func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        fullscreenStates[target]
    }
}
