import AppKit
import ApplicationServices
import Foundation
import SwooshCore

struct TrialOptions {
    var apps = ["Finder", "Safari", "TextEdit"]
    var performMinimize = false
    var performFullscreen = false
    var requestClose = false
    var settleDelay: TimeInterval = 1.2

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--apps":
                if let value = iterator.next() {
                    apps = value.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
                }
            case "--perform-minimize":
                performMinimize = true
            case "--perform-fullscreen":
                performFullscreen = true
            case "--request-close":
                requestClose = true
            case "--settle-delay":
                if let value = iterator.next(), let parsed = TimeInterval(value) {
                    settleDelay = parsed
                }
            default:
                break
            }
        }
    }
}

struct TrialWindow {
    var application: AXUIElement
    var window: AXUIElement
    var target: WindowTargetIdentity
}

final class JSONLinesLogger {
    func write(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }

        print(line)
        fflush(stdout)
    }
}

let options = TrialOptions(arguments: CommandLine.arguments)
let logger = JSONLinesLogger()
let lifecycleClient = SystemAccessibilityLifecycleClient()
let lifecycleController = WindowLifecycleController(client: lifecycleClient)

logger.write([
    "kind": "lifecycle-trial-started",
    "apps": options.apps,
    "performMinimize": options.performMinimize,
    "performFullscreen": options.performFullscreen,
    "requestClose": options.requestClose,
    "permissions": [
        "accessibilityTrusted": AXIsProcessTrusted()
    ],
    "timestamp": ISO8601DateFormatter().string(from: Date())
])

guard AXIsProcessTrusted() else {
    logger.write([
        "kind": "lifecycle-trial-ended",
        "status": "blocked",
        "reason": "Accessibility permission is required.",
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ])
    exit(2)
}

for appName in options.apps {
    runTrial(for: appName)
}

logger.write([
    "kind": "lifecycle-trial-ended",
    "status": "complete",
    "timestamp": ISO8601DateFormatter().string(from: Date())
])

@MainActor
func runTrial(for appName: String) {
    guard let trialWindow = prepareWindow(for: appName) else {
        logger.write([
            "kind": "app-lifecycle-result",
            "app": appName,
            "status": "no-window",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
        return
    }

    let supported = lifecycleController.supportedActions(for: trialWindow.target)
    var result: [String: Any] = [
        "kind": "app-lifecycle-result",
        "app": appName,
        "target": targetPayload(trialWindow.target),
        "supportedActions": supported.map(\.rawValue).sorted(),
        "initialFullscreen": jsonValue(lifecycleController.isFullscreen(trialWindow.target)),
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]

    if options.performMinimize, lifecycleClient.isAlive(trialWindow.target) {
        let minimize = lifecycleController.perform(.minimize, for: trialWindow.target)
        result["minimize"] = resultPayload(minimize)
        result["minimizedReadback"] = waitForBoolAttribute(kAXMinimizedAttribute, on: trialWindow.window, toBecome: true, timeout: 2.0)

        if setBoolAttribute(kAXMinimizedAttribute, value: false, on: trialWindow.window) {
            result["restoredFromMinimize"] = waitForBoolAttribute(kAXMinimizedAttribute, on: trialWindow.window, toBecome: false, timeout: 2.0)
        } else {
            result["restoredFromMinimize"] = false
        }
    }

    if options.performFullscreen, lifecycleClient.isAlive(trialWindow.target) {
        if lifecycleController.isFullscreen(trialWindow.target) == true {
            let preflightExit = lifecycleController.perform(.toggleFullscreen, for: trialWindow.target)
            result["fullscreenPreflightExit"] = resultPayload(preflightExit)
            result["fullscreenClearedBeforeTrial"] = waitForFullscreen(target: trialWindow.target, expected: false, timeout: 6.0)
            Thread.sleep(forTimeInterval: options.settleDelay)
            lifecycleController.finishFullscreenTransition(for: trialWindow.target)
        }

        let enter = lifecycleController.perform(.toggleFullscreen, for: trialWindow.target)
        result["fullscreenEnter"] = resultPayload(enter)
        result["geometryDuringFullscreenTransition"] = jsonValue(lifecycleController.guardGeometryCommand(for: trialWindow.target).map(resultPayload(_:)))
        result["fullscreenReachedAfterEnter"] = waitForFullscreen(target: trialWindow.target, expected: true, timeout: 6.0)
        Thread.sleep(forTimeInterval: options.settleDelay)
        lifecycleController.finishFullscreenTransition(for: trialWindow.target)
        result["fullscreenAfterEnter"] = jsonValue(lifecycleController.isFullscreen(trialWindow.target))

        if lifecycleClient.isAlive(trialWindow.target) {
            let exit = lifecycleController.perform(.toggleFullscreen, for: trialWindow.target)
            result["fullscreenExit"] = resultPayload(exit)
            result["fullscreenClearedAfterExit"] = waitForFullscreen(target: trialWindow.target, expected: false, timeout: 6.0)
            Thread.sleep(forTimeInterval: options.settleDelay)
            lifecycleController.finishFullscreenTransition(for: trialWindow.target)
            result["fullscreenAfterExit"] = jsonValue(lifecycleController.isFullscreen(trialWindow.target))
        }
    }

    if options.requestClose {
        let close = lifecycleController.perform(.requestClose, for: trialWindow.target)
        result["closeRequest"] = resultPayload(close)
        Thread.sleep(forTimeInterval: options.settleDelay)
        result["aliveAfterCloseRequest"] = lifecycleClient.isAlive(trialWindow.target)
    }

    logger.write(result)
}

@MainActor
func prepareWindow(for appName: String) -> TrialWindow? {
    let bundleID = bundleIdentifier(for: appName)
    guard let runningApplication = activateApplication(bundleIdentifier: bundleID) else {
        return nil
    }

    Thread.sleep(forTimeInterval: 0.8)

    let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 2.0)
    guard let window = focusedOrFirstWindow(from: application) else {
        return nil
    }

    return TrialWindow(
        application: application,
        window: window,
        target: WindowTargetIdentity(
            processIdentifier: runningApplication.processIdentifier,
            elementIdentifier: elementIdentifier(for: window, processIdentifier: runningApplication.processIdentifier)
        )
    )
}

@MainActor
func activateApplication(bundleIdentifier: String) -> NSRunningApplication? {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
        running.activate()
        return running
    }

    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
        return nil
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    var runningApplication: NSRunningApplication?
    var completed = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, _ in
        runningApplication = application
        completed = true
    }

    let deadline = Date().addingTimeInterval(5)
    while !completed && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    return runningApplication
}

func focusedOrFirstWindow(from application: AXUIElement) -> AXUIElement? {
    if let focused = elementAttribute(kAXFocusedWindowAttribute, from: application) {
        return focused
    }

    var rawWindows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
          let windows = rawWindows as? [AXUIElement]
    else {
        return nil
    }

    return windows.first
}

func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
    AXUIElementSetMessagingTimeout(element, 2.0)
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXUIElementGetTypeID()
    else {
        return nil
    }

    return (rawValue as! AXUIElement)
}

func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
    AXUIElementSetMessagingTimeout(element, 2.0)
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

func setBoolAttribute(_ attribute: String, value: Bool, on element: AXUIElement) -> Bool {
    AXUIElementSetMessagingTimeout(element, 2.0)
    return AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success
}

func waitForBoolAttribute(_ attribute: String, on element: AXUIElement, toBecome expected: Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if boolAttribute(attribute, from: element) == expected {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline

    return false
}

@MainActor
func waitForFullscreen(target: WindowTargetIdentity, expected: Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if lifecycleController.isFullscreen(target) == expected {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline

    return false
}

func targetPayload(_ target: WindowTargetIdentity) -> [String: Any] {
    [
        "pid": Int(target.processIdentifier),
        "elementIdentifier": target.elementIdentifier
    ]
}

func resultPayload(_ result: WindowLifecycleResult) -> [String: Any] {
    [
        "action": result.action.rawValue,
        "status": result.status.rawValue,
        "reason": jsonValue(result.reason)
    ]
}

func jsonValue<T>(_ value: T?) -> Any {
    value ?? NSNull()
}

func elementIdentifier(for element: AXUIElement, processIdentifier: pid_t) -> String {
    "pid:\(processIdentifier):element:\(CFHash(element))"
}

func bundleIdentifier(for appName: String) -> String {
    switch appName.lowercased() {
    case "finder":
        return "com.apple.finder"
    case "safari":
        return "com.apple.Safari"
    case "textedit":
        return "com.apple.TextEdit"
    default:
        return appName
    }
}
