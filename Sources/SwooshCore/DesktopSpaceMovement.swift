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
    var diagnostics: [String: String] = [:]

    static var success: DesktopSpaceTargetActivationResult {
        DesktopSpaceTargetActivationResult(succeeded: true, reason: nil)
    }

    static func failed(_ reason: String) -> DesktopSpaceTargetActivationResult {
        DesktopSpaceTargetActivationResult(succeeded: false, reason: reason)
    }
}

protocol DesktopSpaceTargetActivating {
    func activate(_ target: WindowTargetIdentity) -> DesktopSpaceTargetActivationResult
    func dragPoint(for target: WindowTargetIdentity, defaultPoint: CGPoint, direction: DesktopSpaceMoveDirection) -> DesktopSpaceDragPointResult
}

struct DesktopSpaceDragPointResult {
    var point: CGPoint?
    var reason: String
    var diagnostics: [String: String] = [:]
}

extension DesktopSpaceTargetActivating {
    func dragPoint(for target: WindowTargetIdentity, defaultPoint: CGPoint, direction: DesktopSpaceMoveDirection) -> DesktopSpaceDragPointResult {
        DesktopSpaceDragPointResult(point: defaultPoint, reason: "standardTitlebar")
    }
}

public protocol DesktopSpaceMoving {
    func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) async -> DesktopSpaceMovementResult

    func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) -> DesktopSpaceMovementResult
}

public extension DesktopSpaceMoving {
    func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) async -> DesktopSpaceMovementResult {
        let syncMove: (WindowTargetIdentity, GeometryRect, DesktopSpaceMoveDirection, Double) -> DesktopSpaceMovementResult = self.moveWindow
        return syncMove(target, frame, direction, desktopTopY)
    }
}

public struct DesktopSpaceTimingProfile: Equatable, Sendable {
    public var targetActivationDelaySeconds: TimeInterval
    public var mouseDownToDragDelaySeconds: TimeInterval
    public var dragToKeyDelaySeconds: TimeInterval
    public var controlToArrowDelaySeconds: TimeInterval
    public var keyToMouseUpDelaySeconds: TimeInterval

    public init(
        targetActivationDelaySeconds: TimeInterval,
        mouseDownToDragDelaySeconds: TimeInterval,
        dragToKeyDelaySeconds: TimeInterval,
        controlToArrowDelaySeconds: TimeInterval,
        keyToMouseUpDelaySeconds: TimeInterval
    ) {
        self.targetActivationDelaySeconds = targetActivationDelaySeconds
        self.mouseDownToDragDelaySeconds = mouseDownToDragDelaySeconds
        self.dragToKeyDelaySeconds = dragToKeyDelaySeconds
        self.controlToArrowDelaySeconds = controlToArrowDelaySeconds
        self.keyToMouseUpDelaySeconds = keyToMouseUpDelaySeconds
    }

    public static let missionControlDefault = DesktopSpaceTimingProfile(
        targetActivationDelaySeconds: 0.08,
        mouseDownToDragDelaySeconds: 0.08,
        dragToKeyDelaySeconds: 0.08,
        controlToArrowDelaySeconds: 0.05,
        keyToMouseUpDelaySeconds: 0.45
    )
}

protocol DesktopSpaceTiming {
    func wait(for duration: TimeInterval, isCancelled: () -> Bool) throws
}

struct SystemDesktopSpaceTiming: DesktopSpaceTiming {
    func wait(for duration: TimeInterval, isCancelled: () -> Bool) throws {
        var remaining = max(0, duration)
        while remaining > 0 {
            try DesktopSpaceMoveCancellation.check(isCancelled)
            let interval = min(remaining, 0.01)
            Thread.sleep(forTimeInterval: interval)
            remaining -= interval
        }
        try DesktopSpaceMoveCancellation.check(isCancelled)
    }
}

private final class DesktopSpaceMoveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    static func check(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw DesktopSpaceMoveExecutionError.cancelled }
    }
}

final class DesktopSpaceMoveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isMoving = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isMoving else { return false }
        isMoving = true
        return true
    }

    func end() {
        lock.lock()
        isMoving = false
        lock.unlock()
    }
}

private enum DesktopSpaceMoveExecutionError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: "Desktop Spaces movement was cancelled."
        }
    }
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

public struct MissionControlDesktopSpaceMover: DesktopSpaceMoving, @unchecked Sendable {
    public static let titlebarYOffset: CGFloat = 10
    public static let carryDragDistance: CGFloat = 2
    public static let mouseDownToDragDelaySeconds = DesktopSpaceTimingProfile.missionControlDefault.mouseDownToDragDelaySeconds
    public static let dragToKeyDelaySeconds = DesktopSpaceTimingProfile.missionControlDefault.dragToKeyDelaySeconds
    public static let controlToArrowDelaySeconds = DesktopSpaceTimingProfile.missionControlDefault.controlToArrowDelaySeconds
    public static let keyToMouseUpDelaySeconds = DesktopSpaceTimingProfile.missionControlDefault.keyToMouseUpDelaySeconds
    public static let targetActivationDelaySeconds = DesktopSpaceTimingProfile.missionControlDefault.targetActivationDelaySeconds
    public static let eventSourceStateID: CGEventSourceStateID = .hidSystemState
    public static let eventTap: CGEventTapLocation = .cghidEventTap
    public static let controlEventFlags: CGEventFlags = .maskControl
    public static let arrowEventFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

    private let coordinateConverter = CoordinateConverter()
    private let targetActivator: DesktopSpaceTargetActivating
    private let postEvent: (CGEvent, CGEventTapLocation) throws -> Void
    private let timing: any DesktopSpaceTiming
    private let timingProfile: DesktopSpaceTimingProfile
    private let diagnosticsSink: any DesktopSpaceDiagnosticsSink
    private let gate: DesktopSpaceMoveGate

    public init(
        timingProfile: DesktopSpaceTimingProfile = .missionControlDefault,
        diagnosticsSink: any DesktopSpaceDiagnosticsSink = NoOpDesktopSpaceDiagnosticsSink()
    ) {
        self.init(
            targetActivator: SystemDesktopSpaceTargetActivator(),
            timingProfile: timingProfile,
            diagnosticsSink: diagnosticsSink
        )
    }

    init(
        targetActivator: DesktopSpaceTargetActivating,
        timingProfile: DesktopSpaceTimingProfile = .missionControlDefault,
        timing: any DesktopSpaceTiming = SystemDesktopSpaceTiming(),
        diagnosticsSink: any DesktopSpaceDiagnosticsSink = NoOpDesktopSpaceDiagnosticsSink(),
        gate: DesktopSpaceMoveGate = DesktopSpaceMoveGate(),
        postEvent: @escaping (CGEvent, CGEventTapLocation) throws -> Void = { $0.post(tap: $1) }
    ) {
        self.targetActivator = targetActivator
        self.timingProfile = timingProfile
        self.timing = timing
        self.diagnosticsSink = diagnosticsSink
        self.gate = gate
        self.postEvent = postEvent
    }

    public func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) async -> DesktopSpaceMovementResult {
        await moveWindowAsync(
            target: target,
            frame: frame,
            direction: direction,
            desktopTopY: desktopTopY
        )
    }

    public func moveWindow(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) -> DesktopSpaceMovementResult {
        executeMove(
            target: target,
            frame: frame,
            direction: direction,
            desktopTopY: desktopTopY,
            cancellation: DesktopSpaceMoveCancellation()
        )
    }

    /// Nonblocking compatibility entry point for callers that can adopt async dispatch.
    /// The current `DesktopSpaceMoving` dispatcher contract remains synchronous.
    public func moveWindowAsync(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double
    ) async -> DesktopSpaceMovementResult {
        let cancellation = DesktopSpaceMoveCancellation()
        if Task.isCancelled { cancellation.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: executeMove(
                        target: target,
                        frame: frame,
                        direction: direction,
                        desktopTopY: desktopTopY,
                        cancellation: cancellation
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func executeMove(
        target: WindowTargetIdentity,
        frame: GeometryRect,
        direction: DesktopSpaceMoveDirection,
        desktopTopY: Double,
        cancellation: DesktopSpaceMoveCancellation
    ) -> DesktopSpaceMovementResult {
        guard direction == .left || direction == .right else {
            return DesktopSpaceMovementResult(
                status: .unavailable,
                reason: "Desktop Spaces movement supports left and right directions only."
            )
        }
        guard gate.begin() else {
            return DesktopSpaceMovementResult(
                status: .unavailable,
                reason: "A Desktop Spaces movement is already in progress."
            )
        }
        defer { gate.end() }

        let diagnostics = diagnosticsSink.makeSession(for: target)
        diagnostics.capture("beforeActivation")
        let activation = targetActivator.activate(target)
        diagnostics.write("activation", details: activation.diagnostics.merging([
            "succeeded": String(activation.succeeded), "reason": activation.reason ?? "none"
        ]) { _, new in new })
        guard activation.succeeded else {
            return DesktopSpaceMovementResult(
                status: .unavailable,
                reason: activation.reason ?? "Could not activate the target window for Desktop Spaces movement."
            )
        }
        do {
            try timing.wait(for: timingProfile.targetActivationDelaySeconds, isCancelled: cancellation.isCancelled)
        } catch {
            diagnostics.write("cancelledBeforeMouseDown", details: ["reason": error.localizedDescription])
            return DesktopSpaceMovementResult(status: .failed, reason: error.localizedDescription)
        }

        var plan = eventPlan(forAppKitFrame: frame, desktopTopY: desktopTopY, direction: direction)
        diagnostics.capture("baselineTitlebar", plan: plan)
        let origin = targetActivator.dragPoint(for: target, defaultPoint: plan.mouseDownPoint, direction: direction)
        diagnostics.write("dragPointResolution", details: origin.diagnostics.merging([
            "baselinePoint": NSStringFromPoint(plan.mouseDownPoint),
            "selectedPoint": origin.point.map(NSStringFromPoint) ?? "unavailable",
            "reason": origin.reason
        ]) { _, new in new })
        guard let point = origin.point else {
            return DesktopSpaceMovementResult(status: .unavailable, reason: origin.reason)
        }
        plan.dragPoint = CGPoint(x: point.x + plan.dragPoint.x - plan.mouseDownPoint.x, y: point.y)
        plan.mouseDownPoint = point
        diagnostics.capture("beforeMouseDown", plan: plan)
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

        diagnostics.write("mouseEvents", details: [
            "downFlags": String(mouseDown.flags.rawValue),
            "dragFlags": String(mouseDrag.flags.rawValue),
            "dragDeltaX": String(mouseDrag.getIntegerValueField(.mouseEventDeltaX)),
            "dragDeltaY": String(mouseDrag.getIntegerValueField(.mouseEventDeltaY))
        ])
        do {
            try performHeldMouseSequence(
                plan: plan,
                mouseDown: mouseDown,
                mouseDrag: mouseDrag,
                controlDown: controlDown,
                keyDown: keyDown,
                keyUp: keyUp,
                mouseUp: mouseUp,
                controlUp: controlUp,
                cancellation: cancellation
            )
        } catch {
            // performHeldMouseSequence releases any held mouse/control state before returning.
            diagnostics.write("sequenceFailedAfterRelease", details: ["reason": error.localizedDescription])
            diagnostics.capture("afterRelease", plan: plan)
            return DesktopSpaceMovementResult(status: .failed, reason: error.localizedDescription)
        }
        diagnostics.capture("afterRelease", plan: plan)

        return DesktopSpaceMovementResult(status: .performed)
    }

    private func performHeldMouseSequence(
        plan: DesktopSpaceMovementEventPlan,
        mouseDown: CGEvent,
        mouseDrag: CGEvent,
        controlDown: CGEvent,
        keyDown: CGEvent,
        keyUp: CGEvent,
        mouseUp: CGEvent,
        controlUp: CGEvent,
        cancellation: DesktopSpaceMoveCancellation
    ) throws {
        var mouseIsHeld = false
        var controlIsHeld = false
        defer {
            if mouseIsHeld { try? postEvent(mouseUp, plan.eventTap) }
            if controlIsHeld { try? postEvent(controlUp, plan.eventTap) }
        }

        try DesktopSpaceMoveCancellation.check(cancellation.isCancelled)
        try postEvent(mouseDown, plan.eventTap)
        mouseIsHeld = true
        try timing.wait(for: plan.mouseDownToDragDelaySeconds, isCancelled: cancellation.isCancelled)
        try postEvent(mouseDrag, plan.eventTap)
        try timing.wait(for: plan.dragToKeyDelaySeconds, isCancelled: cancellation.isCancelled)
        try postEvent(controlDown, plan.eventTap)
        controlIsHeld = true
        try timing.wait(for: plan.controlToArrowDelaySeconds, isCancelled: cancellation.isCancelled)
        try postEvent(keyDown, plan.eventTap)
        try postEvent(keyUp, plan.eventTap)
        try timing.wait(for: plan.keyToMouseUpDelaySeconds, isCancelled: cancellation.isCancelled)
        try postEvent(mouseUp, plan.eventTap)
        mouseIsHeld = false
        try postEvent(controlUp, plan.eventTap)
        controlIsHeld = false
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
        let dragDelta = direction == .left ? -Self.carryDragDistance : Self.carryDragDistance
        let dragPoint = CGPoint(
            x: mouseDownPoint.x + dragDelta,
            y: mouseDownPoint.y
        )
        return DesktopSpaceMovementEventPlan(
            mouseDownPoint: mouseDownPoint,
            dragPoint: dragPoint,
            keyCode: direction == .left ? CGKeyCode(kVK_LeftArrow) : CGKeyCode(kVK_RightArrow),
            controlKeyCode: CGKeyCode(kVK_Control),
            eventSourceStateID: Self.eventSourceStateID,
            eventTap: Self.eventTap,
            controlEventFlags: Self.controlEventFlags,
            arrowEventFlags: Self.arrowEventFlags,
            mouseDownToDragDelaySeconds: timingProfile.mouseDownToDragDelaySeconds,
            dragToKeyDelaySeconds: timingProfile.dragToKeyDelaySeconds,
            controlToArrowDelaySeconds: timingProfile.controlToArrowDelaySeconds,
            keyToMouseUpDelaySeconds: timingProfile.keyToMouseUpDelaySeconds
        )
    }
}

final class SystemDesktopSpaceTargetActivator: DesktopSpaceTargetActivating {
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
        let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let details = [
            "appActivated": String(appActivated), "raiseAXError": String(raiseResult.rawValue),
            "focusAXError": String(focusResult.rawValue), "mainAXError": String(mainResult.rawValue)
        ]

        guard appActivated || raiseResult == .success || focusResult == .success else {
            return DesktopSpaceTargetActivationResult(
                succeeded: false,
                reason: "Could not activate or raise the target window for Desktop Spaces movement.",
                diagnostics: details
            )
        }

        return DesktopSpaceTargetActivationResult(succeeded: true, diagnostics: details)
    }

    func dragPoint(for target: WindowTargetIdentity, defaultPoint: CGPoint, direction: DesktopSpaceMoveDirection) -> DesktopSpaceDragPointResult {
        let bundleID = NSRunningApplication(processIdentifier: target.processIdentifier)?.bundleIdentifier
        guard bundleID == "com.microsoft.VSCode" || bundleID == "com.brave.Browser" else {
            return DesktopSpaceDragPointResult(point: defaultPoint, reason: "standardTitlebar")
        }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let window = windowElement(for: target, in: application),
              let frame = DesktopSpaceDragPointSelector.frame(of: window) else {
            return DesktopSpaceDragPointResult(point: nil, reason: "Could not read the target's custom titlebar geometry.")
        }
        let buttons = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute].compactMap {
            DesktopSpaceDragPointSelector.elementAttribute($0, of: window)
        }.compactMap { DesktopSpaceDragPointSelector.frame(of: $0) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hits: [String: String] = [:]
        let point = DesktopSpaceDragPointSelector.select(
            frame: frame, defaultPoint: defaultPoint, buttons: buttons, direction: direction
        ) { point in
            var hit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
            let key = "hit.\(NSStringFromPoint(point))"
            hits[key] = "AXError=\(result.rawValue)"
            guard result == .success,
                  let hit else { return false }
            var role: CFTypeRef?
            AXUIElementSetMessagingTimeout(hit, 0.1)
            AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
            let roleName = role as? String ?? "unknown"
            let belongsToTargetWindow = belongsToWindow(hit, targetWindow: window)
            var rawActions: CFArray?
            let actionResult = AXUIElementCopyActionNames(hit, &rawActions)
            let actions = actionResult == .success ? Set((rawActions as? [String]) ?? []) : []
            let eligible = DesktopSpaceDragPointSelector.isEligibleCustomTitlebarHit(
                role: roleName,
                actions: actions,
                belongsToTargetWindow: belongsToTargetWindow
            )
            hits[key] = "role=\(roleName),targetWindow=\(belongsToTargetWindow),eligible=\(eligible)"
            return eligible
        }
        return DesktopSpaceDragPointResult(
            point: point,
            reason: point == nil ? "No accessible window background was found in the custom titlebar." : "AXWindowBackground",
            diagnostics: hits
        )
    }

    private func belongsToWindow(_ element: AXUIElement, targetWindow: AXUIElement) -> Bool {
        if CFEqual(element, targetWindow) {
            return true
        }

        var rawWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &rawWindow) == .success,
           let rawWindow,
           CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
           CFEqual(rawWindow, targetWindow) {
            return true
        }

        var ancestor = element
        for _ in 0..<12 {
            var rawParent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ancestor, kAXParentAttribute as CFString, &rawParent) == .success,
                  let rawParent,
                  CFGetTypeID(rawParent) == AXUIElementGetTypeID()
            else {
                return false
            }
            let parent = rawParent as! AXUIElement
            if CFEqual(parent, targetWindow) {
                return true
            }
            AXUIElementSetMessagingTimeout(parent, 0.1)
            ancestor = parent
        }
        return false
    }

    func windowElement(for target: WindowTargetIdentity, in appElement: AXUIElement) -> AXUIElement? {
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
