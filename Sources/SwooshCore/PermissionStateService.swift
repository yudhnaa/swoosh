import ApplicationServices
import CoreGraphics
import Foundation

public struct PrivateMultitouchCapabilityState: Equatable, Sendable {
    public var frameworkAvailable: Bool
    public var requiredSymbolsAvailable: Bool

    public init(frameworkAvailable: Bool, requiredSymbolsAvailable: Bool) {
        self.frameworkAvailable = frameworkAvailable
        self.requiredSymbolsAvailable = requiredSymbolsAvailable
    }
}

public struct PrivateMultitouchDeviceState: Equatable, Sendable {
    public var availableDeviceCount: Int

    public init(availableDeviceCount: Int) {
        self.availableDeviceCount = availableDeviceCount
    }
}

public struct PrivateMultitouchCaptureState: Equatable, Sendable {
    public var started: Bool
    public var startedDeviceCount: Int
    public var failedDeviceCount: Int
    public var reason: String

    public init(
        started: Bool,
        startedDeviceCount: Int,
        failedDeviceCount: Int,
        reason: String
    ) {
        self.started = started
        self.startedDeviceCount = startedDeviceCount
        self.failedDeviceCount = failedDeviceCount
        self.reason = reason
    }
}

public struct PermissionStateSnapshot: Equatable, Sendable {
    public var accessibilityTrusted: Bool
    public var inputMonitoringTrusted: Bool
    public var privateCapability: PrivateMultitouchCapabilityState
    public var privateDevices: PrivateMultitouchDeviceState
    public var privateCapture: PrivateMultitouchCaptureState

    public init(
        accessibilityTrusted: Bool,
        inputMonitoringTrusted: Bool,
        privateCapability: PrivateMultitouchCapabilityState,
        privateDevices: PrivateMultitouchDeviceState,
        privateCapture: PrivateMultitouchCaptureState
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringTrusted = inputMonitoringTrusted
        self.privateCapability = privateCapability
        self.privateDevices = privateDevices
        self.privateCapture = privateCapture
    }

    public init(diagnostics: PermissionDiagnostics) {
        self.init(
            accessibilityTrusted: diagnostics.accessibilityTrusted,
            inputMonitoringTrusted: diagnostics.inputMonitoringTrusted,
            privateCapability: PrivateMultitouchCapabilityState(
                frameworkAvailable: diagnostics.privateMultitouch.frameworkAvailable,
                requiredSymbolsAvailable: diagnostics.privateMultitouch.requiredSymbolsAvailable
            ),
            privateDevices: PrivateMultitouchDeviceState(
                availableDeviceCount: diagnostics.privateMultitouch.deviceCount
            ),
            privateCapture: PrivateMultitouchCaptureState(
                started: diagnostics.privateMultitouch.started,
                startedDeviceCount: diagnostics.privateMultitouch.startedDeviceCount,
                failedDeviceCount: diagnostics.privateMultitouch.failedDeviceCount,
                reason: diagnostics.privateMultitouch.reason
            )
        )
    }

    public static var unknown: PermissionStateSnapshot {
        PermissionStateSnapshot(
            accessibilityTrusted: false,
            inputMonitoringTrusted: false,
            privateCapability: PrivateMultitouchCapabilityState(
                frameworkAvailable: false,
                requiredSymbolsAvailable: false
            ),
            privateDevices: PrivateMultitouchDeviceState(availableDeviceCount: 0),
            privateCapture: PrivateMultitouchCaptureState(
                started: false,
                startedDeviceCount: 0,
                failedDeviceCount: 0,
                reason: "Private multitouch state has not been evaluated."
            )
        )
    }

    public var diagnostics: PermissionDiagnostics {
        PermissionDiagnostics(
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringTrusted: inputMonitoringTrusted,
            privateMultitouch: PrivateCaptureDiagnostics(
                frameworkAvailable: privateCapability.frameworkAvailable,
                requiredSymbolsAvailable: privateCapability.requiredSymbolsAvailable,
                deviceCount: privateDevices.availableDeviceCount,
                startedDeviceCount: privateCapture.startedDeviceCount,
                failedDeviceCount: privateCapture.failedDeviceCount,
                started: privateCapture.started,
                reason: privateCapture.reason
            )
        )
    }
}

/// A lock-backed permission cache. Reads never call TCC or private multitouch APIs.
/// Slow probes are explicit updates so window targeting can use the cached
/// Accessibility value without loading or inspecting MultitouchSupport.
public final class PermissionStateService: PermissionSnapshotProviding, @unchecked Sendable {
    public typealias PermissionProbe = @Sendable () -> Bool

    private let lock = NSLock()
    private let accessibilityProbe: PermissionProbe
    private let inputMonitoringProbe: PermissionProbe
    private var cachedState: PermissionStateSnapshot

    public init(
        initialState: PermissionStateSnapshot = .unknown,
        accessibilityProbe: @escaping PermissionProbe = { AXIsProcessTrusted() },
        inputMonitoringProbe: @escaping PermissionProbe = { CGPreflightListenEventAccess() }
    ) {
        cachedState = initialState
        self.accessibilityProbe = accessibilityProbe
        self.inputMonitoringProbe = inputMonitoringProbe
    }

    public func state() -> PermissionStateSnapshot {
        withLock { cachedState }
    }

    public func snapshot() -> PermissionDiagnostics {
        state().diagnostics
    }

    public func isAccessibilityTrusted() -> Bool {
        withLock { cachedState.accessibilityTrusted }
    }

    @discardableResult
    public func refreshSystemPermissions() -> PermissionStateSnapshot {
        let accessibilityTrusted = accessibilityProbe()
        let inputMonitoringTrusted = inputMonitoringProbe()

        return withLock {
            cachedState.accessibilityTrusted = accessibilityTrusted
            cachedState.inputMonitoringTrusted = inputMonitoringTrusted
            return cachedState
        }
    }

    @discardableResult
    public func updatePrivateCapability(
        frameworkAvailable: Bool,
        requiredSymbolsAvailable: Bool
    ) -> PermissionStateSnapshot {
        withLock {
            cachedState.privateCapability = PrivateMultitouchCapabilityState(
                frameworkAvailable: frameworkAvailable,
                requiredSymbolsAvailable: requiredSymbolsAvailable
            )
            return cachedState
        }
    }

    @discardableResult
    public func updatePrivateDevices(availableDeviceCount: Int) -> PermissionStateSnapshot {
        withLock {
            cachedState.privateDevices = PrivateMultitouchDeviceState(
                availableDeviceCount: max(0, availableDeviceCount)
            )
            return cachedState
        }
    }

    @discardableResult
    public func updatePrivateCapture(
        started: Bool,
        startedDeviceCount: Int,
        failedDeviceCount: Int,
        reason: String
    ) -> PermissionStateSnapshot {
        withLock {
            cachedState.privateCapture = PrivateMultitouchCaptureState(
                started: started,
                startedDeviceCount: max(0, startedDeviceCount),
                failedDeviceCount: max(0, failedDeviceCount),
                reason: reason
            )
            return cachedState
        }
    }

    @discardableResult
    public func updatePrivateMultitouch(_ diagnostics: PrivateCaptureDiagnostics) -> PermissionStateSnapshot {
        withLock {
            cachedState.privateCapability = PrivateMultitouchCapabilityState(
                frameworkAvailable: diagnostics.frameworkAvailable,
                requiredSymbolsAvailable: diagnostics.requiredSymbolsAvailable
            )
            cachedState.privateDevices = PrivateMultitouchDeviceState(
                availableDeviceCount: max(0, diagnostics.deviceCount)
            )
            cachedState.privateCapture = PrivateMultitouchCaptureState(
                started: diagnostics.started,
                startedDeviceCount: max(0, diagnostics.startedDeviceCount),
                failedDeviceCount: max(0, diagnostics.failedDeviceCount),
                reason: diagnostics.reason
            )
            return cachedState
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
