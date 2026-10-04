import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

public enum DesktopSpaceMoveDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum DesktopSpaceMovementStatus: String, Codable, Equatable, Sendable {
    case performed
    case unavailable
    case failed
}

public struct DesktopSpaceMovementResult: Equatable, Sendable {
    public var status: DesktopSpaceMovementStatus
    public var reason: String?

    public init(status: DesktopSpaceMovementStatus, reason: String? = nil) {
        self.status = status
        self.reason = reason
    }
}

struct DesktopSpaceTargetActivationResult: Equatable {
    var succeeded: Bool
    var reason: String?

    static var success: DesktopSpaceTargetActivationResult {
        DesktopSpaceTargetActivationResult(succeeded: true, reason: nil)
    }

    static func failed(_ reason: String) -> DesktopSpaceTargetActivationResult {
        DesktopSpaceTargetActivationResult(succeeded: false, reason: reason)
    }
}

protocol DesktopSpaceTargetActivating {
    func activate(_ target: WindowTargetIdentity) -> DesktopSpaceTargetActivationResult
}

public protocol DesktopSpaceMoving {
    func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) -> DesktopSpaceMovementResult
}

public struct DesktopSpaceMovementEventPlan: Equatable, Sendable {
    public var mouseDownPoint: CGPoint
    public var dragPoint: CGPoint
    public var keyCode: CGKeyCode
    public var controlKeyCode: CGKeyCode
    public var eventSourceStateID: CGEventSourceStateID
    public var eventTap: CGEventTapLocation
    public var controlEventFlags: CGEventFlags
    public var arrowEventFlags: CGEventFlags
    public var mouseDownToDragDelaySeconds: TimeInterval
    public var dragToKeyDelaySeconds: TimeInterval
    public var controlToArrowDelaySeconds: TimeInterval
    public var keyToMouseUpDelaySeconds: TimeInterval

    public init(
        mouseDownPoint: CGPoint,
        dragPoint: CGPoint,
        keyCode: CGKeyCode,
        controlKeyCode: CGKeyCode,
        eventSourceStateID: CGEventSourceStateID,
        eventTap: CGEventTapLocation,
        controlEventFlags: CGEventFlags,
        arrowEventFlags: CGEventFlags,
        mouseDownToDragDelaySeconds: TimeInterval,
        dragToKeyDelaySeconds: TimeInterval,
        controlToArrowDelaySeconds: TimeInterval,
        keyToMouseUpDelaySeconds: TimeInterval
    ) {
        self.mouseDownPoint = mouseDownPoint
        self.dragPoint = dragPoint
        self.keyCode = keyCode
        self.controlKeyCode = controlKeyCode
        self.eventSourceStateID = eventSourceStateID
        self.eventTap = eventTap
        self.controlEventFlags = controlEventFlags
        self.arrowEventFlags = arrowEventFlags
        self.mouseDownToDragDelaySeconds = mouseDownToDragDelaySeconds
        self.dragToKeyDelaySeconds = dragToKeyDelaySeconds
        self.controlToArrowDelaySeconds = controlToArrowDelaySeconds
        self.keyToMouseUpDelaySeconds = keyToMouseUpDelaySeconds
    }
}

public struct MissionControlDesktopSpaceMover: DesktopSpaceMoving {
    public static let titlebarYOffset: CGFloat = 10
    public static let mouseDownToDragDelaySeconds: TimeInterval = 0.08
    public static let dragToKeyDelaySeconds: TimeInterval = 0.08
    public static let controlToArrowDelaySeconds: TimeInterval = 0.05
    public static let keyToMouseUpDelaySeconds: TimeInterval = 0.45
    public static let targetActivationDelaySeconds: TimeInterval = 0.08
    public static let eventSourceStateID: CGEventSourceStateID = .hidSystemState
    public static let eventTap: CGEventTapLocation = .cghidEventTap
    public static let controlEventFlags: CGEventFlags = .maskControl
    public static let arrowEventFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

    private let coordinateConverter = CoordinateConverter()
    private let targetActivator: DesktopSpaceTargetActivating

    public init() {
        targetActivator = SystemDesktopSpaceTargetActivator()
    }

    init(targetActivator: DesktopSpaceTargetActivating) {
        self.targetActivator = targetActivator
    }

    public func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) -> DesktopSpaceMovementResult {
        guard direction == .left || direction == .right else {
            return DesktopSpaceMovementResult(
                status: .unavailable,
                reason: "Desktop Spaces movement supports left and right directions only."
            )
        }

        let activation = targetActivator.activate(target)
        guard activation.succeeded else {
            return DesktopSpaceMovementResult(
                status: .unavailable,
                reason: activation.reason ?? "Could not activate the target window for Desktop Spaces movement."
            )
        }
        Thread.sleep(forTimeInterval: Self.targetActivationDelaySeconds)

        let plan = eventPlan(forAppKitFrame: frame, desktopTopY: desktopTopY, direction: direction)
        guard let source = CGEventSource(stateID: plan.eventSourceStateID),
              let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: plan.mouseDownPoint,
                mouseButton: .left
              ),
              let mouseDrag = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: plan.dragPoint,
                mouseButton: .left
              ),
              let controlDown = CGEvent(keyboardEventSource: source, virtualKey: plan.controlKeyCode, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: plan.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: plan.keyCode, keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: source, virtualKey: plan.controlKeyCode, keyDown: false),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: plan.dragPoint,
                mouseButton: .left
              )
        else {
            return DesktopSpaceMovementResult(
                status: .failed,
                reason: "Could not create Desktop Spaces target-window event sequence."
            )
        }

        mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDrag.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
        controlDown.type = .flagsChanged
        controlDown.flags = plan.controlEventFlags
        keyDown.flags = plan.arrowEventFlags
        keyUp.flags = plan.arrowEventFlags
        controlUp.type = .flagsChanged
        controlUp.flags = []

        mouseDown.post(tap: plan.eventTap)
        Thread.sleep(forTimeInterval: plan.mouseDownToDragDelaySeconds)
        mouseDrag.post(tap: plan.eventTap)
        Thread.sleep(forTimeInterval: plan.dragToKeyDelaySeconds)
        controlDown.post(tap: plan.eventTap)
        Thread.sleep(forTimeInterval: plan.controlToArrowDelaySeconds)
        keyDown.post(tap: plan.eventTap)
        keyUp.post(tap: plan.eventTap)
        Thread.sleep(forTimeInterval: plan.keyToMouseUpDelaySeconds)
        mouseUp.post(tap: plan.eventTap)
        controlUp.post(tap: plan.eventTap)

        return DesktopSpaceMovementResult(status: .performed)
    }

    func eventPlan(
        forAppKitFrame frame: GeometryRect,
        desktopTopY: Double,
        direction: DesktopSpaceMoveDirection
    ) -> DesktopSpaceMovementEventPlan {
        let accessibilityFrame = coordinateConverter.appKitToAccessibility(frame, desktopTopY: desktopTopY)
        return eventPlan(forAccessibilityFrame: accessibilityFrame, direction: direction)
    }

    func eventPlan(
        forAccessibilityFrame frame: GeometryRect,
        direction: DesktopSpaceMoveDirection
    ) -> DesktopSpaceMovementEventPlan {
        let mouseDownPoint = CGPoint(
            x: frame.x + frame.width / 2,
            y: frame.y + Double(Self.titlebarYOffset)
        )
        return DesktopSpaceMovementEventPlan(
            mouseDownPoint: mouseDownPoint,
            dragPoint: mouseDownPoint,
            keyCode: direction == .left ? CGKeyCode(kVK_LeftArrow) : CGKeyCode(kVK_RightArrow),
            controlKeyCode: CGKeyCode(kVK_Control),
            eventSourceStateID: Self.eventSourceStateID,
            eventTap: Self.eventTap,
            controlEventFlags: Self.controlEventFlags,
            arrowEventFlags: Self.arrowEventFlags,
            mouseDownToDragDelaySeconds: Self.mouseDownToDragDelaySeconds,
            dragToKeyDelaySeconds: Self.dragToKeyDelaySeconds,
            controlToArrowDelaySeconds: Self.controlToArrowDelaySeconds,
            keyToMouseUpDelaySeconds: Self.keyToMouseUpDelaySeconds
        )
    }
}

private final class SystemDesktopSpaceTargetActivator: DesktopSpaceTargetActivating {
    private let messagingTimeout: Float

    init(messagingTimeout: Float = 2.0) {
        self.messagingTimeout = messagingTimeout
    }

    func activate(_ target: WindowTargetIdentity) -> DesktopSpaceTargetActivationResult {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return .failed("Could not resolve the target application for Desktop Spaces movement.")
        }

        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let window = windowElement(for: target, in: appElement) else {
            return .failed("Could not resolve the target window for Desktop Spaces movement.")
        }

        let appActivated = app.activate(options: [.activateAllWindows])
        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)

        guard appActivated || raiseResult == .success || focusResult == .success else {
            return .failed("Could not activate or raise the target window for Desktop Spaces movement.")
        }

        return .success
    }

    private func windowElement(for target: WindowTargetIdentity, in appElement: AXUIElement) -> AXUIElement? {
        windowCandidates(for: appElement).first {
            elementIdentifier(for: $0, processIdentifier: target.processIdentifier) == target.elementIdentifier
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
               CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
                let window = rawWindow as! AXUIElement
                if !candidates.contains(where: { CFHash($0) == CFHash(window) }) {
                    candidates.append(window)
                }
            }
        }

        return candidates
    }

    private func elementIdentifier(for element: AXUIElement, processIdentifier: pid_t) -> String {
        "pid:\(processIdentifier):element:\(CFHash(element))"
    }
}
