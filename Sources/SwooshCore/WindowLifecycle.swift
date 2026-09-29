import AppKit
import ApplicationServices
import Foundation

public enum WindowLifecycleAction: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case minimize
    case requestClose
    case toggleFullscreen
}

public enum WindowLifecycleStatus: String, Codable, Equatable, Sendable {
    case performed
    case rejected
    case unsupported
    case targetLost
    case transitioning
}

public struct WindowLifecycleResult: Equatable, Sendable {
    public var action: WindowLifecycleAction
    public var status: WindowLifecycleStatus
    public var reason: String?

    public init(action: WindowLifecycleAction, status: WindowLifecycleStatus, reason: String? = nil) {
        self.action = action
        self.status = status
        self.reason = reason
    }
}

public protocol WindowLifecycleControlling {
    func isAlive(_ target: WindowTargetIdentity) -> Bool
    func supportedActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction>
    func perform(_ action: WindowLifecycleAction, for target: WindowTargetIdentity) -> WindowLifecycleResult
    func isFullscreen(_ target: WindowTargetIdentity) -> Bool?
}

public final class WindowLifecycleController {
    private struct FullscreenTransition {
        var startedAt: TimeInterval
        var expectedFullscreenState: Bool?
    }

    private let client: WindowLifecycleControlling
    private let transitionRecoveryInterval: TimeInterval
    private let clock: () -> TimeInterval
    private var transitioningFullscreenTargets: [WindowTargetIdentity: FullscreenTransition] = [:]

    public init(
        client: WindowLifecycleControlling,
        transitionRecoveryInterval: TimeInterval = 1.5,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.client = client
        self.transitionRecoveryInterval = transitionRecoveryInterval
        self.clock = clock
    }

    public func supportedActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction> {
        guard client.isAlive(target) else {
            return []
        }

        return client.supportedActions(for: target)
    }

    public func perform(_ action: WindowLifecycleAction, for target: WindowTargetIdentity) -> WindowLifecycleResult {
        guard client.isAlive(target) else {
            return WindowLifecycleResult(
                action: action,
                status: .targetLost,
                reason: "The target window is no longer available."
            )
        }

        if isFullscreenTransitioning(target) {
            return WindowLifecycleResult(
                action: action,
                status: .transitioning,
                reason: "The target window is already in a fullscreen transition."
            )
        }

        guard client.supportedActions(for: target).contains(action) else {
            return WindowLifecycleResult(
                action: action,
                status: .unsupported,
                reason: "The target window does not expose a supported control for \(action.rawValue)."
            )
        }

        let expectedFullscreenState = action == .toggleFullscreen
            ? client.isFullscreen(target).map { !$0 }
            : nil
        let result = client.perform(action, for: target)
        if action == .toggleFullscreen, result.status == .performed {
            transitioningFullscreenTargets[target] = FullscreenTransition(
                startedAt: clock(),
                expectedFullscreenState: expectedFullscreenState
            )
        }

        return result
    }

    public func guardGeometryCommand(for target: WindowTargetIdentity) -> WindowLifecycleResult? {
        guard isFullscreenTransitioning(target) else {
            return nil
        }

        return WindowLifecycleResult(
            action: .toggleFullscreen,
            status: .transitioning,
            reason: "Geometry commands are unavailable until the fullscreen transition finishes."
        )
    }

    public func finishFullscreenTransition(for target: WindowTargetIdentity) {
        transitioningFullscreenTargets.removeValue(forKey: target)
    }

    public func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        client.isFullscreen(target)
    }

    private func isFullscreenTransitioning(_ target: WindowTargetIdentity) -> Bool {
        guard let transition = transitioningFullscreenTargets[target] else {
            return false
        }

        guard client.isAlive(target) else {
            transitioningFullscreenTargets.removeValue(forKey: target)
            return false
        }

        if let expectedFullscreenState = transition.expectedFullscreenState,
           client.isFullscreen(target) == expectedFullscreenState {
            transitioningFullscreenTargets.removeValue(forKey: target)
            return false
        }

        if clock() - transition.startedAt >= transitionRecoveryInterval {
            transitioningFullscreenTargets.removeValue(forKey: target)
            return false
        }

        return true
    }
}

public struct SystemAccessibilityLifecycleClient: WindowLifecycleControlling {
    private let messagingTimeout: Float

    public init(messagingTimeout: Float = 2.0) {
        self.messagingTimeout = messagingTimeout
    }

    public func isAlive(_ target: WindowTargetIdentity) -> Bool {
        windowElement(for: target) != nil
    }

    public func supportedActions(for target: WindowTargetIdentity) -> Set<WindowLifecycleAction> {
        guard let window = windowElement(for: target) else {
            return []
        }

        var actions: Set<WindowLifecycleAction> = []
        if isAttributeSettable(kAXMinimizedAttribute, on: window) {
            actions.insert(.minimize)
        }
        if elementAttribute(kAXCloseButtonAttribute, from: window) != nil {
            actions.insert(.requestClose)
        }
        if isAttributeSettable("AXFullScreen", on: window) || elementAttribute(kAXFullScreenButtonAttribute, from: window) != nil {
            actions.insert(.toggleFullscreen)
        }

        return actions
    }

    public func perform(_ action: WindowLifecycleAction, for target: WindowTargetIdentity) -> WindowLifecycleResult {
        guard let window = windowElement(for: target) else {
            return WindowLifecycleResult(
                action: action,
                status: .targetLost,
                reason: "The target window is no longer available."
            )
        }

        switch action {
        case .minimize:
            guard isAttributeSettable(kAXMinimizedAttribute, on: window) else {
                return unsupported(action, reason: "The window does not allow AXMinimized to be changed.")
            }

            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return result == .success
                ? WindowLifecycleResult(action: action, status: .performed)
                : rejected(action, result: result, control: "AXMinimized")

        case .requestClose:
            guard let button = elementAttribute(kAXCloseButtonAttribute, from: window) else {
                return unsupported(action, reason: "The window does not expose an AXCloseButton.")
            }

            return press(button, action: action, control: "AXCloseButton")

        case .toggleFullscreen:
            if isAttributeSettable("AXFullScreen", on: window), let isFullscreen = boolAttribute("AXFullScreen", from: window) {
                let result = setBoolAttribute("AXFullScreen", value: !isFullscreen, on: window)
                return result == .success
                    ? WindowLifecycleResult(action: action, status: .performed)
                    : rejected(action, result: result, control: "AXFullScreen")
            }

            guard let button = elementAttribute(kAXFullScreenButtonAttribute, from: window) else {
                return unsupported(action, reason: "The window does not expose settable AXFullScreen or an AXFullScreenButton.")
            }

            return press(button, action: action, control: "AXFullScreenButton")
        }
    }

    public func isFullscreen(_ target: WindowTargetIdentity) -> Bool? {
        guard let window = windowElement(for: target) else {
            return nil
        }

        return boolAttribute("AXFullScreen", from: window)
    }

    private func press(_ button: AXUIElement, action: WindowLifecycleAction, control: String) -> WindowLifecycleResult {
        AXUIElementSetMessagingTimeout(button, messagingTimeout)
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        return result == .success
            ? WindowLifecycleResult(action: action, status: .performed)
            : rejected(action, result: result, control: control)
    }

    private func windowElement(for target: WindowTargetIdentity) -> AXUIElement? {
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        return windowCandidates(for: application).first { window in
            elementIdentifier(for: window, processIdentifier: target.processIdentifier) == target.elementIdentifier
        }
    }

    private func windowCandidates(for application: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        var rawWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
           let windows = rawWindows as? [AXUIElement] {
            candidates.append(contentsOf: windows)
        }

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var rawWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attribute as CFString, &rawWindow) == .success,
               let rawWindow,
               CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
                let window = rawWindow as! AXUIElement
                if !candidates.contains(where: { CFHash($0) == CFHash(window) }) {
                    candidates.append(window)
                }
            }
        }

        return candidates
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (rawValue as! AXUIElement)
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue
        else {
            return nil
        }

        if CFGetTypeID(rawValue) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((rawValue as! CFBoolean))
        }

        return rawValue as? Bool
    }

    private func setBoolAttribute(_ attribute: String, value: Bool, on element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private func unsupported(_ action: WindowLifecycleAction, reason: String) -> WindowLifecycleResult {
        WindowLifecycleResult(action: action, status: .unsupported, reason: reason)
    }

    private func rejected(_ action: WindowLifecycleAction, result: AXError, control: String) -> WindowLifecycleResult {
        WindowLifecycleResult(
            action: action,
            status: .rejected,
            reason: "\(control) returned \(result)."
        )
    }

    private func elementIdentifier(for element: AXUIElement, processIdentifier: pid_t) -> String {
        "pid:\(processIdentifier):element:\(CFHash(element))"
    }
}
