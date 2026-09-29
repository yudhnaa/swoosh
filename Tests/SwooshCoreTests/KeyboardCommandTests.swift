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

    @Test
    func defaultsLeaveShortcutsUnassigned() {
        #expect(SwooshSettings.defaults.keyboardBindings.isEmpty)
    }

    @Test
    func bindingValidatorRejectsDuplicateReservedUnsupportedAndDeferredCommands() {
        var settings = SwooshSettings.defaults
        settings.keyboardBindings = [
            .snapLeft: "Option + Command + Left",
            .snapRight: "Command + Option + Left",
            .close: "Command + Q",
            .center: "F13",
            .unsnap: "A",
            .moveDisplayLeft: "Control + Option + Left"
        ]

        let issues = KeyboardBindingValidator().issues(for: settings)

        #expect(issues.contains { $0.command == .snapRight && $0.reason == .duplicate })
        #expect(issues.contains { $0.command == .close && $0.reason == .reservedSystemShortcut })
        #expect(issues.contains { $0.command == .center && $0.reason == .unsupportedKey })
        #expect(issues.contains { $0.command == .unsnap && $0.reason == .missingModifier })
        #expect(issues.contains { $0.command == .moveDisplayLeft && $0.reason == .unsupportedCommand })
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
            gridSpacingProvider: { 0 }
        )

        #expect(dispatcher.dispatch(.snapLeft).status == .targetFailure)
        #expect(dispatcher.dispatch(.moveDisplayLeft).status == .unavailable)
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

    init(initialFrames: [WindowTargetIdentity: GeometryRect]) {
        frames = initialFrames
    }

    func frame(for target: WindowTargetIdentity) -> GeometryRect? {
        frames[target]
    }

    func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool {
        guard frames[target] != nil else {
            return false
        }

        frames[target] = frame
        return true
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
