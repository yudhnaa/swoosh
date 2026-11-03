import AppKit
import ApplicationServices
import Foundation
import OSLog

public protocol DesktopSpaceDiagnosticsSession: AnyObject {
    func write(_ stage: String, details: [String: String])
    func capture(_ stage: String, plan: DesktopSpaceMovementEventPlan?)
}

public extension DesktopSpaceDiagnosticsSession {
    func write(_ stage: String) {
        write(stage, details: [:])
    }

    func capture(_ stage: String) {
        capture(stage, plan: nil)
    }
}

public protocol DesktopSpaceDiagnosticsSink {
    func makeSession(for target: WindowTargetIdentity) -> any DesktopSpaceDiagnosticsSession
}

/// The production default. It intentionally performs no AX queries, encoding, or logging.
public struct NoOpDesktopSpaceDiagnosticsSink: DesktopSpaceDiagnosticsSink {
    public init() {}

    public func makeSession(for target: WindowTargetIdentity) -> any DesktopSpaceDiagnosticsSession {
        NoOpDesktopSpaceDiagnosticsSession.shared
    }
}

private final class NoOpDesktopSpaceDiagnosticsSession: DesktopSpaceDiagnosticsSession, @unchecked Sendable {
    static let shared = NoOpDesktopSpaceDiagnosticsSession()

    func write(_ stage: String, details: [String: String]) {}
    func capture(_ stage: String, plan: DesktopSpaceMovementEventPlan?) {}
}

/// Opt-in system diagnostics. Read-only observations cannot prove Space membership.
/// Window titles, document contents, and URLs are deliberately excluded.
public struct SystemDesktopSpaceDiagnosticsSink: DesktopSpaceDiagnosticsSink {
    public init() {}

    public func makeSession(for target: WindowTargetIdentity) -> any DesktopSpaceDiagnosticsSession {
        DesktopSpaceMoveDiagnostics(target: target)
    }
}

final class DesktopSpaceMoveDiagnostics: DesktopSpaceDiagnosticsSession {
    private let id = UUID().uuidString
    private let target: WindowTargetIdentity
    private let application: AXUIElement
    private let window: AXUIElement?
    private let logger = Logger(subsystem: "com.yudhnaa.Swoosh", category: "DesktopSpaceMovement")
    private var previousFrame: CGRect?
    private var previousFocus: String?

    init(target: WindowTargetIdentity) {
        self.target = target
        application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.05)
        window = SystemDesktopSpaceTargetActivator().windowElement(for: target, in: application)
        if let window { AXUIElementSetMessagingTimeout(window, 0.05) }
    }

    func write(_ stage: String, details: [String: String]) {
        var record = details.filter { key, _ in
            let key = key.lowercased()
            return !key.contains("pid") &&
                !key.contains("application") &&
                !key.contains("bundle") &&
                !key.contains("point") &&
                !key.contains("pointer") &&
                !key.contains("frame") &&
                !key.hasPrefix("hit.")
        }
        record["stage"] = stage
        record["moveID"] = id
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        logger.info("\(line, privacy: .public)")
        FileHandle.standardError.write(Data("[swoosh-space] \(line)\n".utf8))
    }

    func capture(_ stage: String, plan: DesktopSpaceMovementEventPlan?) {
        var details: [String: String] = [:]
        var errors: [String: String] = [:]
        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if result != .success { errors[attribute] = String(result.rawValue) }
            return value
        }
        if let window {
            details["role"] = read(window, kAXRoleAttribute) as? String ?? "unknown"
            details["subrole"] = read(window, kAXSubroleAttribute) as? String ?? "unknown"
            let position = read(window, kAXPositionAttribute)
            let size = read(window, kAXSizeAttribute)
            if let frame = Self.frame(position: position, size: size) {
                details["frameAvailable"] = "true"
                if let previousFrame {
                    details["frameChanged"] = String(frame != previousFrame)
                }
                previousFrame = frame
            } else {
                details["frameAvailable"] = "false"
                previousFrame = nil
            }
        } else {
            details["windowResolved"] = "false"
        }
        if let focused = read(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            details["targetFocused"] = String(window.map { CFEqual($0, focused) } ?? false)
            let focusState = window.map { CFEqual($0, focused) ? "target" : "other" } ?? "unresolved"
            if let previousFocus { details["focusChanged"] = String(previousFocus != focusState) }
            previousFocus = focusState
        } else {
            details["focusAvailable"] = "false"
            previousFocus = nil
        }
        details["targetApplicationFrontmost"] = String(
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        )
        details["physicalFlags"] = String(CGEventSource.flagsState(.hidSystemState).rawValue)
        if let plan {
            var hit: AXUIElement?
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.05)
            let result = AXUIElementCopyElementAtPosition(system, Float(plan.mouseDownPoint.x), Float(plan.mouseDownPoint.y), &hit)
            details["hitTestAXError"] = String(result.rawValue)
            if let hit {
                AXUIElementSetMessagingTimeout(hit, 0.05)
                details["hitRole"] = read(hit, kAXRoleAttribute) as? String ?? "unknown"
                details["hitSubrole"] = read(hit, kAXSubroleAttribute) as? String ?? "unknown"
                if let hitWindow = read(hit, kAXWindowAttribute) {
                    details["hitTargetWindow"] = String(window.map { CFEqual($0, hitWindow) } ?? false)
                }
            }
        }
        for (attribute, error) in errors { details["error.\(attribute)"] = error }
        write(stage, details: details)
    }

    private static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
