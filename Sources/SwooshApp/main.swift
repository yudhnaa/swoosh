import AppKit
import Darwin
import IOKit
import ServiceManagement
import SwooshCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lifecycle = LifecycleCoordinator()
    private let store = UserDefaultsSettingsStore()
    private let permissionProvider = SystemPermissionSnapshotProvider()
    private let systemDiagnosticsProvider = SystemDiagnosticsProvider()
    private let loginItemCoordinator = LoginItemCoordinator(registrar: SystemLoginItemRegistrar())
    private let displayProvider = SystemDisplayProvider()
    private let frameController = SystemWindowFrameController()
    private let lifecycleController = WindowLifecycleController(client: SystemAccessibilityLifecycleClient())
    private let frameHistory = WindowFrameHistory()
    private let runtimeSettings = KeyboardRuntimeSettings()
    private let modelBridge = SettingsModelBridge()
    private lazy var targetResolver = WindowTargetResolver(
        permissions: permissionProvider,
        client: SystemAccessibilityTargetClient()
    )
    private lazy var commandDispatcher = KeyboardWindowCommandDispatcher(
        targetResolver: targetResolver,
        frameController: frameController,
        lifecycleController: lifecycleController,
        history: frameHistory,
        displayProvider: { [displayProvider] in displayProvider.mainDisplay() },
        displayListProvider: { [displayProvider] in displayProvider.displays() },
        gridSpacingProvider: { [runtimeSettings] in runtimeSettings.gridSpacing }
    )
    private lazy var shortcutRegistrar = SystemKeyboardShortcutRegistrar { [weak self] command in
        Task { @MainActor [weak self] in
            self?.handleKeyboardCommand(command)
        }
    }
    private lazy var shortcutCoordinator = KeyboardShortcutCoordinator(registrar: shortcutRegistrar)
    private lazy var gestureInputCoordinator = GestureInputCoordinator(
        settings: runtimeSettings.settings,
        dispatcher: commandDispatcher
    )
    private lazy var gestureCapture = PrivateMultitouchCaptureSource(
        settingsProvider: { [runtimeSettings] in runtimeSettings.settings }
    )
    private lazy var gesturePreviewOverlay = GesturePreviewOverlayController()
    private lazy var gestureController = GestureRuntimeController(
        capture: gestureCapture,
        targetResolver: targetResolver,
        coordinator: gestureInputCoordinator,
        topologyTokenProvider: { [displayProvider] in displayProvider.topologyToken },
        onCommandResult: { [modelBridge] result in
            modelBridge.recordGestureCommandResult(result)
        },
        onCaptureDiagnostics: { [modelBridge] diagnostics in
            modelBridge.recordPrivateCaptureDiagnostics(diagnostics)
        },
        onStatusChanged: { [modelBridge] status, reason in
            modelBridge.recordGestureStatus(status, failureReason: reason)
        },
        onDebugChanged: { [modelBridge] summary in
            modelBridge.recordGestureDebugSummary(summary)
        },
        onPreviewChanged: { [weak self, runtimeSettings] command, fullscreenState, displayMovementPreview, pointer in
            self?.gesturePreviewOverlay.show(
                command,
                fullscreenState: fullscreenState,
                displayMovementPreview: displayMovementPreview,
                size: runtimeSettings.settings.overlayPreviewSize,
                near: pointer
            )
        },
        onPreviewEnded: { [weak self] in
            self?.gesturePreviewOverlay.hide()
        }
    )
    private lazy var model: SettingsModel = {
        let model = SettingsModel(
            store: store,
            permissionProvider: permissionProvider,
            systemDiagnosticsProvider: systemDiagnosticsProvider,
            loginItemCoordinator: loginItemCoordinator,
            runtimeSettings: runtimeSettings,
            shortcutCoordinator: shortcutCoordinator,
            commandDispatcher: commandDispatcher,
            gestureController: gestureController
        )
        modelBridge.model = model
        model.recheckPermissions()
        return model
    }()
    fileprivate var statusController: StatusMenuController?
    private var settingsWindowController: SettingsWindowController?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var captureDeviceObserver: CaptureDeviceChangeObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
        
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApplication.shared.mainMenu = menu

        lifecycle.register(shortcutCoordinator)
        lifecycle.register(gestureController)
        installWorkspaceObservers()
        installCaptureDeviceObserver()
        statusController = StatusMenuController(model: model, lifecycle: lifecycle) { [weak self] in
            self?.openSettings()
        }
        settingsWindowController = SettingsWindowController(model: model)
        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeCaptureDeviceObserver()
        removeWorkspaceObservers()
        lifecycle.shutdownAll()
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.gestureController.suspendForSystemSleep()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.recheckPermissions()
            }
        })
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func installCaptureDeviceObserver() {
        let observer = CaptureDeviceChangeObserver { [weak self] in
            self?.gestureController.captureDevicesDidChange()
        }
        observer.start()
        captureDeviceObserver = observer
    }

    private func removeCaptureDeviceObserver() {
        captureDeviceObserver?.stop()
        captureDeviceObserver = nil
    }

    private func openSettings() {
        settingsWindowController?.show()
    }

    private func handleKeyboardCommand(_ command: KeyboardCommand) {
        model.handleKeyboardCommand(command)
    }
}

@MainActor
private final class CaptureDeviceChangeObserver {
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard notificationPort == nil else {
            return
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }

        notificationPort = port
        if let source = IONotificationPortGetRunLoopSource(port) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source.takeUnretainedValue(), .defaultMode)
        }

        installNotification(named: kIOFirstMatchNotification, iterator: &addedIterator)
        installNotification(named: kIOTerminatedNotification, iterator: &removedIterator)
    }

    func stop() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let notificationPort {
            if let source = IONotificationPortGetRunLoopSource(notificationPort) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source.takeUnretainedValue(), .defaultMode)
            }
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    private func installNotification(named name: UnsafePointer<CChar>, iterator: UnsafeMutablePointer<io_iterator_t>) {
        guard let notificationPort,
              let matching = IOServiceMatching("IOHIDDevice")
        else {
            return
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = IOServiceAddMatchingNotification(
            notificationPort,
            name,
            matching,
            Self.deviceChanged,
            refcon,
            iterator
        )
        guard result == KERN_SUCCESS else {
            iterator.pointee = 0
            return
        }
        Self.drain(iterator.pointee)
    }

    private func handleDeviceChanged() {
        onChange()
    }

    private nonisolated static let deviceChanged: IOServiceMatchingCallback = { refcon, iterator in
        drain(iterator)
        guard let refcon else {
            return
        }
        let observer = Unmanaged<CaptureDeviceChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor in
            observer.handleDeviceChanged()
        }
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}

final class KeyboardRuntimeSettings {
    var settings = SwooshSettings.defaults
    var gridSpacing = SwooshSettings.defaults.gridSpacing

    func apply(_ next: SwooshSettings) {
        settings = next.normalized
        gridSpacing = settings.gridSpacing
    }
}

@MainActor
private struct SystemDiagnostics: Equatable {
    var operatingSystem: String
    var processorArchitecture: String
    var displayCount: Int
    var displaySummary: String
}

@MainActor
private protocol SystemDiagnosticsProviding {
    func snapshot() -> SystemDiagnostics
}

@MainActor
private struct SystemDiagnosticsProvider: SystemDiagnosticsProviding {
    func snapshot() -> SystemDiagnostics {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #else
        let architecture = ProcessInfo.processInfo.machineHardwareName
        #endif

        let displays = NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame
            return "#\(index + 1) \(Int(frame.width))x\(Int(frame.height)) @\(screen.backingScaleFactor)x"
        }.joined(separator: ", ")

        return SystemDiagnostics(
            operatingSystem: os,
            processorArchitecture: architecture,
            displayCount: NSScreen.screens.count,
            displaySummary: displays.isEmpty ? "No active displays" : displays
        )
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let nullIndex = machine.firstIndex(of: 0) ?? machine.count
        return String(decoding: machine[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private struct SystemLoginItemRegistrar: LoginItemRegistering {
    func state() -> LoginItemRegistrationState {
        convert(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) -> LoginItemRegistrationState {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return state()
        } catch {
            return LoginItemRegistrationState(status: .error, message: error.localizedDescription)
        }
    }

    private func convert(_ status: SMAppService.Status) -> LoginItemRegistrationState {
        switch status {
        case .notRegistered:
            LoginItemRegistrationState(status: .notRegistered)
        case .enabled:
            LoginItemRegistrationState(status: .registered)
        case .requiresApproval:
            LoginItemRegistrationState(
                status: .requiresApproval,
                message: "macOS requires approval in Login Items."
            )
        case .notFound:
            LoginItemRegistrationState(status: .notFound, message: "The app is not available as a login item.")
        @unknown default:
            LoginItemRegistrationState(status: .unavailable, message: "macOS returned an unknown login item state.")
        }
    }
}

@MainActor
private final class SettingsModelBridge {
    weak var model: SettingsModel?

    func recordGestureCommandResult(_ result: WindowCommandResult) {
        model?.recordGestureCommandResult(result)
    }

    func recordPrivateCaptureDiagnostics(_ diagnostics: PrivateCaptureDiagnostics) {
        model?.recordPrivateCaptureDiagnostics(diagnostics)
    }

    func recordGestureStatus(_ status: GestureInputStatus, failureReason: GestureInputFailureReason?) {
        model?.recordGestureStatus(status, failureReason: failureReason)
    }

    func recordGestureDebugSummary(_ summary: String) {
        model?.recordGestureDebugSummary(summary)
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published private(set) var settings: SwooshSettings
    @Published private(set) var lastError: String?
    @Published private(set) var permissionDiagnostics: PermissionDiagnostics
    @Published private(set) var systemDiagnostics: SystemDiagnostics
    @Published private(set) var loginItemState: LoginItemRegistrationState
    @Published private(set) var shortcutRegistrationRecords: [KeyboardRegistrationRecord] = []
    @Published private(set) var lastCommandResult: WindowCommandResult?
    @Published private(set) var isRecordingShortcut = false
    @Published private(set) var gestureInputStatus: GestureInputStatus = .stopped
    @Published private(set) var gestureFailureReason: GestureInputFailureReason?
    @Published private(set) var gestureDebugSummary = "No gesture events yet"

    private let store: SettingsPersisting
    private let permissionProvider: PermissionSnapshotProviding
    private let systemDiagnosticsProvider: SystemDiagnosticsProviding
    private let loginItemCoordinator: LoginItemCoordinator
    private let runtimeSettings: KeyboardRuntimeSettings
    private let shortcutCoordinator: KeyboardShortcutCoordinator
    private let commandDispatcher: KeyboardWindowCommandDispatcher
    private let gestureController: GestureRuntimeController
    private var shortcutRecordingDepth = 0

    init(
        store: SettingsPersisting,
        permissionProvider: PermissionSnapshotProviding = SystemPermissionSnapshotProvider(),
        systemDiagnosticsProvider: SystemDiagnosticsProviding = SystemDiagnosticsProvider(),
        loginItemCoordinator: LoginItemCoordinator,
        runtimeSettings: KeyboardRuntimeSettings,
        shortcutCoordinator: KeyboardShortcutCoordinator,
        commandDispatcher: KeyboardWindowCommandDispatcher,
        gestureController: GestureRuntimeController
    ) {
        self.store = store
        self.permissionProvider = permissionProvider
        self.systemDiagnosticsProvider = systemDiagnosticsProvider
        self.loginItemCoordinator = loginItemCoordinator
        self.runtimeSettings = runtimeSettings
        self.shortcutCoordinator = shortcutCoordinator
        self.commandDispatcher = commandDispatcher
        self.gestureController = gestureController
        let loadedSettings = store.load().normalized
        let loginSnapshot = loginItemCoordinator.refresh(settings: loadedSettings)
        let effectiveSettings = loginSnapshot.settings
        settings = effectiveSettings
        runtimeSettings.apply(effectiveSettings)
        permissionDiagnostics = permissionProvider.snapshot()
        systemDiagnostics = systemDiagnosticsProvider.snapshot()
        loginItemState = loginSnapshot.state
        shortcutRegistrationRecords = shortcutCoordinator.apply(effectiveSettings)
        gestureController.apply(settings: effectiveSettings, permissions: permissionDiagnostics)
    }

    var isPaused: Bool {
        settings.isPaused
    }

    var shortcutFailures: [KeyboardRegistrationRecord] {
        shortcutRegistrationRecords.filter { $0.status == .failed }
    }

    var visibleError: String? {
        guard let lastError else {
            return nil
        }

        if lastError.contains("duplicateKeyboardBindings") {
            return "That shortcut is already assigned."
        }

        if lastError.contains("invalidKeyboardBindings") {
            return "That shortcut is reserved or unsupported."
        }

        return lastError
    }

    func update(_ mutate: (inout SwooshSettings) -> Void) {
        var next = settings
        mutate(&next)
        if next.launchAtLogin != settings.launchAtLogin {
            updateLaunchAtLogin(next.launchAtLogin)
            return
        }

        if next.showInDock != settings.showInDock {
            NSApplication.shared.setActivationPolicy(next.showInDock ? .regular : .accessory)
        }
        
        if next.showInMenuBar != settings.showInMenuBar {
            (NSApp.delegate as? AppDelegate)?.statusController?.updateVisibility(show: next.showInMenuBar)
        }

        do {
            try store.save(next)
            settings = next.normalized
            runtimeSettings.apply(settings)
            shortcutRegistrationRecords = shortcutCoordinator.apply(settings)
            gestureController.apply(settings: settings, permissions: permissionDiagnostics)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func restoreDefaults() {
        do {
            let restored = try store.restoreDefaults()
            let loginSnapshot = loginItemCoordinator.setEnabled(restored.launchAtLogin, settings: restored)
            try store.save(loginSnapshot.settings)
            settings = loginSnapshot.settings
            loginItemState = loginSnapshot.state
            runtimeSettings.apply(settings)
            shortcutRegistrationRecords = shortcutCoordinator.apply(settings)
            gestureController.apply(settings: settings, permissions: permissionDiagnostics)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func recheckPermissions() {
        permissionDiagnostics = permissionProvider.snapshot()
        systemDiagnostics = systemDiagnosticsProvider.snapshot()
        refreshLoginItemState()
        gestureController.apply(settings: settings, permissions: permissionDiagnostics)
    }

    func refreshLoginItemState() {
        let snapshot = loginItemCoordinator.refresh(settings: settings)
        settings = snapshot.settings
        loginItemState = snapshot.state
        runtimeSettings.apply(settings)
        shortcutRegistrationRecords = shortcutCoordinator.apply(settings)
        try? store.save(settings)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            let snapshot = loginItemCoordinator.setEnabled(enabled, settings: settings)
            try store.save(snapshot.settings)
            settings = snapshot.settings
            loginItemState = snapshot.state
            runtimeSettings.apply(settings)
            shortcutRegistrationRecords = shortcutCoordinator.apply(settings)
            gestureController.apply(settings: settings, permissions: permissionDiagnostics)
            lastError = snapshot.state.status == .error ? snapshot.state.message : nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func beginShortcutRecording() {
        shortcutRecordingDepth += 1
        guard shortcutRecordingDepth == 1 else {
            return
        }

        isRecordingShortcut = true
        shortcutRegistrationRecords = shortcutCoordinator.releaseAll()
    }

    func endShortcutRecording() {
        guard shortcutRecordingDepth > 0 else {
            return
        }

        shortcutRecordingDepth -= 1
        guard shortcutRecordingDepth == 0 else {
            return
        }

        isRecordingShortcut = false
        shortcutRegistrationRecords = shortcutCoordinator.apply(settings)
    }

    func handleKeyboardCommand(_ command: KeyboardCommand) {
        guard !settings.isPaused, !isRecordingShortcut else {
            return
        }

        lastCommandResult = commandDispatcher.dispatch(command)
    }

    func recordGestureCommandResult(_ result: WindowCommandResult) {
        lastCommandResult = result
    }

    func recordPrivateCaptureDiagnostics(_ diagnostics: PrivateCaptureDiagnostics) {
        permissionDiagnostics.privateMultitouch = diagnostics
    }

    func recordGestureStatus(_ status: GestureInputStatus, failureReason: GestureInputFailureReason?) {
        gestureInputStatus = status
        gestureFailureReason = failureReason
    }

    func recordGestureDebugSummary(_ summary: String) {
        gestureDebugSummary = summary
    }
}

@MainActor
final class GestureRuntimeController: @preconcurrency LifecycleResource {
    private let capture: GestureCaptureSource
    private let targetResolver: WindowTargetResolver
    private let coordinator: GestureInputCoordinator
    private let topologyTokenProvider: () -> String
    private let onCommandResult: (WindowCommandResult) -> Void
    private let onCaptureDiagnostics: (PrivateCaptureDiagnostics) -> Void
    private let onStatusChanged: (GestureInputStatus, GestureInputFailureReason?) -> Void
    private let onDebugChanged: (String) -> Void
    private let onPreviewChanged: (KeyboardCommand, Bool?, DisplayMovementPreviewContext?, ScreenPoint) -> Void
    private let onPreviewEnded: () -> Void
    private var settings = SwooshSettings.defaults
    private var timeoutGeneration = 0
    private var resolverSessionActive = false
    private var capturedEventCount = 0
    private var titlebarRejectCount = 0
    private var commandCommitCount = 0
    private var lastDebugEvent = "No gesture events yet"
    private var pendingRestoreTap: RestoreTapCandidate?
    private var activeGestureTarget: WindowTargetIdentity?
    private var activeGestureModifierMode: GestureModifierMode = .unsupported
    private var activeGestureStartedAt: Int?
    private var stagedStrokeDirections: [GestureDirection] = []
    private var lastPresentedPreviewLabel: String?
    private var idleDiscardGeneration = 0
    private var suppressActiveGestureUntilRelease = false
    private let previewLatencyTracker = GesturePreviewLatencyTracker()
    private let captureOwnership = CaptureEventOwnershipGate()
    private let restoreDoubleTapWindowMilliseconds = 450
    private var expectedCaptureDeviceCount = 0
    private var captureRefreshGeneration = 0
    private var captureRefreshScheduled = false
    private var captureRecoveryAttempt = 0
    private var lastCaptureDeviceCount = 0
    private var lastStartedCaptureDeviceCount = 0
    private let captureDeviceChangeDebounceMilliseconds = 350
    private let captureRecoveryRetryMilliseconds = 1_000
    private let maximumCaptureRecoveryAttempts = 12

    init(
        capture: GestureCaptureSource,
        targetResolver: WindowTargetResolver,
        coordinator: GestureInputCoordinator,
        topologyTokenProvider: @escaping () -> String,
        onCommandResult: @escaping (WindowCommandResult) -> Void,
        onCaptureDiagnostics: @escaping (PrivateCaptureDiagnostics) -> Void,
        onStatusChanged: @escaping (GestureInputStatus, GestureInputFailureReason?) -> Void,
        onDebugChanged: @escaping (String) -> Void,
        onPreviewChanged: @escaping (KeyboardCommand, Bool?, DisplayMovementPreviewContext?, ScreenPoint) -> Void,
        onPreviewEnded: @escaping () -> Void
    ) {
        self.capture = capture
        self.targetResolver = targetResolver
        self.coordinator = coordinator
        self.topologyTokenProvider = topologyTokenProvider
        self.onCommandResult = onCommandResult
        self.onCaptureDiagnostics = onCaptureDiagnostics
        self.onStatusChanged = onStatusChanged
        self.onDebugChanged = onDebugChanged
        self.onPreviewChanged = onPreviewChanged
        self.onPreviewEnded = onPreviewEnded
    }

    func apply(settings: SwooshSettings, permissions: PermissionDiagnostics) {
        self.settings = settings.normalized
        coordinator.updateSettings(self.settings)
        timeoutGeneration += 1
        idleDiscardGeneration += 1
        captureRefreshGeneration += 1
        captureRefreshScheduled = false
        captureRecoveryAttempt = 0
        previewLatencyTracker.reset()
        captureOwnership.reset()
        resetActiveGestureState()
        onPreviewEnded()

        let permissionReady = permissions.accessibilityTrusted && permissions.inputMonitoringTrusted
        let captureReady = permissions.privateMultitouch.isUsable
        expectedCaptureDeviceCount = max(expectedCaptureDeviceCount, permissions.privateMultitouch.deviceCount)
        coordinator.start(permissionReady: permissionReady, captureReady: captureReady)
        updateDebug("startup permissions=\(permissionReady ? "ready" : "missing") capturePrereq=\(captureReady ? "available" : "unavailable")")
        publishStatus()

        guard self.settings.gesturesEnabled, !self.settings.isPaused, permissionReady, captureReady else {
            capture.stop()
            captureRefreshGeneration += 1
            captureRefreshScheduled = false
            captureRecoveryAttempt = 0
            updateDebug("capture stopped: gestures=\(self.settings.gesturesEnabled) paused=\(self.settings.isPaused) permissions=\(permissionReady) prereq=\(captureReady)")
            return
        }

        switch capture.start(handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }) {
        case .running(let diagnostics):
            handleCaptureRunning(diagnostics, context: "capture running")
        case .failed(let diagnostics):
            onCaptureDiagnostics(diagnostics)
            coordinator.listenerFailed()
            updateDebug("capture failed: \(diagnostics.reason)")
            publishStatus()
        case .stopped:
            updateDebug("capture stopped")
            publishStatus()
        }
    }

    func captureDevicesDidChange() {
        captureRecoveryAttempt = 0
        scheduleCaptureDeviceRefresh(reason: "device change")
    }

    func shutdown() {
        timeoutGeneration += 1
        idleDiscardGeneration += 1
        captureRefreshGeneration += 1
        captureRefreshScheduled = false
        captureRecoveryAttempt = 0
        previewLatencyTracker.reset()
        captureOwnership.reset()
        resetActiveGestureState()
        onPreviewEnded()
        _ = coordinator.cancel(.paused, at: timestampMilliseconds())
        coordinator.stop()
        capture.stop()
        updateDebug("shutdown")
        publishStatus()
    }

    func suspendForSystemSleep() {
        timeoutGeneration += 1
        idleDiscardGeneration += 1
        captureRefreshGeneration += 1
        captureRefreshScheduled = false
        captureRecoveryAttempt = 0
        previewLatencyTracker.reset()
        captureOwnership.reset()
        resetActiveGestureState()
        onPreviewEnded()
        _ = coordinator.cancel(.gestureCancelled, at: timestampMilliseconds())
        capture.stop()
        updateDebug("capture stopped: system sleep")
        publishStatus()
    }

    private func handleCaptureRunning(
        _ diagnostics: PrivateCaptureDiagnostics,
        context: String,
        forceDebug: Bool = true
    ) {
        expectedCaptureDeviceCount = max(
            expectedCaptureDeviceCount,
            diagnostics.deviceCount,
            diagnostics.startedDeviceCount
        )
        let deviceCountsChanged = diagnostics.deviceCount != lastCaptureDeviceCount ||
            diagnostics.startedDeviceCount != lastStartedCaptureDeviceCount
        lastCaptureDeviceCount = diagnostics.deviceCount
        lastStartedCaptureDeviceCount = diagnostics.startedDeviceCount
        let startedSummary = diagnostics.startedDeviceCount > 0
            ? "\(diagnostics.startedDeviceCount)/\(max(diagnostics.deviceCount, diagnostics.startedDeviceCount))"
            : "\(diagnostics.started)"
        onCaptureDiagnostics(diagnostics)
        if forceDebug || deviceCountsChanged || diagnostics.startedDeviceCount < expectedCaptureDeviceCount {
            updateDebug("\(context): devices=\(diagnostics.deviceCount) started=\(startedSummary)")
            publishStatus()
        }
        if diagnostics.startedDeviceCount >= expectedCaptureDeviceCount {
            captureRecoveryAttempt = 0
        } else if context.hasPrefix("capture refresh") {
            scheduleCaptureRecoveryIfNeeded()
        }
    }

    private func scheduleCaptureRecoveryIfNeeded() {
        guard lastStartedCaptureDeviceCount < expectedCaptureDeviceCount else {
            captureRecoveryAttempt = 0
            return
        }

        guard captureRecoveryAttempt < maximumCaptureRecoveryAttempts else {
            updateDebug("capture recovery waiting for device change: devices=\(lastCaptureDeviceCount) expected=\(expectedCaptureDeviceCount)")
            publishStatus()
            return
        }

        captureRecoveryAttempt += 1
        scheduleCaptureDeviceRefresh(
            reason: "device recovery \(captureRecoveryAttempt)/\(maximumCaptureRecoveryAttempts)",
            delayMilliseconds: captureRecoveryRetryMilliseconds
        )
    }

    private func scheduleCaptureDeviceRefresh(
        reason: String,
        delayMilliseconds: Int? = nil
    ) {
        guard settings.gesturesEnabled,
              !settings.isPaused,
              !captureRefreshScheduled
        else {
            return
        }

        captureRefreshScheduled = true
        let generation = captureRefreshGeneration
        let delay = delayMilliseconds ?? captureDeviceChangeDebounceMilliseconds
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self,
                  self.captureRefreshGeneration == generation,
                  self.settings.gesturesEnabled,
                  !self.settings.isPaused
            else {
                return
            }

            self.captureRefreshScheduled = false
            switch self.capture.refreshDevices() {
            case .running(let refreshed):
                self.handleCaptureRunning(refreshed, context: "capture refresh: \(reason)", forceDebug: false)
            case .failed(let refreshed):
                self.onCaptureDiagnostics(refreshed)
                self.coordinator.listenerFailed()
                self.updateDebug("capture refresh failed after \(reason): \(refreshed.reason)")
                self.publishStatus()
            case .stopped:
                self.updateDebug("capture refresh after \(reason): stopped")
                self.publishStatus()
            }
        }
    }

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

        switch event {
        case .began(let start):
            timeoutGeneration += 1
            idleDiscardGeneration += 1
            suppressActiveGestureUntilRelease = false
            guard !resolverSessionActive else {
                updateDebug("begin ignored during active chain")
                return
            }
            let targetResult = targetResolver.targetUnderPointer(at: start.pointer)
            let target = try? targetResult.get().identity
            if target == nil {
                titlebarRejectCount += 1
                updateDebug("begin rejected: \(targetResult.failureDescription)")
            }
            let result = route(.begin(GestureSessionStart(
                target: target,
                modifiers: start.modifiers,
                timestampMilliseconds: start.timestampMilliseconds,
                topologyToken: topologyTokenProvider()
            )), actionID: nil)
            resolverSessionActive = result.resolverOutput.kind == .none
            if resolverSessionActive {
                activeGestureTarget = target
                activeGestureModifierMode = modifierMode(for: start.modifiers, settings: settings)
                activeGestureStartedAt = start.timestampMilliseconds
                lastPresentedPreviewLabel = nil
                scheduleIdleDiscard(at: start.timestampMilliseconds)
                updateDebug("begin accepted: modifiers=\(start.modifiers.debugNames)")
            }

        case .movement(let timestampMilliseconds):
            handleMovement(at: timestampMilliseconds)

        case .deviceMovement(let movement):
            handleMovement(at: movement.timestampMilliseconds)

        case .changed(let progress):
            guard !suppressActiveGestureUntilRelease else {
                return
            }
            guard !cancelForTopologyChangeIfNeeded(at: progress.timestampMilliseconds) else {
                return
            }
            presentLivePreview(for: progress)

        case .strokeEnded(let stroke):
            handleStrokeEnded(stroke, sourceEvent: event)

        case .pinchEnded(let pinch):
            handlePinchEnded(pinch, sourceEvent: event)

        case .tapEnded(let tap):
            idleDiscardGeneration += 1
            if suppressActiveGestureUntilRelease {
                suppressActiveGestureUntilRelease = false
                updateDebug("tap ignored after idle discard")
                captureOwnership.releaseOwner(for: event)
                publishStatus()
                return
            }
            handleRestoreTap(tap)
            captureOwnership.releaseOwner(for: event)

        case .ended(let timestampMilliseconds):
            handleEnded(at: timestampMilliseconds, sourceEvent: event)

        case .deviceEnded(let end):
            handleEnded(at: end.timestampMilliseconds, sourceEvent: event)

        case .cancelled(let reason, let timestampMilliseconds):
            handleCancelled(reason, at: timestampMilliseconds, sourceEvent: event)

        case .deviceCancelled(let cancellation):
            handleCancelled(cancellation.reason, at: cancellation.timestampMilliseconds, sourceEvent: event)
        }

        publishStatus()
    }

    private func handleMovement(at timestampMilliseconds: Int) {
        guard !suppressActiveGestureUntilRelease else {
            return
        }
        guard !cancelForTopologyChangeIfNeeded(at: timestampMilliseconds) else {
            return
        }
        scheduleIdleDiscard(at: timestampMilliseconds)
    }

    private func handleStrokeEnded(_ stroke: CapturedGestureStroke, sourceEvent event: CapturedGestureEvent) {
        guard !suppressActiveGestureUntilRelease else {
            suppressActiveGestureUntilRelease = false
            updateDebug("stroke \(stroke.direction.rawValue): ignored after idle discard")
            captureOwnership.releaseOwner(for: event)
            publishStatus()
            return
        }
        pendingRestoreTap = nil
        guard !cancelForTopologyChangeIfNeeded(at: stroke.timestampMilliseconds) else {
            return
        }
        if !resolverSessionActive {
            beginResolverSession(
                pointer: stroke.pointer,
                modifiers: stroke.modifiers,
                timestampMilliseconds: stroke.timestampMilliseconds,
                debugPrefix: "late stroke begin"
            )
        }
        if activeGestureModifierMode != .unmodified {
            onPreviewEnded()
        }
        let result = route(.strokeEnded(GestureStroke(
            direction: stroke.direction,
            timestampMilliseconds: stroke.timestampMilliseconds,
            eventID: stroke.eventID,
            modifiers: stroke.modifiers
        )), actionID: stroke.eventID)
        switch result.resolverOutput.kind {
        case .preview:
            resolverSessionActive = true
            stagedStrokeDirections.append(stroke.direction)
            presentResolvedPreview(from: result.resolverOutput, pointer: stroke.pointer, recognizedAt: stroke.timestampMilliseconds)
            updateDebug("stroke \(stroke.direction.rawValue): preview \(result.resolverOutput.intent?.command.displayName ?? "unknown")")
        case .commit, .cancel, .passThrough:
            onPreviewEnded()
            captureOwnership.releaseOwner(for: event)
            resetActiveGestureState()
            updateDebug("stroke \(stroke.direction.rawValue): \(result.resolverOutput.kind.rawValue)\(result.commandResult.debugSuffix)")
        case .none:
            updateDebug("stroke \(stroke.direction.rawValue): ignored")
            break
        }
    }

    private func handlePinchEnded(_ pinch: CapturedGesturePinch, sourceEvent event: CapturedGestureEvent) {
        timeoutGeneration += 1
        idleDiscardGeneration += 1
        if suppressActiveGestureUntilRelease {
            suppressActiveGestureUntilRelease = false
            updateDebug("pinch \(pinch.direction.rawValue): ignored after idle discard")
            captureOwnership.releaseOwner(for: event)
            publishStatus()
            return
        }
        pendingRestoreTap = nil
        guard !cancelForTopologyChangeIfNeeded(at: pinch.timestampMilliseconds) else {
            return
        }
        if !resolverSessionActive {
            beginResolverSession(
                pointer: pinch.pointer,
                modifiers: pinch.modifiers,
                timestampMilliseconds: pinch.timestampMilliseconds,
                debugPrefix: "late pinch begin",
                fallingBackToFrontmost: pinch.direction == .outward
            )
        }
        onPreviewEnded()
        let result = route(.pinchEnded(GesturePinch(
            direction: pinch.direction,
            timestampMilliseconds: pinch.timestampMilliseconds,
            eventID: pinch.eventID,
            isCancelled: pinch.isCancelled,
            modifiers: pinch.modifiers
        )), actionID: pinch.eventID)
        captureOwnership.releaseOwner(for: event)
        if result.resolverOutput.kind == .commit || result.resolverOutput.kind == .cancel || result.resolverOutput.kind == .passThrough {
            onPreviewEnded()
            resetActiveGestureState()
        }
        updateDebug("pinch \(pinch.direction.rawValue): \(result.resolverOutput.kind.rawValue) \(result.resolverOutput.intent?.command.displayName ?? "")\(result.commandResult.debugSuffix)")
    }

    private func handleEnded(at timestampMilliseconds: Int, sourceEvent event: CapturedGestureEvent) {
        idleDiscardGeneration += 1
        if suppressActiveGestureUntilRelease {
            suppressActiveGestureUntilRelease = false
            updateDebug("ended ignored after idle discard")
            captureOwnership.releaseOwner(for: event)
            publishStatus()
            return
        }
        guard !cancelForTopologyChangeIfNeeded(at: timestampMilliseconds) else {
            return
        }
        onPreviewEnded()
        let result = route(.release(timestampMilliseconds: timestampMilliseconds), actionID: "release-\(timestampMilliseconds)")
        captureOwnership.releaseOwner(for: event)
        if result.resolverOutput.kind == .commit || result.resolverOutput.kind == .cancel || result.resolverOutput.kind == .passThrough {
            resetActiveGestureState()
        }
        updateDebug("release: \(result.resolverOutput.kind.rawValue) \(result.resolverOutput.intent?.command.displayName ?? "")\(result.commandResult.debugSuffix)")
    }

    private func handleCancelled(_ reason: GestureCancelReason, at timestampMilliseconds: Int, sourceEvent event: CapturedGestureEvent) {
        timeoutGeneration += 1
        idleDiscardGeneration += 1
        captureOwnership.releaseOwner(for: event)
        resetActiveGestureState()
        onPreviewEnded()
        _ = coordinator.cancel(reason, at: timestampMilliseconds)
        updateDebug("cancelled: \(reason.rawValue)")
    }

    private func beginResolverSession(
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        debugPrefix: String,
        fallingBackToFrontmost: Bool = false
    ) {
        let targetResult = targetResolver.targetUnderPointer(
            at: pointer,
            fallingBackToFrontmost: fallingBackToFrontmost
        )
        let target = try? targetResult.get().identity
        if target == nil {
            titlebarRejectCount += 1
            updateDebug("\(debugPrefix) rejected: \(targetResult.failureDescription)")
        }
        let result = route(.begin(GestureSessionStart(
            target: target,
            modifiers: modifiers,
            timestampMilliseconds: timestampMilliseconds,
            topologyToken: topologyTokenProvider()
        )), actionID: nil)
        resolverSessionActive = result.resolverOutput.kind == .none
        if resolverSessionActive {
            activeGestureTarget = target
            activeGestureModifierMode = modifierMode(for: modifiers, settings: settings)
            activeGestureStartedAt = timestampMilliseconds
            lastPresentedPreviewLabel = nil
            scheduleIdleDiscard(at: timestampMilliseconds)
            updateDebug("\(debugPrefix) accepted: modifiers=\(modifiers.debugNames)")
        }
    }

    @discardableResult
    private func route(_ event: GestureResolverEvent, actionID: String?) -> GestureInputResult {
        let result = coordinator.handle(event, actionID: actionID)
        if let commandResult = result.commandResult {
            commandCommitCount += 1
            onCommandResult(commandResult)
            updateDebug(commandResult.debugSummary)
        }
        return result
    }

    private func cancelForTopologyChangeIfNeeded(at timestampMilliseconds: Int) -> Bool {
        let result = coordinator.cancelIfTopologyChanged(
            currentTopologyToken: topologyTokenProvider(),
            at: timestampMilliseconds
        )
        guard result.resolverOutput.kind == .cancel else {
            return false
        }

        onPreviewEnded()
        captureOwnership.releaseOwner()
        resetActiveGestureState()
        updateDebug("topology changed: cancelled preview")
        publishStatus()
        return true
    }

    private func handleRestoreTap(_ tap: CapturedGestureTap) {
        timeoutGeneration += 1
        if resolverSessionActive {
            _ = coordinator.cancel(.gestureCancelled, at: tap.timestampMilliseconds)
            resetActiveGestureState(clearPendingTap: false)
        }

        let targetResult = targetResolver.targetUnderPointer(at: tap.pointer)
        guard let target = try? targetResult.get().identity else {
            titlebarRejectCount += 1
            resetActiveGestureState()
            updateDebug("tap rejected: \(targetResult.failureDescription)")
            return
        }

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
        onPreviewEnded()
        let result = coordinator.dispatch(command, to: target, actionID: tap.eventID)
        if let commandResult = result.commandResult {
            commandCommitCount += 1
            onCommandResult(commandResult)
            updateDebug(commandResult.debugSummary)
        }
        updateDebug("double tap restore: \(result.resolverOutput.kind.rawValue) \(command.displayName)")
    }

    private func presentLivePreview(for progress: CapturedGestureProgress) {
        guard settings.previewsEnabled,
              settings.overlayPreviewSize != .off,
              resolverSessionActive,
              activeGestureTarget != nil,
              let command = previewCommand(for: progress)
        else {
            return
        }

        let label = command.displayName
        guard label != lastPresentedPreviewLabel else {
            onPreviewChanged(command, fullscreenState(for: command), displayMovementPreview(for: command), progress.pointer)
            recordPreviewLatency(recognizedAt: progress.timestampMilliseconds)
            updateDebug("live preview: \(label)")
            return
        }

        lastPresentedPreviewLabel = label
        onPreviewChanged(command, fullscreenState(for: command), displayMovementPreview(for: command), progress.pointer)
        recordPreviewLatency(recognizedAt: progress.timestampMilliseconds)
        updateDebug("live preview: \(label)")
    }

    private func fullscreenState(for command: KeyboardCommand) -> Bool? {
        guard command == .toggleFullscreen, let activeGestureTarget else {
            return nil
        }

        return coordinator.isFullscreen(activeGestureTarget)
    }

    private func displayMovementPreview(for command: KeyboardCommand) -> DisplayMovementPreviewContext? {
        guard command.displayMoveDirection != nil, let activeGestureTarget else {
            return nil
        }

        return coordinator.displayMovementPreview(for: command, target: activeGestureTarget)
    }

    private func recordPreviewLatency(recognizedAt timestamp: Int) {
        _ = previewLatencyTracker.record(
            recognizedAt: timestamp,
            presentedAt: timestampMilliseconds()
        )
    }

    private func previewCommand(for progress: CapturedGestureProgress) -> KeyboardCommand? {
        switch progress.kind {
        case .stroke(let direction):
            switch activeGestureModifierMode {
            case .unmodified:
                if stagedStrokeDirections.isEmpty,
                   direction.isHorizontal,
                   !hasReachedDesktopSpaceHoldThreshold(at: progress.timestampMilliseconds) {
                    return nil
                }

                return GestureSequenceResolver.command(
                    for: stagedStrokeDirections + [direction],
                    modifierMode: activeGestureModifierMode,
                    startedAt: activeGestureStartedAt,
                    timestampMilliseconds: progress.timestampMilliseconds,
                    configuration: GestureResolverConfiguration(settings: settings)
                )
            case .general:
                return GestureSequenceResolver.command(
                    for: [direction],
                    modifierMode: activeGestureModifierMode,
                    startedAt: activeGestureStartedAt,
                    timestampMilliseconds: progress.timestampMilliseconds,
                    configuration: GestureResolverConfiguration(settings: settings)
                )
            case .screen:
                return GestureSequenceResolver.command(
                    for: [direction],
                    modifierMode: activeGestureModifierMode,
                    startedAt: activeGestureStartedAt,
                    timestampMilliseconds: progress.timestampMilliseconds,
                    configuration: GestureResolverConfiguration(settings: settings)
                )
            case .unsupported:
                return nil
            }
        case .pinch(let direction):
            guard activeGestureModifierMode == .unmodified else {
                return nil
            }
            return direction == .inward ? .close : .toggleFullscreen
        }
    }

    private func hasReachedDesktopSpaceHoldThreshold(at timestampMilliseconds: Int) -> Bool {
        guard let activeGestureStartedAt else {
            return false
        }

        return timestampMilliseconds - activeGestureStartedAt >= GestureResolverConfiguration(settings: settings).desktopSpaceMovementHoldMilliseconds
    }

    private func presentResolvedPreview(
        from output: GestureResolverOutput,
        pointer: ScreenPoint,
        recognizedAt timestampMilliseconds: Int
    ) {
        guard settings.previewsEnabled,
              settings.overlayPreviewSize != .off,
              let command = output.intent?.command
        else {
            return
        }

        lastPresentedPreviewLabel = command.displayName
        onPreviewChanged(command, fullscreenState(for: command), displayMovementPreview(for: command), pointer)
        recordPreviewLatency(recognizedAt: timestampMilliseconds)
    }

    private func scheduleTimeout(after stroke: CapturedGestureStroke) {
        timeoutGeneration += 1
        let generation = timeoutGeneration
        let delay = settings.chainTimeoutMilliseconds
        let timeoutTimestamp = stroke.timestampMilliseconds + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, self.timeoutGeneration == generation else {
                return
            }
            guard !self.cancelForTopologyChangeIfNeeded(at: timeoutTimestamp) else {
                return
            }
            self.onPreviewEnded()
            let result = self.route(.timeout(timestampMilliseconds: timeoutTimestamp), actionID: "timeout-\(stroke.eventID)")
            if result.resolverOutput.kind == .commit || result.resolverOutput.kind == .cancel || result.resolverOutput.kind == .passThrough {
                self.captureOwnership.releaseOwner()
                self.resetActiveGestureState()
            }
            self.updateDebug("timeout: \(result.resolverOutput.kind.rawValue) \(result.resolverOutput.intent?.command.displayName ?? "")")
            self.publishStatus()
        }
    }

    private func scheduleIdleDiscard(at timestampMilliseconds: Int) {
        idleDiscardGeneration += 1
        let generation = idleDiscardGeneration
        let delay = settings.gestureIdleTimeoutMilliseconds
        let cancelTimestamp = timestampMilliseconds + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self,
                  self.idleDiscardGeneration == generation,
                  self.resolverSessionActive
            else {
                return
            }

            _ = self.coordinator.cancel(.gestureCancelled, at: cancelTimestamp)
            self.suppressActiveGestureUntilRelease = true
            self.resetActiveGestureState(clearSuppression: false)
            self.onPreviewEnded()
            self.updateDebug("idle discard after \(delay)ms")
            self.publishStatus()
        }
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
        if let data = "[swoosh] \(summary)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private func timestampMilliseconds() -> Int {
        Int((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func resetActiveGestureState(clearPendingTap: Bool = true, clearSuppression: Bool = true) {
        resolverSessionActive = false
        if clearPendingTap {
            pendingRestoreTap = nil
        }
        if clearSuppression {
            suppressActiveGestureUntilRelease = false
        }
        activeGestureTarget = nil
        activeGestureModifierMode = .unsupported
        activeGestureStartedAt = nil
        stagedStrokeDirections = []
        lastPresentedPreviewLabel = nil
    }
}

private struct RestoreTapCandidate {
    var source: CapturedGestureSource
    var target: WindowTargetIdentity
    var modifiers: Set<ModifierRole>
    var timestampMilliseconds: Int
}

private extension CenterBehavior {
    var keyboardCommand: KeyboardCommand {
        switch self {
        case .centerAndUnsnap:
            .centerAndUnsnap
        case .center:
            .center
        case .unsnap:
            .unsnap
        }
    }
}

private extension GestureDirection {
    var isHorizontal: Bool {
        self == .left || self == .right
    }
}

private func modifierMode(for modifiers: Set<ModifierRole>, settings: SwooshSettings) -> GestureModifierMode {
    if modifiers.isEmpty {
        return .unmodified
    }

    if modifiers == [settings.generalModifier] {
        return .general
    }

    if modifiers == [settings.screenModifier] {
        return .screen
    }

    return .unsupported
}

private extension OverlayPreviewSize {
    var panelSize: NSSize {
        switch self {
        case .off:
            NSSize(width: 0, height: 0)
        case .small:
            NSSize(width: 50, height: 36)
        case .medium:
            NSSize(width: 66, height: 48)
        case .large:
            NSSize(width: 82, height: 58)
        }
    }

    var displayMovementPanelSize: NSSize {
        let size = panelSize
        return NSSize(width: size.width * 1.1, height: size.height * 1.1)
    }

    var cornerRadius: CGFloat {
        switch self {
        case .off:
            0
        case .small:
            12
        case .medium:
            15
        case .large:
            18
        }
    }
}

private extension Result where Success == WindowTarget, Failure == WindowTargetFailure {
    var failureDescription: String {
        switch self {
        case .success:
            "none"
        case .failure(let failure):
            "\(failure)"
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
        guard let result = self else {
            return ""
        }

        return "; \(result.debugSummary)"
    }
}

@MainActor
private final class StatusMenuController {
    private let statusItem: NSStatusItem
    private weak var model: SettingsModel?
    private let openSettings: () -> Void
    private let lifecycle: LifecycleCoordinator

    init(model: SettingsModel, lifecycle: LifecycleCoordinator, openSettings: @escaping () -> Void) {
        self.model = model
        self.lifecycle = lifecycle
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusMenuController.createMenuBarIcon()
        statusItem.isVisible = model.settings.showInMenuBar
        rebuildMenu()
    }

    private static func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        
        let swooshPath = NSBezierPath()
        let scale: CGFloat = 18.0 / 1024.0
        swooshPath.move(to: NSPoint(x: 200 * scale, y: 300 * scale))
        swooshPath.curve(
            to: NSPoint(x: 824 * scale, y: 700 * scale),
            controlPoint1: NSPoint(x: 400 * scale, y: 100 * scale),
            controlPoint2: NSPoint(x: 600 * scale, y: 900 * scale)
        )
        swooshPath.lineWidth = 100 * scale
        swooshPath.lineCapStyle = .round
        NSColor.black.setStroke()
        swooshPath.stroke()
        
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func updateVisibility(show: Bool) {
        statusItem.isVisible = show
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Settings", action: #selector(openSettingsItem), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem(title: model?.isPaused == true ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Swoosh", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openSettingsItem() {
        openSettings()
    }

    @objc private func togglePause() {
        model?.update { $0.isPaused.toggle() }
        rebuildMenu()
    }

    @objc private func quit() {
        lifecycle.shutdownAll()
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
private final class SettingsWindowController {
    private let window: NSWindow

    init(model: SettingsModel) {
        let rootView = PreferencesRootView(model: model)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Swoosh Settings"
        window.collectionBehavior = [.fullScreenNone]
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class GesturePreviewOverlayController {
    private let panel: NSPanel
    private let previewView: GesturePreviewOverlayView
    private let coordinateConverter = CoordinateConverter()
    private var hideWorkItem: DispatchWorkItem?
    private var currentPanelSize = OverlayPreviewSize.large.panelSize

    init() {
        previewView = GesturePreviewOverlayView(frame: NSRect(origin: .zero, size: OverlayPreviewSize.large.panelSize))

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayPreviewSize.large.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = previewView
    }

    func show(
        _ command: KeyboardCommand,
        fullscreenState: Bool?,
        displayMovementPreview: DisplayMovementPreviewContext?,
        size: OverlayPreviewSize,
        near pointer: ScreenPoint
    ) {
        guard size != .off else {
            hide()
            return
        }

        hideWorkItem?.cancel()
        currentPanelSize = displayMovementPreview == nil ? size.panelSize : size.displayMovementPanelSize
        previewView.command = command
        previewView.fullscreenState = fullscreenState
        previewView.displayMovementPreview = displayMovementPreview
        previewView.previewSize = size
        positionPanel(near: pointer)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: workItem)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.alphaValue = 0
        previewView.displayMovementPreview = nil
        panel.orderOut(nil)
    }

    private func positionPanel(near pointer: ScreenPoint) {
        let point = appKitPoint(fromCapturedPointer: pointer)
        guard let screen = screen(containingAppKitPoint: point) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let frame = screen.visibleFrame
        let size = currentPanelSize
        let margin: CGFloat = 8
        let gap: CGFloat = 4
        var origin = NSPoint(x: point.x - (size.width / 2), y: point.y + gap)
        if origin.y + size.height > frame.maxY - margin {
            origin.y = point.y - size.height - gap
        }
        origin.x = min(max(origin.x, frame.minX + margin), frame.maxX - size.width - margin)
        origin.y = min(max(origin.y, frame.minY + margin), frame.maxY - size.height - margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func screen(containingAppKitPoint point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            NSPointInRect(point, screen.frame)
        }
    }

    private func appKitPoint(fromCapturedPointer point: ScreenPoint) -> NSPoint {
        guard let desktopTopY = NSScreen.screens.map(\.frame.maxY).max() else {
            return NSPoint(x: point.x, y: point.y)
        }

        let converted = coordinateConverter.accessibilityToAppKit(
            GeometryPoint(x: point.x, y: point.y),
            desktopTopY: desktopTopY
        )
        return NSPoint(
            x: converted.x,
            y: converted.y
        )
    }
}

private final class GesturePreviewOverlayView: NSView {
    var command: KeyboardCommand = .maximize {
        didSet {
            needsDisplay = true
        }
    }
    var fullscreenState: Bool? {
        didSet {
            needsDisplay = true
        }
    }
    var displayMovementPreview: DisplayMovementPreviewContext? {
        didSet {
            needsDisplay = true
        }
    }
    var previewSize = OverlayPreviewSize.large {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let capsule = bounds.insetBy(dx: 1, dy: 1)
        if let displayMovementPreview, command.displayMoveDirection != nil {
            drawDisplayMovementPreview(displayMovementPreview, in: capsule)
            return
        }

        if let lifecycleButton = lifecycleButton(for: command, fullscreenState: fullscreenState) {
            drawLifecycleButton(lifecycleButton, in: capsule)
            return
        }

        let radius = previewSize.cornerRadius
        let path = NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.96).setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.systemBlue.setFill()
        activeRegion(in: capsule, for: command).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func activeRegion(in capsule: NSRect, for command: KeyboardCommand) -> NSBezierPath {
        let rect: NSRect
        switch command {
        case .snapLeft:
            rect = NSRect(x: capsule.minX, y: capsule.minY, width: capsule.width / 2, height: capsule.height)
        case .snapRight:
            rect = NSRect(x: capsule.midX, y: capsule.minY, width: capsule.width / 2, height: capsule.height)
        case .snapTop:
            rect = NSRect(x: capsule.minX, y: capsule.minY, width: capsule.width, height: capsule.height / 2)
        case .snapBottom:
            rect = NSRect(x: capsule.minX, y: capsule.midY, width: capsule.width, height: capsule.height / 2)
        case .minimize:
            let width = capsule.width * 0.56
            let height = max(4, capsule.height * 0.14)
            let bottomInset = max(5, capsule.height * 0.12)
            rect = NSRect(x: capsule.midX - width / 2, y: capsule.maxY - height - bottomInset, width: width, height: height)
        case .snapTopLeft:
            rect = NSRect(x: capsule.minX, y: capsule.minY, width: capsule.width / 2, height: capsule.height / 2)
        case .snapTopRight:
            rect = NSRect(x: capsule.midX, y: capsule.minY, width: capsule.width / 2, height: capsule.height / 2)
        case .snapBottomLeft:
            rect = NSRect(x: capsule.minX, y: capsule.midY, width: capsule.width / 2, height: capsule.height / 2)
        case .snapBottomRight:
            rect = NSRect(x: capsule.midX, y: capsule.midY, width: capsule.width / 2, height: capsule.height / 2)
        case .center, .unsnap, .centerAndUnsnap:
            let width = capsule.width * 0.58
            let height = capsule.height * 0.58
            rect = NSRect(x: capsule.midX - width / 2, y: capsule.midY - height / 2, width: width, height: height)
        case .close:
            rect = capsule.insetBy(dx: capsule.width * 0.18, dy: capsule.height * 0.18)
        case .maximize,
             .toggleFullscreen,
             .moveDisplayLeft,
             .moveDisplayRight,
             .moveDisplayUp,
             .moveDisplayDown,
             .moveSpaceLeft,
             .moveSpaceRight,
             .moveSpaceUp,
             .moveSpaceDown:
            rect = capsule
        }

        return NSBezierPath(rect: rect)
    }

    private func drawDisplayMovementPreview(_ preview: DisplayMovementPreviewContext, in bounds: NSRect) {
        guard !preview.displays.isEmpty else {
            return
        }

        let displayBounds = unionFrame(for: preview.displays)
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            return
        }

        let padding = max(5, min(bounds.width, bounds.height) * 0.12)
        let layoutArea = bounds.insetBy(dx: padding, dy: padding)
        let scale = min(layoutArea.width / displayBounds.width, layoutArea.height / displayBounds.height)
        let scaledWidth = displayBounds.width * scale
        let scaledHeight = displayBounds.height * scale
        let origin = NSPoint(
            x: layoutArea.midX - scaledWidth / 2,
            y: layoutArea.midY - scaledHeight / 2
        )

        for display in preview.displays {
            let rect = previewRect(
                for: display.frame,
                displayBounds: displayBounds,
                origin: origin,
                scale: scale
            )
            let isCurrent = display.id == preview.currentDisplayID
            let isHighlighted = display.id == preview.highlightedDisplayID
            drawDisplayTile(in: rect, isCurrent: isCurrent, isHighlighted: isHighlighted)
        }
    }

    private func unionFrame(for displays: [DisplayGeometry]) -> GeometryRect {
        let minX = displays.map(\.frame.x).min() ?? 0
        let minY = displays.map(\.frame.y).min() ?? 0
        let maxX = displays.map(\.frame.maxX).max() ?? minX
        let maxY = displays.map(\.frame.maxY).max() ?? minY
        return GeometryRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func previewRect(
        for frame: GeometryRect,
        displayBounds: GeometryRect,
        origin: NSPoint,
        scale: CGFloat
    ) -> NSRect {
        NSRect(
            x: origin.x + CGFloat(frame.x - displayBounds.x) * scale,
            y: origin.y + CGFloat(displayBounds.maxY - frame.maxY) * scale,
            width: max(6, CGFloat(frame.width) * scale),
            height: max(6, CGFloat(frame.height) * scale)
        )
    }

    private func drawDisplayTile(in rect: NSRect, isCurrent: Bool, isHighlighted: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        let fill = isHighlighted
            ? NSColor.systemBlue.withAlphaComponent(0.92)
            : NSColor.white.withAlphaComponent(isCurrent ? 0.78 : 0.52)
        fill.setFill()
        path.fill()

        let strokeColor: NSColor
        if isHighlighted {
            strokeColor = .systemBlue
        } else if isCurrent {
            strokeColor = .systemBlue.withAlphaComponent(0.72)
        } else {
            strokeColor = .black.withAlphaComponent(0.18)
        }
        strokeColor.setStroke()
        path.lineWidth = isCurrent || isHighlighted ? 1.8 : 1
        path.stroke()

        if isCurrent && !isHighlighted {
            let inset = min(rect.width, rect.height) * 0.16
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            NSColor.systemBlue.withAlphaComponent(0.34).setFill()
            dot.fill()
        }
    }

    private func lifecycleButton(for command: KeyboardCommand, fullscreenState: Bool?) -> LifecyclePreviewButton? {
        switch command {
        case .close:
            return .close
        case .minimize:
            return .minimize
        case .toggleFullscreen:
            return fullscreenState == true ? .exitFullscreen : .enterFullscreen
        default:
            return nil
        }
    }

    private func drawLifecycleButton(_ button: LifecyclePreviewButton, in capsule: NSRect) {
        let diameter = min(capsule.width, capsule.height) * 0.52
        let rect = NSRect(
            x: capsule.midX - diameter / 2,
            y: capsule.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let buttonPath = NSBezierPath(ovalIn: rect)

        button.fillColor.setFill()
        buttonPath.fill()

        NSColor.white.withAlphaComponent(0.98).setStroke()
        NSColor.white.withAlphaComponent(0.98).setFill()
        switch button {
        case .close:
            drawCloseGlyph(in: rect)
        case .minimize:
            drawMinimizeGlyph(in: rect)
        case .enterFullscreen:
            drawFullscreenGlyph(in: rect, pointsInward: false)
        case .exitFullscreen:
            drawFullscreenGlyph(in: rect, pointsInward: true)
        }
    }

    private func drawCloseGlyph(in rect: NSRect) {
        let inset = rect.width * 0.32
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.lineCapStyle = .round
        path.lineWidth = max(1.8, rect.width * 0.11)
        path.stroke()
    }

    private func drawMinimizeGlyph(in rect: NSRect) {
        let width = rect.width * 0.42
        let height = max(2.0, rect.height * 0.10)
        let glyphRect = NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        let path = NSBezierPath(roundedRect: glyphRect, xRadius: height / 2, yRadius: height / 2)
        path.fill()
    }

    private func drawFullscreenGlyph(in rect: NSRect, pointsInward: Bool) {
        let pad = rect.width * 0.27
        let gap = rect.width * 0.08
        let triangleHeight = rect.height * 0.38
        let leftEdge = rect.minX + pad
        let rightEdge = rect.maxX - pad
        let centerLeft = rect.midX - gap / 2
        let centerRight = rect.midX + gap / 2
        let top = rect.midY - triangleHeight / 2
        let bottom = rect.midY + triangleHeight / 2

        let left = NSBezierPath()
        let right = NSBezierPath()

        if pointsInward {
            left.move(to: NSPoint(x: leftEdge, y: top))
            left.line(to: NSPoint(x: centerLeft, y: rect.midY))
            left.line(to: NSPoint(x: leftEdge, y: bottom))
            right.move(to: NSPoint(x: rightEdge, y: top))
            right.line(to: NSPoint(x: centerRight, y: rect.midY))
            right.line(to: NSPoint(x: rightEdge, y: bottom))
        } else {
            left.move(to: NSPoint(x: centerLeft, y: top))
            left.line(to: NSPoint(x: leftEdge, y: rect.midY))
            left.line(to: NSPoint(x: centerLeft, y: bottom))
            right.move(to: NSPoint(x: centerRight, y: top))
            right.line(to: NSPoint(x: rightEdge, y: rect.midY))
            right.line(to: NSPoint(x: centerRight, y: bottom))
        }

        left.close()
        right.close()
        left.fill()
        right.fill()
    }
}

private enum LifecyclePreviewButton {
    case close
    case minimize
    case enterFullscreen
    case exitFullscreen

    var fillColor: NSColor {
        switch self {
        case .close:
            return .systemRed
        case .minimize:
            return .systemBlue
        case .enterFullscreen, .exitFullscreen:
            return .systemGreen
        }
    }
}

private struct PreferencesRootView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection = PreferencesPane.general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Swoosh")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SettingsPalette.heading)
                    .padding(.horizontal, 14)
                    .padding(.top, 18)

                VStack(spacing: 4) {
                    ForEach(PreferencesPane.allCases) { pane in
                        Button {
                            selection = pane
                        } label: {
                            Label(pane.title, systemImage: pane.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == pane ? SettingsPalette.accent : SettingsPalette.sidebarText)
                        .background(selection == pane ? SettingsPalette.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityAddTraits(selection == pane ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)

                Spacer()
            }
            .frame(width: 196)
            .background(SettingsPalette.sidebarBackground)

            Divider()

            switch selection {
            case .general:
                GeneralSettingsView(model: model)
            case .snapping:
                SnappingSettingsView(model: model)
            case .windows:
                WindowsSettingsView(model: model)
            case .shortcuts:
                ShortcutsSettingsView(model: model)
            case .advanced:
                AdvancedSettingsView(model: model)
            case .about:
                AboutSettingsView()
            }
        }
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .background(SettingsPalette.pageBackground)
        .toggleStyle(.switch)
    }
}

private enum PreferencesPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case snapping
    case windows
    case shortcuts
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .snapping:
            "Snapping"
        case .windows:
            "Windows"
        case .shortcuts:
            "Shortcuts"
        case .advanced:
            "Advanced"
        case .about:
            "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "switch.2"
        case .snapping:
            "rectangle.3.group"
        case .windows:
            "macwindow"
        case .shortcuts:
            "keyboard"
        case .advanced:
            "slider.horizontal.3"
        case .about:
            "info.circle"
        }
    }
}

private struct PreferencesPage<Content: View>: View {
    var title: String
    var subtitle: String
    var status: StatusBadge?
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String,
        status: StatusBadge? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(SettingsPalette.heading)
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(SettingsPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    if let status {
                        status
                    }
                }

                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .background(SettingsPalette.pageBackground)
        .toggleStyle(.switch)
    }
}

private struct SettingsGroup<Content: View>: View {
    var title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(SettingsPalette.heading)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(SettingsPalette.groupBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SettingsPalette.groupStroke, lineWidth: 1)
            }

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(SettingsPalette.primaryText)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 20)

            content
                .labelsHidden()
        }
        .padding(.vertical, 9)
        .frame(minHeight: 42)
    }
}

private struct ReadOnlySettingsRow<Accessory: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    init(title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(SettingsPalette.primaryText)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 20)

            accessory
        }
        .padding(.vertical, 9)
        .frame(minHeight: 42)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 1)
            .overlay(SettingsPalette.divider)
    }
}

private enum SettingsPalette {
    static let accent = Color(red: 0.18, green: 0.39, blue: 0.72)
    static let accentSoft = Color(red: 0.18, green: 0.55, blue: 0.63)
    static let pageBackground = Color(red: 0.965, green: 0.972, blue: 0.978)
    static let sidebarBackground = Color(red: 0.92, green: 0.94, blue: 0.955)
    static let groupBackground = Color.white.opacity(0.72)
    static let groupStroke = Color.black.opacity(0.06)
    static let selectionFill = accent.opacity(0.13)
    static let primaryText = Color(red: 0.12, green: 0.14, blue: 0.17)
    static let secondaryText = Color(red: 0.39, green: 0.43, blue: 0.48)
    static let sidebarText = Color(red: 0.24, green: 0.28, blue: 0.33)
    static let heading = Color(red: 0.09, green: 0.12, blue: 0.16)
    static let divider = Color.black.opacity(0.07)
    static let ready = Color(red: 0.16, green: 0.52, blue: 0.34)
    static let attention = Color(red: 0.73, green: 0.43, blue: 0.12)
    static let destructive = Color(red: 0.74, green: 0.25, blue: 0.31)
    static let info = accentSoft
    static let muted = secondaryText
}

private struct StatusBadge: View {
    var title: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.22), lineWidth: 1)
            }
            .accessibilityLabel(title)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var isShowingSetup = false

    var body: some View {
        PreferencesPage(
            title: "General",
            subtitle: "Start, pause, and prepare Swoosh without crowding the everyday controls.",
            status: readinessBadge
        ) {
            SettingsGroup(
                title: "Setup",
                footer: "Use setup when first launching Swoosh, after macOS permission changes, or when gestures stop responding."
            ) {
                ReadOnlySettingsRow(title: "Permissions and Diagnostics", detail: setupSummary) {
                    Button {
                        isShowingSetup = true
                    } label: {
                        Label("Open Setup", systemImage: "checklist")
                    }
                    .help("Open permission, capture, listener, and diagnostics setup.")
                }
            }

            SettingsGroup(
                title: "App State",
                footer: "Pausing keeps preferences intact while temporarily stopping gestures and shortcuts."
            ) {
                SettingsRow(title: "Paused", detail: "Temporarily stop Swoosh from acting on gestures and shortcuts.") {
                    Toggle("Paused", isOn: binding(\.isPaused))
                }
                SettingsDivider()
                SettingsRow(title: "Gestures", detail: "Enable trackpad gesture capture when required permissions are available.") {
                    Toggle("Gestures Enabled", isOn: binding(\.gesturesEnabled))
                }
                SettingsDivider()
                SettingsRow(title: "Launch at Login", detail: "Swoosh mirrors the effective macOS login item state.") {
                    Toggle("Launch at Login", isOn: binding(\.launchAtLogin))
                        .help("macOS may require approval in System Settings before Swoosh can launch at login.")
                }
                SettingsDivider()
                SettingsRow(title: "Show in Dock", detail: "Display Swoosh in the macOS Dock when running.") {
                    Toggle("Show in Dock", isOn: binding(\.showInDock))
                        .help("Toggle visibility of the app icon in the Dock.")
                }
                SettingsDivider()
                SettingsRow(title: "Show in Menu Bar", detail: "Display Swoosh in the macOS Menu Bar.") {
                    Toggle("Show in Menu Bar", isOn: binding(\.showInMenuBar))
                        .help("Toggle visibility of the app icon in the Menu Bar.")
                }
                SettingsDivider()
                ReadOnlySettingsRow(title: "Login Item", detail: model.loginItemState.message) {
                    StatusBadge(
                        title: model.loginItemState.status.displayName,
                        systemImage: model.loginItemState.isEffectivelyEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        color: model.loginItemState.isEffectivelyEnabled ? SettingsPalette.ready : SettingsPalette.attention
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingSetup) {
            PermissionSetupSheet(model: model)
        }
    }

    private var readinessBadge: StatusBadge {
        switch model.permissionDiagnostics.readiness {
        case .ready:
            StatusBadge(title: "Ready", systemImage: "checkmark.circle.fill", color: SettingsPalette.ready)
        case .blocked(let requirements):
            StatusBadge(title: "\(requirements.count) Issue\(requirements.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill", color: SettingsPalette.attention)
        }
    }

    private var setupSummary: String {
        switch model.permissionDiagnostics.readiness {
        case .ready:
            "All required permissions and capture prerequisites are ready."
        case .blocked(let requirements):
            "\(requirements.count) setup item\(requirements.count == 1 ? "" : "s") need attention."
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SwooshSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct PermissionSetupSheet: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Welcome Setup")
                        .font(.title2.weight(.semibold))
                Text("Review permissions, capture readiness, and current diagnostics before using gestures.")
                    .font(.callout)
                    .foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PermissionDiagnosticsView(model: model)
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .frame(width: 760, height: 560)
    }
}

private struct PermissionDiagnosticsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup(
            title: "Permissions and Diagnostics",
            footer: "Diagnostics stay limited to permission, listener, display, and action state. Swoosh does not show document text, screenshots, account data, raw keystrokes, or raw touch frames."
        ) {
            ReadOnlySettingsRow(title: "Accessibility", detail: "Required for targeting and moving windows.") {
                permissionBadge(model.permissionDiagnostics.accessibilityTrusted)
            }
            SettingsDivider()
            ReadOnlySettingsRow(title: "Input Monitoring", detail: "Required for global gesture capture.") {
                permissionBadge(model.permissionDiagnostics.inputMonitoringTrusted)
            }
            SettingsDivider()
            ReadOnlySettingsRow(title: "Private Capture", detail: privateCaptureDetail) {
                StatusBadge(
                    title: model.permissionDiagnostics.privateMultitouch.isUsable ? "Available" : "Needs Setup",
                    systemImage: model.permissionDiagnostics.privateMultitouch.isUsable ? "checkmark.circle.fill" : "xmark.circle.fill",
                    color: model.permissionDiagnostics.privateMultitouch.isUsable ? SettingsPalette.ready : SettingsPalette.destructive
                )
            }
            SettingsDivider()
            ReadOnlySettingsRow(title: "Gesture Input", detail: model.gestureFailureReason?.rawValue) {
                Text(model.gestureInputStatus.rawValue.capitalized)
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .monospacedDigit()
            }
            SettingsDivider()
            ReadOnlySettingsRow(title: "Displays", detail: displayDiagnosticsDetail) {
                Text(model.systemDiagnostics.displaySummary)
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            SettingsDivider()
            ReadOnlySettingsRow(title: "System", detail: "\(model.systemDiagnostics.operatingSystem) · \(model.systemDiagnostics.processorArchitecture)") {
                Text("Hardware support still requires the physical verification task before release claims.")
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()
            HStack(spacing: 10) {
                Button {
                    model.recheckPermissions()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .help("Refresh permissions, login item state, and system diagnostics.")

                ForEach(permissionRequirements, id: \.kind) { requirement in
                    if let url = requirement.settingsURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open \(buttonTitle(for: requirement.kind))", systemImage: "gearshape")
                        }
                        .help(requirement.message)
                    }
                }
            }
            .padding(.vertical, 9)
        }
    }

    private var permissionRequirements: [PermissionRequirement] {
        switch model.permissionDiagnostics.readiness {
        case .ready:
            []
        case .blocked(let requirements):
            requirements
        }
    }

    private var privateCaptureDetail: String {
        let diagnostics = model.permissionDiagnostics.privateMultitouch
        let active = "\(diagnostics.startedDeviceCount)/\(max(diagnostics.deviceCount, diagnostics.startedDeviceCount)) active"
        return "\(active) · \(diagnostics.reason)"
    }

    private var displayDiagnosticsDetail: String {
        let count = model.systemDiagnostics.displayCount
        return count == 1 ? "1 active display" : "\(count) active displays"
    }

    private func buttonTitle(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            "Accessibility"
        case .inputMonitoring:
            "Input Monitoring"
        case .privateMultitouch:
            "Capture"
        }
    }

    private func permissionBadge(_ isReady: Bool) -> StatusBadge {
        StatusBadge(
            title: isReady ? "Ready" : "Missing",
            systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            color: isReady ? SettingsPalette.ready : SettingsPalette.attention
        )
    }
}

private struct WindowsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PreferencesPage(
            title: "Windows",
            subtitle: "Choose the modifier keys that separate standard window gestures from screen-oriented gestures."
        ) {
            SettingsGroup(title: "Gesture Modifiers") {
                SettingsRow(title: "General Modifier", detail: "Used for snap, maximize, center, restore, and lifecycle gestures.") {
                    Picker("General Modifier", selection: modifierBinding(\.generalModifier)) {
                        ForEach(ModifierRole.allCases, id: \.self) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    .frame(width: 180)
                }
                SettingsDivider()
                SettingsRow(title: "Screen Modifier", detail: "Required for display movement gestures.") {
                    Picker("Screen Modifier", selection: modifierBinding(\.screenModifier)) {
                        ForEach(ModifierRole.allCases, id: \.self) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    .frame(width: 180)
                }
            }
        }
    }

    private func modifierBinding(_ keyPath: WritableKeyPath<SwooshSettings, ModifierRole>) -> Binding<ModifierRole> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct SnappingSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PreferencesPage(
            title: "Snapping",
            subtitle: "Tune gesture feel, snap geometry, restore behavior, and previews in one place."
        ) {
            SettingsGroup(title: "Gesture Feel") {
                SettingsRow(title: "Touch Sensitivity", detail: "Higher values require stronger movement before gestures commit.") {
                    HStack(spacing: 10) {
                        Text("\(model.settings.sensitivity)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(SettingsPalette.secondaryText)
                            .frame(width: 56, alignment: .trailing)
                        Slider(value: Binding(get: { Double(sensitivityBinding.wrappedValue) }, set: { sensitivityBinding.wrappedValue = Int($0) }), in: Double(SwooshSettings.sensitivityRange.lowerBound)...Double(SwooshSettings.sensitivityRange.upperBound), step: 1) { Text("Touch Sensitivity") }.labelsHidden()
                    }
                    .frame(width: 150)
                }
                SettingsDivider()
                SettingsRow(title: "Gesture Idle Timeout", detail: "Time allowed before an unfinished gesture is cancelled.") {
                    HStack(spacing: 10) {
                        Text("\(model.settings.gestureIdleTimeoutMilliseconds) ms")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(SettingsPalette.secondaryText)
                            .frame(width: 80, alignment: .trailing)
                        Slider(value: Binding(get: { Double(model.settings.gestureIdleTimeoutMilliseconds) }, set: { intBinding(\.gestureIdleTimeoutMilliseconds).wrappedValue = Int($0) }), in: Double(SwooshSettings.gestureIdleTimeoutRange.lowerBound)...Double(SwooshSettings.gestureIdleTimeoutRange.upperBound), step: 50) { Text("Gesture Idle Timeout") }.labelsHidden()
                    }
                    .frame(width: 176)
                }
            }

            SettingsGroup(title: "Snap Layout") {
                SettingsRow(title: "Center Action", detail: "Action used when a center gesture commits.") {
                    Picker("Center Action", selection: centerBinding) {
                        ForEach(CenterBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .frame(width: 190)
                }
                SettingsDivider()
                SettingsRow(title: "Grid Spacing", detail: "Inset added between snapped window edges and screen bounds.") {
                    HStack(spacing: 10) {
                        Text(model.settings.gridSpacing == 0 ? "Off" : "\(model.settings.gridSpacing) pt")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(SettingsPalette.secondaryText)
                            .frame(width: 64, alignment: .trailing)
                        Slider(value: Binding(get: { Double(model.settings.gridSpacing) }, set: { intBinding(\.gridSpacing).wrappedValue = Int($0) }), in: Double(SwooshSettings.gridSpacingRange.lowerBound)...Double(SwooshSettings.gridSpacingRange.upperBound), step: 1) { Text("Grid Spacing") }.labelsHidden()
                    }
                    .frame(width: 160)
                }
            }

            SettingsGroup(
                title: "Gesture Preview",
                footer: "Choose Off to disable previews. Any size enables the lightweight pointer overlay."
            ) {
                SettingsRow(title: "Preview Size", detail: "Preview shown near the pointer before a gesture command commits.") {
                    Picker("Preview Size", selection: previewSizeBinding) {
                        ForEach(OverlayPreviewSize.allCases, id: \.self) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .frame(width: 190)
                }
            }
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<SwooshSettings, Int>) -> Binding<Int> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } }
        )
    }

    private var sensitivityBinding: Binding<Int> {
        Binding(
            get: { model.settings.sensitivity },
            set: { value in model.update { $0.sensitivity = value } }
        )
    }

    private var centerBinding: Binding<CenterBehavior> {
        Binding(
            get: { model.settings.centerBehavior },
            set: { value in model.update { $0.centerBehavior = value } }
        )
    }

    private var previewSizeBinding: Binding<OverlayPreviewSize> {
        Binding(
            get: { model.settings.previewsEnabled ? model.settings.overlayPreviewSize : .off },
            set: { value in
                model.update { settings in
                    settings.previewsEnabled = value != .off
                    settings.overlayPreviewSize = value
                }
            }
        )
    }
}

private struct AdvancedSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PreferencesPage(
            title: "Advanced",
            subtitle: "Use these actions when you need to repair or reset Swoosh."
        ) {
            SettingsGroup(
                title: "Reset",
                footer: "Restore Defaults resets Swoosh preferences and shortcut bindings. It does not grant or remove macOS privacy permissions."
            ) {
                ReadOnlySettingsRow(title: "Default Settings", detail: "Return app choices to the built-in defaults.") {
                    Button(role: .destructive) {
                        model.restoreDefaults()
                    } label: {
                        Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .help("Restore Swoosh settings to defaults.")
                }

                if let lastError = model.lastError {
                    SettingsDivider()
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(SettingsPalette.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 9)
                }
            }
        }
    }
}

private struct ShortcutsSettingsView: View {
    @ObservedObject var model: SettingsModel

    private var commands: [KeyboardCommand] {
        KeyboardCommand.allCases.filter(\.isMVPKeyboardCommand)
    }

    var body: some View {
        PreferencesPage(
            title: "Shortcuts",
            subtitle: "Assign optional global shortcuts for window and display commands.",
            status: keyboardStatusBadge
        ) {
            SettingsGroup(
                title: "Bindings",
                footer: "Click a field and press a shortcut. Delete clears the binding; Escape keeps the current value."
            ) {
                ForEach(commands, id: \.self) { command in
                    SettingsRow(title: command.displayName) {
                        ShortcutRecorderField(
                            shortcut: binding(for: command),
                            onRecordingChanged: { isRecording in
                                if isRecording {
                                    model.beginShortcutRecording()
                                } else {
                                    model.endShortcutRecording()
                                }
                            }
                        )
                        .frame(width: 190, height: 24)
                        .help("Click and press a shortcut. Backspace clears the binding.")
                    }

                    if command != commands.last {
                        SettingsDivider()
                    }
                }
            }

                    }
    }

    private var keyboardStatusBadge: StatusBadge {
        if model.isRecordingShortcut {
            return StatusBadge(title: "Recording", systemImage: "record.circle", color: SettingsPalette.info)
        }

        if model.visibleError != nil || !model.shortcutFailures.isEmpty {
            return StatusBadge(title: "Needs Attention", systemImage: "exclamationmark.triangle.fill", color: SettingsPalette.attention)
        }

        if model.settings.keyboardBindings.isEmpty {
            return StatusBadge(title: "Unassigned", systemImage: "keyboard", color: SettingsPalette.muted)
        }

        return StatusBadge(
            title: model.settings.isPaused ? "Paused" : "Registered",
            systemImage: model.settings.isPaused ? "pause.circle.fill" : "checkmark.circle.fill",
            color: model.settings.isPaused ? SettingsPalette.attention : SettingsPalette.ready
        )
    }

    private var keyboardStatusDetail: String {
        if model.isRecordingShortcut {
            return "Press a modified key combination to assign it."
        }

        if let visibleError = model.visibleError {
            return visibleError
        }

        if model.settings.keyboardBindings.isEmpty {
            return "No keyboard shortcuts are assigned."
        }

        if !model.shortcutFailures.isEmpty {
            return "One or more shortcuts could not be registered by macOS."
        }

        return model.settings.isPaused ? "Shortcuts are configured but paused." : "Configured shortcuts are registered."
    }

    private func binding(for command: KeyboardCommand) -> Binding<String> {
        Binding(
            get: { model.settings.keyboardBindings[command] ?? "" },
            set: { value in
                model.update { settings in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        settings.keyboardBindings.removeValue(forKey: command)
                    } else {
                        settings.keyboardBindings[command] = trimmed
                    }
                }
            }
        )
    }
}

private struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: String
    var onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderTextField {
        let field = ShortcutRecorderTextField()
        field.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        field.onRecordingChanged = onRecordingChanged
        return field
    }

    func updateNSView(_ field: ShortcutRecorderTextField, context: Context) {
        field.shortcut = shortcut
        field.onRecordingChanged = onRecordingChanged
    }
}

private final class ShortcutRecorderTextField: NSTextField {
    var onShortcut: (String) -> Void = { _ in }
    var onRecordingChanged: (Bool) -> Void = { _ in }
    var shortcut = "" {
        didSet {
            guard window?.firstResponder !== self else {
                return
            }
            stringValue = shortcut
            placeholderString = "Unassigned"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = true
        drawsBackground = true
        bezelStyle = .roundedBezel
        alignment = .center
        focusRingType = .default
        placeholderString = "Unassigned"
        toolTip = "Click and press a shortcut. Backspace clears."
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        stringValue = "Press shortcut"
        onRecordingChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        stringValue = shortcut
        onRecordingChanged(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            shortcut = ""
            onShortcut("")
            window?.makeFirstResponder(nil)
        case 53:
            window?.makeFirstResponder(nil)
        default:
            guard let recorded = Self.shortcut(from: event) else {
                NSSound.beep()
                return
            }
            shortcut = recorded
            onShortcut(recorded)
            window?.makeFirstResponder(nil)
        }
    }

    private static func shortcut(from event: NSEvent) -> String? {
        guard let key = keyName(from: event) else {
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.command) {
            modifiers.append("command")
        }
        if flags.contains(.option) {
            modifiers.append("option")
        }
        if flags.contains(.control) {
            modifiers.append("control")
        }
        if flags.contains(.shift) {
            modifiers.append("shift")
        }

        guard !modifiers.isEmpty else {
            return nil
        }

        return (modifiers + [key]).joined(separator: "+")
    }

    private static func keyName(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 123:
            return "left"
        case 124:
            return "right"
        case 125:
            return "down"
        case 126:
            return "up"
        case 36:
            return "enter"
        case 49:
            return "space"
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased(), character.count == 1 else {
                return nil
            }

            return character.first?.isLetter == true || character.first?.isNumber == true ? character : nil
        }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        PreferencesPage(
            title: "About Swoosh",
            subtitle: "Version information and project details."
        ) {
            SettingsGroup(title: "Application") {
                ReadOnlySettingsRow(title: "Version") {
                    Text(appVersion)
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .monospacedDigit()
                }
                SettingsDivider()
                ReadOnlySettingsRow(title: "Build") {
                    Text(appBuild)
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .monospacedDigit()
                }
            }

            SettingsGroup(title: "Credits") {
                ForEach(Array(DependencyCredits.current.enumerated()), id: \.element.name) { index, credit in
                    ReadOnlySettingsRow(title: credit.name, detail: credit.purpose) {
                        EmptyView()
                    }

                    if index < DependencyCredits.current.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "local"
    }
}

private extension ModifierRole {
    var displayName: String {
        switch self {
        case .control:
            "Control"
        case .command:
            "Command"
        case .option:
            "Option"
        case .shift:
            "Shift"
        case .function:
            "Function"
        }
    }
}

private extension CenterBehavior {
    var displayName: String {
        switch self {
        case .centerAndUnsnap:
            "Center and Restore"
        case .center:
            "Center"
        case .unsnap:
            "Restore"
        }
    }
}

private extension OverlayPreviewSize {
    var displayName: String {
        switch self {
        case .off:
            "Off"
        case .small:
            "Small"
        case .medium:
            "Medium"
        case .large:
            "Large"
        }
    }
}

private extension LoginItemRegistrationStatus {
    var displayName: String {
        switch self {
        case .notRegistered:
            "Off"
        case .registered:
            "Registered"
        case .requiresApproval:
            "Requires Approval"
        case .notFound:
            "Not Found"
        case .unavailable:
            "Unavailable"
        case .error:
            "Error"
        }
    }
}

@main
enum SwooshApplicationMain {
    @MainActor private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
