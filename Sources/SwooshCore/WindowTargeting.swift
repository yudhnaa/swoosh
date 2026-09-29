import AppKit
import ApplicationServices
import Foundation

public struct ScreenPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct AccessibilityElementSnapshot: Equatable, Sendable {
    public var processIdentifier: pid_t
    public var elementIdentifier: String
    public var role: String
    public var subrole: String?
    public var rolePath: [String]
    public var actions: Set<String>
    public var frame: GeometryRect?
    public var hitPoint: ScreenPoint?

    public init(
        processIdentifier: pid_t,
        elementIdentifier: String,
        role: String,
        subrole: String? = nil,
        rolePath: [String],
        actions: Set<String> = [],
        frame: GeometryRect? = nil,
        hitPoint: ScreenPoint? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.elementIdentifier = elementIdentifier
        self.role = role
        self.subrole = subrole
        self.rolePath = rolePath
        self.actions = actions
        self.frame = frame
        self.hitPoint = hitPoint
    }

    public var identity: WindowTargetIdentity {
        WindowTargetIdentity(processIdentifier: processIdentifier, elementIdentifier: elementIdentifier)
    }
}

public struct WindowTargetIdentity: Codable, Hashable, Sendable {
    public var processIdentifier: pid_t
    public var elementIdentifier: String

    public init(processIdentifier: pid_t, elementIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.elementIdentifier = elementIdentifier
    }
}

public enum WindowTargetSource: String, Codable, Equatable, Sendable {
    case pointerTitlebar
    case frontmostKeyboard
}

public struct WindowTarget: Equatable, Sendable {
    public var identity: WindowTargetIdentity
    public var source: WindowTargetSource
    public var rolePath: [String]
    public var availableActions: Set<String>

    public init(
        identity: WindowTargetIdentity,
        source: WindowTargetSource,
        rolePath: [String],
        availableActions: Set<String>
    ) {
        self.identity = identity
        self.source = source
        self.rolePath = rolePath
        self.availableActions = availableActions
    }

    public func requireAction(_ actionName: String) -> Result<Void, WindowTargetFailure> {
        availableActions.contains(actionName) ? .success(()) : .failure(.unsupported(actionName))
    }
}

public enum WindowTargetFailure: Error, Equatable, Sendable {
    case permissionDenied
    case noTarget
    case excludedSurface(String)
    case unsupported(String)
    case targetLost
}

public protocol AccessibilityTargetClient {
    func hitTest(at point: ScreenPoint) -> AccessibilityElementSnapshot?
    func frontmostWindow() -> AccessibilityElementSnapshot?
    func isAlive(_ identity: WindowTargetIdentity) -> Bool
}

public struct WindowTargetResolver {
    private let permissions: PermissionSnapshotProviding
    private let client: AccessibilityTargetClient
    private let classifier: WindowTargetClassifying

    public init(
        permissions: PermissionSnapshotProviding,
        client: AccessibilityTargetClient,
        classifier: WindowTargetClassifying = DefaultWindowTargetClassifier()
    ) {
        self.permissions = permissions
        self.client = client
        self.classifier = classifier
    }

    public func targetUnderPointer(at point: ScreenPoint) -> Result<WindowTarget, WindowTargetFailure> {
        guard permissions.snapshot().accessibilityTrusted else {
            return .failure(.permissionDenied)
        }

        guard var element = client.hitTest(at: point) else {
            return .failure(.noTarget)
        }

        element.hitPoint = point
        return classifier.classify(element, source: .pointerTitlebar)
    }

    public func targetUnderPointer(
        at point: ScreenPoint,
        fallingBackToFrontmost fallbackToFrontmost: Bool
    ) -> Result<WindowTarget, WindowTargetFailure> {
        let pointerResult = targetUnderPointer(at: point)
        guard fallbackToFrontmost,
              case .failure(.noTarget) = pointerResult
        else {
            return pointerResult
        }

        return frontmostPointerTitlebarTarget(at: point)
    }

    public func frontmostKeyboardTarget() -> Result<WindowTarget, WindowTargetFailure> {
        guard permissions.snapshot().accessibilityTrusted else {
            return .failure(.permissionDenied)
        }

        guard let element = client.frontmostWindow() else {
            return .failure(.noTarget)
        }

        return classifier.classify(element, source: .frontmostKeyboard)
    }

    private func frontmostPointerTitlebarTarget(at point: ScreenPoint) -> Result<WindowTarget, WindowTargetFailure> {
        guard permissions.snapshot().accessibilityTrusted else {
            return .failure(.permissionDenied)
        }

        guard var element = client.frontmostWindow() else {
            return .failure(.noTarget)
        }

        element.hitPoint = point
        return classifier.classify(element, source: .pointerTitlebar)
    }

    public func beginSession(with target: WindowTarget) -> WindowTargetSession {
        WindowTargetSession(identity: target.identity, client: client)
    }
}

public protocol WindowTargetClassifying {
    func classify(_ element: AccessibilityElementSnapshot, source: WindowTargetSource) -> Result<WindowTarget, WindowTargetFailure>
}

public struct DefaultWindowTargetClassifier: WindowTargetClassifying {
    private let excludedRoles: Set<String> = [
        "AXMenu",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXPopover",
        "AXSheet",
        "AXDialog",
        "AXDockItem"
    ]

    private let contentRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXScrollArea",
        "AXWebArea",
        "AXOutline",
        "AXTable"
    ]

    private let hardContentRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXScrollArea",
        "AXOutline",
        "AXTable"
    ]

    private let titlebarBandChromeRoles: Set<String> = [
        "AXButton",
        "AXGroup",
        "AXImage",
        "AXStaticText"
    ]

    public init() {}

    public func classify(_ element: AccessibilityElementSnapshot, source: WindowTargetSource) -> Result<WindowTarget, WindowTargetFailure> {
        if let excluded = element.rolePath.first(where: { excludedRoles.contains($0) }) {
            return .failure(.excludedSurface(excluded))
        }

        guard element.rolePath.contains("AXWindow") else {
            return .failure(.noTarget)
        }

        if source == .pointerTitlebar && !isTitlebarRelated(element) {
            return .failure(.excludedSurface(element.role))
        }

        return .success(WindowTarget(
            identity: element.identity,
            source: source,
            rolePath: element.rolePath,
            availableActions: element.actions
        ))
    }

    private func isTitlebarRelated(_ element: AccessibilityElementSnapshot) -> Bool {
        if ["AXTitleBar", "AXToolbar"].contains(element.role) {
            return true
        }

        guard let windowIndex = element.rolePath.firstIndex(of: "AXWindow") else {
            return false
        }

        let rolesBeforeWindow = element.rolePath[..<windowIndex]
        if rolesBeforeWindow.contains(where: { $0 == "AXToolbar" || $0 == "AXTitleBar" }) {
            return true
        }

        let pointerInTitlebarBand = isPointerInTitlebarBand(element)

        if hardContentRoles.contains(element.role) || element.rolePath.contains(where: { hardContentRoles.contains($0) }) {
            return false
        }

        if titlebarBandChromeRoles.contains(element.role), pointerInTitlebarBand {
            return true
        }

        if contentRoles.contains(element.role) || element.rolePath.contains(where: { contentRoles.contains($0) }) {
            return false
        }

        if element.role == "AXWindow" {
            return pointerInTitlebarBand
        }

        return pointerInTitlebarBand && rolesBeforeWindow.contains { role in
            role == "AXButton" || role == "AXToolbar" || role == "AXTitleBar"
        }
    }

    private func isPointerInTitlebarBand(_ element: AccessibilityElementSnapshot) -> Bool {
        guard let frame = element.frame, let point = element.hitPoint else {
            return false
        }

        let titlebarHeight = min(max(frame.height * 0.10, 28), 72)
        return point.x >= frame.x
            && point.x <= frame.maxX
            && point.y >= frame.y
            && point.y <= frame.y + titlebarHeight
    }
}

public final class WindowTargetSession {
    private let identity: WindowTargetIdentity
    private let client: AccessibilityTargetClient

    public init(identity: WindowTargetIdentity, client: AccessibilityTargetClient) {
        self.identity = identity
        self.client = client
    }

    public func requireLiveTarget() -> Result<WindowTargetIdentity, WindowTargetFailure> {
        client.isAlive(identity) ? .success(identity) : .failure(.targetLost)
    }
}

public struct SystemAccessibilityTargetClient: AccessibilityTargetClient {
    private let messagingTimeout: Float

    public init(messagingTimeout: Float = 2.0) {
        self.messagingTimeout = messagingTimeout
    }

    public func hitTest(at point: ScreenPoint) -> AccessibilityElementSnapshot? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var rawElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &rawElement)
        guard result == .success, let rawElement else {
            return nil
        }

        return snapshot(from: rawElement)
    }

    public func frontmostWindow() -> AccessibilityElementSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var rawWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawWindow)
        guard result == .success,
              let rawWindow,
              let windowElement = axElement(from: rawWindow)
        else {
            return nil
        }

        return snapshot(from: windowElement)
    }

    public func isAlive(_ identity: WindowTargetIdentity) -> Bool {
        let appElement = AXUIElementCreateApplication(identity.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        return windowCandidates(for: appElement).contains { element in
            elementIdentifier(for: element, processIdentifier: identity.processIdentifier) == identity.elementIdentifier
        }
    }

    private func windowCandidates(for appElement: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        var rawWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows) == .success,
           let windows = rawWindows as? [AXUIElement] {
            candidates.append(contentsOf: windows)
        }

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var rawWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, attribute as CFString, &rawWindow) == .success,
               let rawWindow,
               let window = axElement(from: rawWindow),
               !candidates.contains(where: { CFHash($0) == CFHash(window) }) {
                candidates.append(window)
            }
        }

        return candidates
    }

    private func snapshot(from element: AXUIElement) -> AccessibilityElementSnapshot? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? "unknown"
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let rolePath = rolePath(from: element)
        let targetElement = windowAncestor(from: element) ?? element
        let actions = actionNames(from: targetElement)
        let frame = frameAttribute(from: targetElement)

        return AccessibilityElementSnapshot(
            processIdentifier: pid,
            elementIdentifier: elementIdentifier(for: targetElement, processIdentifier: pid),
            role: role,
            subrole: subrole,
            rolePath: rolePath,
            actions: actions,
            frame: frame
        )
    }

    private func rolePath(from element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element

        for _ in 0..<12 {
            guard let currentElement = current else {
                break
            }

            if let role = stringAttribute(kAXRoleAttribute, from: currentElement) {
                roles.append(role)
            }

            var rawParent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &rawParent) == .success,
                  let parent = rawParent,
                  let parentElement = axElement(from: parent)
            else {
                break
            }

            current = parentElement
        }

        return roles
    }

    private func windowAncestor(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element

        for _ in 0..<12 {
            guard let currentElement = current else {
                return nil
            }

            if stringAttribute(kAXRoleAttribute, from: currentElement) == "AXWindow" {
                return currentElement
            }

            var rawParent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &rawParent) == .success,
                  let parent = rawParent,
                  let parentElement = axElement(from: parent)
            else {
                return nil
            }

            current = parentElement
        }

        return nil
    }

    private func actionNames(from element: AXUIElement) -> Set<String> {
        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(element, &rawActions) == .success,
              let actions = rawActions as? [String]
        else {
            return []
        }

        return Set(actions)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }

        return rawValue as? String
    }

    private func frameAttribute(from element: AXUIElement) -> GeometryRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition,
              let rawSize
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID(),
              AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return GeometryRect(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    private func elementIdentifier(for element: AXUIElement, processIdentifier: pid_t) -> String {
        "pid:\(processIdentifier):element:\(CFHash(element))"
    }

    private func axElement(from value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }
}
