import AppKit
import ApplicationServices
import Foundation
import SwooshCore

struct TrialApp {
    var name: String
    var bundleIdentifier: String
}

struct TrialWindow {
    var app: TrialApp
    var application: AXUIElement
    var window: AXUIElement
}

final class JSONLinesLogger {
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = [.sortedKeys]
    }

    func write(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            print("{\"kind\":\"logger-error\"}")
            fflush(stdout)
            return
        }

        print(line)
        fflush(stdout)
    }
}

let logger = JSONLinesLogger()
let engine = SnapGeometryEngine()
let converter = CoordinateConverter()
let apps = [
    TrialApp(name: "Finder", bundleIdentifier: "com.apple.finder"),
    TrialApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
    TrialApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
]

logger.write([
    "kind": "geometry-trial-started",
    "timestamp": isoTimestamp(),
    "accessibilityTrusted": AXIsProcessTrusted()
])

guard AXIsProcessTrusted() else {
    logger.write([
        "kind": "geometry-trial-ended",
        "status": "blocked",
        "reason": "Accessibility permission is not trusted for this runner."
    ])
    Foundation.exit(3)
}

let displays = NSScreen.screens.enumerated().map { index, screen in
    DisplayGeometry(
        id: screen.localizedName.isEmpty ? "screen-\(index)" : screen.localizedName,
        frame: GeometryRect(screen.frame),
        usableFrame: GeometryRect(screen.visibleFrame),
        scaleFactor: screen.backingScaleFactor
    )
}

logger.write([
    "kind": "display-snapshot",
    "displays": displays.map { display in
        [
            "id": display.id,
            "frame": display.frame.payload,
            "usableFrame": display.usableFrame.payload,
            "scaleFactor": display.scaleFactor
        ]
    }
])

for app in apps {
    autoreleasepool {
        runTrial(for: app, displays: displays)
    }
}

logger.write([
    "kind": "geometry-trial-ended",
    "timestamp": isoTimestamp(),
    "status": "complete"
])

@MainActor
func runTrial(for app: TrialApp, displays: [DisplayGeometry]) {
    guard let trialWindow = prepareWindow(for: app) else {
        logger.write([
            "kind": "app-result",
            "app": app.name,
            "status": "unavailable",
            "reason": "No eligible focused or first window was available."
        ])
        return
    }

    guard let originalAccessibilityFrame = readFrame(trialWindow.window),
          let desktopTopY = desktopTopY(displays: displays)
    else {
        logger.write([
            "kind": "app-result",
            "app": app.name,
            "status": "unavailable",
            "reason": "Could not read original frame or resolve display topology."
        ])
        return
    }

    let originalFrame = converter.accessibilityToAppKit(originalAccessibilityFrame, desktopTopY: desktopTopY)
    guard let display = nearestDisplay(forAppKitFrame: originalFrame, displays: displays) else {
        logger.write([
            "kind": "app-result",
            "app": app.name,
            "status": "unavailable",
            "reason": "Could not resolve display for original frame."
        ])
        return
    }

    let destinations: [SnapDestination] = [.leftHalf, .topRight, .bottomRight]
    var results: [[String: Any]] = []

    for destination in destinations {
        let requested = engine.frame(for: destination, on: display, gridSpacing: 0)
        let requestedAX = converter.appKitToAccessibility(requested, desktopTopY: desktopTopY)
        let setSucceeded = setFrame(requestedAX, for: trialWindow.window)
        Thread.sleep(forTimeInterval: 0.25)
        let appliedAX = readFrame(trialWindow.window)
        let applied = appliedAX.map { converter.accessibilityToAppKit($0, desktopTopY: desktopTopY) }
        let result = engine.evaluateAppliedFrame(requested: requested, applied: applied)

        results.append([
            "destination": destination.rawValue,
            "setSucceeded": setSucceeded,
            "requestedFrame": requested.payload,
            "appliedFrame": applied?.payload as Any,
            "status": result.status.rawValue,
            "reason": result.reason as Any
        ])
    }

    let restoreAX = converter.appKitToAccessibility(originalFrame, desktopTopY: desktopTopY)
    let restoreSetSucceeded = setFrame(restoreAX, for: trialWindow.window)
    Thread.sleep(forTimeInterval: 0.25)
    let restoredAX = readFrame(trialWindow.window)
    let restored = restoredAX.map { converter.accessibilityToAppKit($0, desktopTopY: desktopTopY) }
    let restoreResult = engine.evaluateAppliedFrame(requested: originalFrame, applied: restored)

    logger.write([
        "kind": "app-result",
        "app": app.name,
        "display": display.id,
        "status": results.allSatisfy { $0["status"] as? String == GeometryApplyStatus.exact.rawValue }
            && restoreResult.status == .exact ? "passed" : "constrained-or-failed",
        "originalFrame": originalFrame.payload,
        "snapResults": results,
        "restore": [
            "setSucceeded": restoreSetSucceeded,
            "appliedFrame": restored?.payload as Any,
            "status": restoreResult.status.rawValue,
            "reason": restoreResult.reason as Any
        ]
    ])
}

@MainActor
func prepareWindow(for app: TrialApp) -> TrialWindow? {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        Thread.sleep(forTimeInterval: 1.0)
    }

    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first else {
        return nil
    }

    running.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.5)

    let application = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 2.0)

    if let focused = copyElementAttribute(kAXFocusedWindowAttribute, from: application) {
        return TrialWindow(app: app, application: application, window: focused)
    }

    if let windows = copyElementArrayAttribute(kAXWindowsAttribute, from: application), let first = windows.first {
        return TrialWindow(app: app, application: application, window: first)
    }

    return nil
}

func readFrame(_ window: AXUIElement) -> GeometryRect? {
    AXUIElementSetMessagingTimeout(window, 2.0)
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

func setFrame(_ frame: GeometryRect, for window: AXUIElement) -> Bool {
    AXUIElementSetMessagingTimeout(window, 2.0)
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

func nearestDisplay(forAppKitFrame frame: GeometryRect, displays: [DisplayGeometry]) -> DisplayGeometry? {
    displays.min { lhs, rhs in
        distance(from: frame, to: lhs.frame) < distance(from: frame, to: rhs.frame)
    }
}

func desktopTopY(displays: [DisplayGeometry]) -> Double? {
    displays.map(\.frame.maxY).max()
}

func distance(from rect: GeometryRect, to displayFrame: GeometryRect) -> Double {
    let centerX = rect.x + rect.width / 2
    let centerY = rect.y + rect.height / 2
    let displayCenterX = displayFrame.x + displayFrame.width / 2
    let displayCenterY = displayFrame.y + displayFrame.height / 2
    return hypot(centerX - displayCenterX, centerY - displayCenterY)
}

func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let raw,
          CFGetTypeID(raw) == AXUIElementGetTypeID()
    else {
        return nil
    }

    return (raw as! AXUIElement)
}

func copyElementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let elements = raw as? [AXUIElement]
    else {
        return nil
    }

    return elements
}

func copyValueAttribute(_ attribute: String, from element: AXUIElement) -> AXValue? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let value = raw,
          CFGetTypeID(value) == AXValueGetTypeID()
    else {
        return nil
    }

    return (value as! AXValue)
}

func isoTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private extension GeometryRect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var payload: [String: Double] {
        [
            "x": x,
            "y": y,
            "width": width,
            "height": height
        ]
    }
}
