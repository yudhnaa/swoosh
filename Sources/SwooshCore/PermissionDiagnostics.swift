import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public enum PermissionKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case accessibility
    case inputMonitoring
    case privateMultitouch
}

public enum PermissionReadiness: Equatable, Sendable {
    case ready
    case blocked([PermissionRequirement])
}

public struct PermissionRequirement: Equatable, Sendable {
    public var kind: PermissionKind
    public var message: String
    public var settingsURL: URL?

    public init(kind: PermissionKind, message: String, settingsURL: URL? = nil) {
        self.kind = kind
        self.message = message
        self.settingsURL = settingsURL
    }
}

public struct PermissionDiagnostics: Equatable, Sendable {
    public var accessibilityTrusted: Bool
    public var inputMonitoringTrusted: Bool
    public var privateMultitouch: PrivateCaptureDiagnostics

    public init(
        accessibilityTrusted: Bool,
        inputMonitoringTrusted: Bool,
        privateMultitouch: PrivateCaptureDiagnostics
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringTrusted = inputMonitoringTrusted
        self.privateMultitouch = privateMultitouch
    }

    public var readiness: PermissionReadiness {
        var missing: [PermissionRequirement] = []
        if !accessibilityTrusted {
            missing.append(.accessibility)
        }
        if !inputMonitoringTrusted {
            missing.append(.inputMonitoring)
        }
        if !privateMultitouch.isUsable {
            missing.append(PermissionRequirement(
                kind: .privateMultitouch,
                message: privateMultitouch.reason
            ))
        }

        return missing.isEmpty ? .ready : .blocked(missing)
    }
}

public struct PrivateCaptureDiagnostics: Equatable, Sendable {
    public var frameworkAvailable: Bool
    public var requiredSymbolsAvailable: Bool
    public var deviceCount: Int
    public var startedDeviceCount: Int
    public var failedDeviceCount: Int
    public var started: Bool
    public var reason: String

    public init(
        frameworkAvailable: Bool,
        requiredSymbolsAvailable: Bool,
        deviceCount: Int,
        startedDeviceCount: Int = 0,
        failedDeviceCount: Int = 0,
        started: Bool,
        reason: String
    ) {
        self.frameworkAvailable = frameworkAvailable
        self.requiredSymbolsAvailable = requiredSymbolsAvailable
        self.deviceCount = deviceCount
        self.startedDeviceCount = startedDeviceCount
        self.failedDeviceCount = failedDeviceCount
        self.started = started
        self.reason = reason
    }

    public var isUsable: Bool {
        frameworkAvailable && requiredSymbolsAvailable && deviceCount > 0
    }

    public static var unavailable: PrivateCaptureDiagnostics {
        PrivateCaptureDiagnostics(
            frameworkAvailable: false,
            requiredSymbolsAvailable: false,
            deviceCount: 0,
            started: false,
            reason: "Private multitouch capture is unavailable."
        )
    }
}

public protocol PermissionSnapshotProviding {
    func snapshot() -> PermissionDiagnostics
    func isAccessibilityTrusted() -> Bool
}

public extension PermissionSnapshotProviding {
    func isAccessibilityTrusted() -> Bool {
        snapshot().accessibilityTrusted
    }
}

public struct SystemPermissionSnapshotProvider: PermissionSnapshotProviding {
    private let privateProbe: PrivateCaptureDiagnosing

    public init(privateProbe: PrivateCaptureDiagnosing = PrivateMultitouchRuntimeDiagnostics()) {
        self.privateProbe = privateProbe
    }

    public func snapshot() -> PermissionDiagnostics {
        PermissionDiagnostics(
            accessibilityTrusted: AXIsProcessTrusted(),
            inputMonitoringTrusted: CGPreflightListenEventAccess(),
            privateMultitouch: privateProbe.diagnostics()
        )
    }

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}

public protocol PrivateCaptureDiagnosing {
    func diagnostics() -> PrivateCaptureDiagnostics
}

public struct PrivateMultitouchRuntimeDiagnostics: PrivateCaptureDiagnosing {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private static let requiredSymbols = [
        "MTDeviceCreateList",
        "MTRegisterContactFrameCallback",
        "MTUnregisterContactFrameCallback",
        "MTDeviceStart",
        "MTDeviceStop",
        "MTDeviceIsBuiltIn",
        "MTDeviceGetDeviceID"
    ]

    public init() {}

    public func diagnostics() -> PrivateCaptureDiagnostics {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            return PrivateCaptureDiagnostics(
                frameworkAvailable: false,
                requiredSymbolsAvailable: false,
                deviceCount: 0,
                started: false,
                reason: "MultitouchSupport.framework could not be loaded."
            )
        }
        defer { dlclose(handle) }

        let missing = Self.requiredSymbols.filter { dlsym(handle, $0) == nil }
        guard missing.isEmpty else {
            return PrivateCaptureDiagnostics(
                frameworkAvailable: true,
                requiredSymbolsAvailable: false,
                deviceCount: 0,
                started: false,
                reason: "Required private multitouch symbols are missing."
            )
        }

        // Device enumeration is exclusively owned by the capture worker. This
        // probe reports capability only so permission refreshes can never race
        // MTDeviceCreateList against capture start or hot-plug reconciliation.
        return PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: 0,
            started: false,
            reason: "Private multitouch capture capability is available; device state is pending capture."
        )
    }
}

private extension PermissionRequirement {
    static var accessibility: PermissionRequirement {
        PermissionRequirement(
            kind: .accessibility,
            message: "Accessibility permission is required for window targeting.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        )
    }

    static var inputMonitoring: PermissionRequirement {
        PermissionRequirement(
            kind: .inputMonitoring,
            message: "Input Monitoring permission is required for global gesture capture.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        )
    }
}
