import AppKit
import ApplicationServices
import Foundation

public struct GeometryPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct GeometrySize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct GeometryRect: Codable, Equatable, Sendable {
    public var origin: GeometryPoint
    public var size: GeometrySize

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = GeometryPoint(x: x, y: y)
        size = GeometrySize(width: width, height: height)
    }

    public var x: Double {
        origin.x
    }

    public var y: Double {
        origin.y
    }

    public var width: Double {
        size.width
    }

    public var height: Double {
        size.height
    }

    public var maxX: Double {
        x + width
    }

    public var maxY: Double {
        y + height
    }

    public var isPositive: Bool {
        width > 0 && height > 0
    }

    public func clamped(to bounds: GeometryRect) -> GeometryRect {
        let clampedWidth = min(width, bounds.width)
        let clampedHeight = min(height, bounds.height)
        let clampedX = min(max(x, bounds.x), bounds.maxX - clampedWidth)
        let clampedY = min(max(y, bounds.y), bounds.maxY - clampedHeight)
        return GeometryRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    public func centered(in bounds: GeometryRect) -> GeometryRect {
        GeometryRect(
            x: bounds.x + (bounds.width - width) / 2,
            y: bounds.y + (bounds.height - height) / 2,
            width: width,
            height: height
        ).clamped(to: bounds)
    }

    public func isWithin(_ tolerance: Double, of other: GeometryRect) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

public struct DisplayGeometry: Codable, Equatable, Sendable {
    public var id: String
    public var frame: GeometryRect
    public var usableFrame: GeometryRect
    public var scaleFactor: Double

    public init(id: String, frame: GeometryRect, usableFrame: GeometryRect, scaleFactor: Double = 1) {
        self.id = id
        self.frame = frame
        self.usableFrame = usableFrame
        self.scaleFactor = scaleFactor
    }
}

public enum SnapDestination: String, Codable, CaseIterable, Equatable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximize
}

public enum GeometryApplyStatus: String, Codable, Equatable, Sendable {
    case exact
    case constrained
    case unsupported
}

public struct GeometryApplyResult: Equatable, Sendable {
    public var requestedFrame: GeometryRect
    public var appliedFrame: GeometryRect?
    public var status: GeometryApplyStatus
    public var reason: String?

    public init(
        requestedFrame: GeometryRect,
        appliedFrame: GeometryRect?,
        status: GeometryApplyStatus,
        reason: String? = nil
    ) {
        self.requestedFrame = requestedFrame
        self.appliedFrame = appliedFrame
        self.status = status
        self.reason = reason
    }
}

public struct SnapGeometryEngine {
    public static let frameTolerance = 2.0

    public init() {}

    public func frame(for destination: SnapDestination, on display: DisplayGeometry, gridSpacing: Int) -> GeometryRect {
        let gap = clampedGap(gridSpacing, for: display.usableFrame)
        let slot = slotDescription(for: destination)
        let usable = display.usableFrame
        let cellWidth = (usable.width - Double(slot.columns + 1) * gap) / Double(slot.columns)
        let cellHeight = (usable.height - Double(slot.rows + 1) * gap) / Double(slot.rows)

        let x = usable.x + gap + Double(slot.column) * (cellWidth + gap)
        let y = usable.y + gap + Double(slot.row) * (cellHeight + gap)
        let width = Double(slot.columnSpan) * cellWidth + Double(slot.columnSpan - 1) * gap
        let height = Double(slot.rowSpan) * cellHeight + Double(slot.rowSpan - 1) * gap

        return GeometryRect(x: x, y: y, width: width, height: height)
    }

    public func evaluateAppliedFrame(
        requested: GeometryRect,
        applied: GeometryRect?,
        minimumSize: GeometrySize? = nil,
        tolerance: Double = SnapGeometryEngine.frameTolerance
    ) -> GeometryApplyResult {
        guard let applied else {
            return GeometryApplyResult(
                requestedFrame: requested,
                appliedFrame: nil,
                status: .unsupported,
                reason: "Frame could not be read back after applying."
            )
        }

        if let minimumSize,
           requested.width < minimumSize.width || requested.height < minimumSize.height {
            return GeometryApplyResult(
                requestedFrame: requested,
                appliedFrame: applied,
                status: .constrained,
                reason: "Requested frame is smaller than the window minimum size."
            )
        }

        if applied.isWithin(tolerance, of: requested) {
            return GeometryApplyResult(requestedFrame: requested, appliedFrame: applied, status: .exact)
        }

        return GeometryApplyResult(
            requestedFrame: requested,
            appliedFrame: applied,
            status: .constrained,
            reason: "Applied frame did not match the requested frame within tolerance."
        )
    }

    public func clampedGap(_ gridSpacing: Int, for usableFrame: GeometryRect) -> Double {
        let settingGap = Double(min(max(gridSpacing, SwooshSettings.gridSpacingRange.lowerBound), SwooshSettings.gridSpacingRange.upperBound))
        let maxGridGap = min(usableFrame.width, usableFrame.height) / 3
        return max(0, min(settingGap, maxGridGap.nextDown))
    }

    private func slotDescription(for destination: SnapDestination) -> SlotDescription {
        switch destination {
        case .maximize:
            SlotDescription(columns: 1, rows: 1, column: 0, row: 0)
        case .leftHalf:
            SlotDescription(columns: 2, rows: 1, column: 0, row: 0)
        case .rightHalf:
            SlotDescription(columns: 2, rows: 1, column: 1, row: 0)
        case .topHalf:
            SlotDescription(columns: 1, rows: 2, column: 0, row: 1)
        case .bottomHalf:
            SlotDescription(columns: 1, rows: 2, column: 0, row: 0)
        case .topLeft:
            SlotDescription(columns: 2, rows: 2, column: 0, row: 1)
        case .topRight:
            SlotDescription(columns: 2, rows: 2, column: 1, row: 1)
        case .bottomLeft:
            SlotDescription(columns: 2, rows: 2, column: 0, row: 0)
        case .bottomRight:
            SlotDescription(columns: 2, rows: 2, column: 1, row: 0)
        }
    }
}

private struct SlotDescription {
    var columns: Int
    var rows: Int
    var column: Int
    var row: Int
    var columnSpan = 1
    var rowSpan = 1
}

public enum CenterRestoreAction: Equatable, Sendable {
    case center
    case unsnap
    case centerAndUnsnap
}

public enum WindowFrameHistoryOutcome: Equatable, Sendable {
    case noOp
    case planned(GeometryRect)
}

public final class WindowFrameHistory {
    private var originalFrames: [WindowTargetIdentity: GeometryRect] = [:]
    private var lastManagedFrames: [WindowTargetIdentity: GeometryRect] = [:]

    public init() {}

    public func recordSuccessfulSnap(target: WindowTargetIdentity, originalFrame: GeometryRect, result: GeometryApplyResult) {
        guard result.status == .exact || result.status == .constrained else {
            return
        }

        if let lastManagedFrame = lastManagedFrames[target],
           !originalFrame.isWithin(SnapGeometryEngine.frameTolerance, of: lastManagedFrame) {
            originalFrames[target] = originalFrame
        } else if originalFrames[target] == nil {
            originalFrames[target] = originalFrame
        }
        recordManagedFrame(target: target, result: result)
    }

    public func recordManagedFrame(target: WindowTargetIdentity, result: GeometryApplyResult) {
        guard result.status == .exact || result.status == .constrained else {
            return
        }

        lastManagedFrames[target] = result.appliedFrame ?? result.requestedFrame
    }

    public func originalFrame(for target: WindowTargetIdentity) -> GeometryRect? {
        originalFrames[target]
    }

    public func remove(_ target: WindowTargetIdentity) {
        originalFrames.removeValue(forKey: target)
        lastManagedFrames.removeValue(forKey: target)
    }

    public func clearStaleTargets(keeping liveTargets: Set<WindowTargetIdentity>) {
        originalFrames = originalFrames.filter { liveTargets.contains($0.key) }
        lastManagedFrames = lastManagedFrames.filter { liveTargets.contains($0.key) }
    }

    public func plan(
        _ action: CenterRestoreAction,
        target: WindowTargetIdentity,
        currentFrame: GeometryRect,
        reachableDisplay: DisplayGeometry
    ) -> WindowFrameHistoryOutcome {
        let baseFrame = currentFrameAdjustedForManualChange(target: target, currentFrame: currentFrame)
        switch action {
        case .center:
            return .planned(currentFrame.centered(in: reachableDisplay.usableFrame))
        case .unsnap:
            guard let originalFrame = baseFrame else {
                return .noOp
            }
            return .planned(originalFrame.clamped(to: reachableDisplay.usableFrame))
        case .centerAndUnsnap:
            return (baseFrame ?? currentFrame).centered(in: reachableDisplay.usableFrame).planned
        }
    }

    private func currentFrameAdjustedForManualChange(target: WindowTargetIdentity, currentFrame: GeometryRect) -> GeometryRect? {
        guard originalFrames[target] != nil else {
            return nil
        }

        if let lastManagedFrame = lastManagedFrames[target],
           !currentFrame.isWithin(SnapGeometryEngine.frameTolerance, of: lastManagedFrame) {
            originalFrames[target] = currentFrame
            lastManagedFrames.removeValue(forKey: target)
        }

        return originalFrames[target]
    }
}

private extension GeometryRect {
    var planned: WindowFrameHistoryOutcome {
        .planned(self)
    }
}

public struct CoordinateConverter {
    public init() {}

    public func appKitToAccessibility(_ rect: GeometryRect, on displayFrame: GeometryRect) -> GeometryRect {
        GeometryRect(
            x: rect.x,
            y: displayFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public func accessibilityToAppKit(_ rect: GeometryRect, on displayFrame: GeometryRect) -> GeometryRect {
        GeometryRect(
            x: rect.x,
            y: displayFrame.maxY - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

public protocol WindowFrameControlling {
    func frame(for target: WindowTargetIdentity) -> GeometryRect?
    func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool
}

public struct SystemDisplayProvider {
    public init() {}

    public func mainDisplay() -> DisplayGeometry? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }

        return DisplayGeometry(screen: screen, index: 0)
    }

    public func displays() -> [DisplayGeometry] {
        NSScreen.screens.enumerated().map { index, screen in
            DisplayGeometry(screen: screen, index: index)
        }
    }
}

public final class SystemWindowFrameController: WindowFrameControlling {
    private let messagingTimeout: Float
    private let converter = CoordinateConverter()
    private let displayProvider = SystemDisplayProvider()

    public init(messagingTimeout: Float = 2.0) {
        self.messagingTimeout = messagingTimeout
    }

    public func frame(for target: WindowTargetIdentity) -> GeometryRect? {
        guard let window = windowElement(for: target),
              let accessibilityFrame = accessibilityFrame(for: window),
              let display = nearestDisplay(for: accessibilityFrame)
        else {
            return nil
        }

        return converter.accessibilityToAppKit(accessibilityFrame, on: display.frame)
    }

    public func setFrame(_ frame: GeometryRect, for target: WindowTargetIdentity) -> Bool {
        guard let window = windowElement(for: target),
              let display = nearestDisplay(for: frame)
        else {
            return false
        }

        let accessibilityFrame = converter.appKitToAccessibility(frame, on: display.frame)
        return setAccessibilityFrame(accessibilityFrame, for: window)
    }

    private func windowElement(for target: WindowTargetIdentity) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        return windowCandidates(for: appElement).first {
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

    private func accessibilityFrame(for window: AXUIElement) -> GeometryRect? {
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        guard let positionValue = copyValueAttribute(kAXPositionAttribute, from: window),
              let sizeValue = copyValueAttribute(kAXSizeAttribute, from: window)
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        return GeometryRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private func setAccessibilityFrame(_ frame: GeometryRect, for window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        var point = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let pointValue = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return positionResult == .success && sizeResult == .success
    }

    private func copyValueAttribute(_ attribute: String, from element: AXUIElement) -> AXValue? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        return (rawValue as! AXValue)
    }

    private func nearestDisplay(for frame: GeometryRect) -> DisplayGeometry? {
        displayProvider.displays().min { lhs, rhs in
            distance(from: frame, to: lhs.frame) < distance(from: frame, to: rhs.frame)
        }
    }

    private func distance(from rect: GeometryRect, to displayFrame: GeometryRect) -> Double {
        let centerX = rect.x + rect.width / 2
        let centerY = rect.y + rect.height / 2
        let displayCenterX = displayFrame.x + displayFrame.width / 2
        let displayCenterY = displayFrame.y + displayFrame.height / 2
        return hypot(centerX - displayCenterX, centerY - displayCenterY)
    }

    private func elementIdentifier(for element: AXUIElement, processIdentifier: pid_t) -> String {
        "pid:\(processIdentifier):element:\(CFHash(element))"
    }
}

private extension DisplayGeometry {
    init(screen: NSScreen, index: Int) {
        self.init(
            id: screen.localizedName.isEmpty ? "screen-\(index)" : screen.localizedName,
            frame: GeometryRect(screen.frame),
            usableFrame: GeometryRect(screen.visibleFrame),
            scaleFactor: screen.backingScaleFactor
        )
    }
}

private extension GeometryRect {
    init(_ rect: NSRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }
}
