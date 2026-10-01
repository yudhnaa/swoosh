import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct ProbeOptions {
    var duration: TimeInterval = 30
    var includeAXHitTest = true
    var includePrivateMultitouch = true
    var healthInterval: TimeInterval = 5
    var privateDeviceFilter: PrivateDeviceFilter = .all
    var maxTouchFramesPerDevice = 120

    static func parse(_ arguments: [String]) -> ProbeOptions {
        var options = ProbeOptions()
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration" where index + 1 < arguments.count:
                options.duration = TimeInterval(arguments[index + 1]) ?? options.duration
                index += 2
            case "--no-ax-hit-test":
                options.includeAXHitTest = false
                index += 1
            case "--no-private-multitouch":
                options.includePrivateMultitouch = false
                index += 1
            case "--health-interval" where index + 1 < arguments.count:
                options.healthInterval = TimeInterval(arguments[index + 1]) ?? options.healthInterval
                index += 2
            case "--private-device-filter" where index + 1 < arguments.count:
                guard let filter = PrivateDeviceFilter(rawValue: arguments[index + 1]) else {
                    fputs("Invalid --private-device-filter: \(arguments[index + 1])\n\n", stderr)
                    printHelp()
                    Foundation.exit(2)
                }
                options.privateDeviceFilter = filter
                index += 2
            case "--max-touch-frames-per-device" where index + 1 < arguments.count:
                guard let limit = Int(arguments[index + 1]), limit >= 0 else {
                    fputs("--max-touch-frames-per-device must be a non-negative integer\n\n", stderr)
                    printHelp()
                    Foundation.exit(2)
                }
                options.maxTouchFramesPerDevice = limit
                index += 2
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                fputs("Unknown argument: \(arguments[index])\n\n", stderr)
                printHelp()
                Foundation.exit(2)
            }
        }

        return options
    }

    private static func printHelp() {
        print("""
        gesture-probe records documented macOS input evidence as newline-delimited JSON.

        Usage:
          swift run gesture-probe [--duration seconds] [--no-ax-hit-test] [--no-private-multitouch]
                                  [--health-interval seconds]
                                  [--private-device-filter all|built-in|external]
                                  [--max-touch-frames-per-device count]

        During capture, place the pointer on Finder, Safari, and TextEdit titlebars and try:
          - horizontal and vertical two-finger strokes
          - pinch in/out
          - Esc and configured modifier keys
          - ordinary scroll/zoom/typing outside titlebars

        The probe records event metadata, phases, deltas, modifier state, permission state,
        screen geometry, and Accessibility role/subrole hit-test data. It does not record
        keystroke characters, window titles, document text, screenshots, or account data.

        By default the probe also attempts to runtime-load Apple's private
        MultitouchSupport.framework to emit sanitized touch-frame and derived pinch
        feasibility data. Use --no-private-multitouch to disable that path. Private
        touch-frame logging is capped per device; derived gesture summaries continue.
        """)
    }
}

enum PrivateDeviceFilter: String {
    case all
    case builtIn = "built-in"
    case external

    func includes(isBuiltIn: Bool?) -> Bool {
        switch self {
        case .all:
            return true
        case .builtIn:
            return isBuiltIn == true
        case .external:
            return isBuiltIn == false
        }
    }
}

final class JSONLogger {
    private let lock = NSLock()

    func write(_ payload: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            print("{\"kind\":\"logger-error\",\"message\":\"invalid JSON payload\"}")
            fflush(stdout)
            return
        }

        print(line)
        fflush(stdout)
    }
}

final class ProbeState {
    let logger = JSONLogger()
    let options: ProbeOptions
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var privateMultitouch: PrivateMultitouchProbe?
    private var healthTimer: DispatchSourceTimer?

    init(options: ProbeOptions) {
        self.options = options
    }

    deinit {
        healthTimer?.cancel()
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    func start() {
        writeEnvironment()
        installAppKitMonitors()
        installCGEventTap()
        installPrivateMultitouchIfEnabled()
        startHealthTimer()
    }

    private func writeEnvironment() {
        logger.write([
            "kind": "environment",
            "timestamp": isoTimestamp(),
            "process": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": machineArchitecture(),
                "swiftRuntimeTarget": "macOS 15.0"
            ],
            "permissions": permissionSnapshot(),
            "hardware": [
                "modelIdentifier": sysctlString("hw.model") ?? "unknown",
                "cpuBrand": sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
            ],
            "screens": NSScreen.screens.enumerated().map { index, screen in
                [
                    "index": index,
                    "frame": rectPayload(screen.frame),
                    "visibleFrame": rectPayload(screen.visibleFrame),
                    "backingScaleFactor": screen.backingScaleFactor
                ]
            },
            "coreGraphicsDisplays": activeDisplayPayload()
        ])
    }

    private func installAppKitMonitors() {
        let masks: NSEvent.EventTypeMask = [
            .beginGesture,
            .endGesture,
            .flagsChanged,
            .gesture,
            .keyDown,
            .keyUp,
            .magnify,
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .scrollWheel,
            .swipe
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: masks) { [weak self] event in
            self?.logAppKitEvent(event, scope: "global")
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: masks) { [weak self] event in
            self?.logAppKitEvent(event, scope: "local")
            return event
        }

        logger.write([
            "kind": "monitor-installed",
            "api": "NSEvent.addGlobalMonitorForEvents/addLocalMonitorForEvents",
            "scope": "appkit",
            "permissions": permissionSnapshot()
        ])
    }

    private func installCGEventTap() {
        let eventTypes: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .keyUp,
            .leftMouseDown,
            .leftMouseUp,
            .mouseMoved,
            .rightMouseDown,
            .rightMouseUp,
            .scrollWheel,
            .tapDisabledByTimeout,
            .tapDisabledByUserInput
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, eventType in
            partial | CGEventMask(1 << UInt64(eventType.rawValue))
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: CGEventBridge.callback,
            userInfo: refcon
        ) else {
            logger.write([
                "kind": "monitor-unavailable",
                "api": "CGEvent.tapCreate",
                "scope": "coregraphics",
                "reason": "tapCreate returned nil",
                "permissions": permissionSnapshot()
            ])
            return
        }

        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        logger.write([
            "kind": "monitor-installed",
            "api": "CGEvent.tapCreate",
            "scope": "coregraphics",
            "events": eventTypes.map { String(describing: $0) },
            "permissions": permissionSnapshot()
        ])
    }

    private func installPrivateMultitouchIfEnabled() {
        guard options.includePrivateMultitouch else {
            logger.write([
                "kind": "monitor-disabled",
                "api": "MultitouchSupport.framework",
                "scope": "private-multitouch",
                "reason": "--no-private-multitouch"
            ])
            return
        }

        privateMultitouch = PrivateMultitouchProbe(
            logger: logger,
            includeAXHitTest: options.includeAXHitTest,
            deviceFilter: options.privateDeviceFilter,
            maxTouchFramesPerDevice: options.maxTouchFramesPerDevice
        )
        privateMultitouch?.start()
    }

    private func startHealthTimer() {
        guard options.healthInterval > 0 else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + options.healthInterval, repeating: options.healthInterval)
        timer.setEventHandler { [weak self] in
            self?.writeHealthSnapshot()
        }
        timer.resume()
        healthTimer = timer
    }

    private func writeHealthSnapshot() {
        logger.write([
            "kind": "health",
            "timestamp": isoTimestamp(),
            "permissions": permissionSnapshot(),
            "listeners": [
                "appkitGlobalInstalled": globalMonitor != nil,
                "appkitLocalInstalled": localMonitor != nil,
                "coreGraphicsTapInstalled": eventTap != nil,
                "coreGraphicsTapEnabled": eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
                "privateMultitouchStarted": privateMultitouch?.hasStartedDevices ?? false
            ]
        ])
    }

    func logCGEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            logger.write([
                "kind": "tap-disabled",
                "timestamp": isoTimestamp(),
                "type": String(describing: type),
                "reEnabled": eventTap != nil
            ])
            return
        }

        var payload: [String: Any] = [
            "kind": "event",
            "timestamp": isoTimestamp(),
            "source": "coregraphics",
            "type": String(describing: type),
            "location": pointPayload(event.location),
            "scroll": [
                "fixedDeltaX": event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2),
                "fixedDeltaY": event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1),
                "pointDeltaX": event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                "pointDeltaY": event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                "momentumPhase": event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                "scrollPhase": event.getIntegerValueField(.scrollWheelEventScrollPhase)
            ],
            "modifierFlags": event.flags.rawValue
        ]

        if options.includeAXHitTest {
            payload["accessibilityHitTest"] = accessibilityHitTest(at: event.location)
        }

        logger.write(payload)
    }

    private func logAppKitEvent(_ event: NSEvent, scope: String) {
        var payload: [String: Any] = [
            "kind": "event",
            "timestamp": isoTimestamp(),
            "source": "appkit",
            "scope": scope,
            "type": String(describing: event.type),
            "phase": String(describing: event.phase),
            "momentumPhase": String(describing: event.momentumPhase),
            "modifierFlags": event.modifierFlags.rawValue,
            "locationInWindow": pointPayload(event.locationInWindow),
            "scroll": [
                "deltaX": event.deltaX,
                "deltaY": event.deltaY,
                "scrollingDeltaX": event.scrollingDeltaX,
                "scrollingDeltaY": event.scrollingDeltaY,
                "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
                "isDirectionInvertedFromDevice": event.isDirectionInvertedFromDevice
            ],
            "gesture": [
                "magnification": event.type == .magnify ? event.magnification : 0,
                "rotation": event.rotation
            ]
        ]

        if options.includeAXHitTest {
            payload["accessibilityHitTest"] = accessibilityHitTest(at: NSEvent.mouseLocation)
        }

        logger.write(payload)
    }
}

private enum CGEventBridge {
    nonisolated(unsafe) static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        if let userInfo {
            let state = Unmanaged<ProbeState>.fromOpaque(userInfo).takeUnretainedValue()
            state.logCGEvent(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }
}

private typealias MTDeviceRef = UnsafeMutableRawPointer

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

private typealias MTFrameCallbackWithRefcon = @convention(c) (
    MTDeviceRef?,
    UnsafeRawPointer?,
    Int,
    Double,
    Int,
    UnsafeMutableRawPointer?
) -> Void

private typealias MTFrameCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeRawPointer?,
    Int,
    Double,
    Int
) -> Void

private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallbackWithRefconFn = @convention(c) (
    MTDeviceRef?,
    MTFrameCallbackWithRefcon?,
    UnsafeMutableRawPointer?
) -> Void
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (MTDeviceRef?, MTFrameCallback?) -> Void
private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef?, Int32) -> Int32
private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef?) -> Int32
private typealias MTDeviceIsBuiltInFn = @convention(c) (MTDeviceRef?) -> Bool
private typealias MTDeviceGetDeviceIDFn = @convention(c) (MTDeviceRef?, UnsafeMutablePointer<UInt64>?) -> Int32
private typealias MTDeviceGetSensorSurfaceDimensionsFn = @convention(c) (
    MTDeviceRef?,
    UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<Int32>?
) -> Int32

final class PrivateMultitouchProbe {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private let logger: JSONLogger
    private let includeAXHitTest: Bool
    private let deviceFilter: PrivateDeviceFilter
    private let maxTouchFramesPerDevice: Int
    private var handle: UnsafeMutableRawPointer?
    private var devices: [MTDeviceRef] = []
    private let lock = NSLock()
    private var deviceLabelsByPointer: [UInt: String] = [:]
    private var deviceBuiltInByLabel: [String: Bool?] = [:]
    private var recognizersByDeviceLabel: [String: TouchGestureRecognizer] = [:]
    private var emittedTouchFrameCountsByLabel: [String: Int] = [:]
    private var touchFrameSuppressionLoggedByLabel: Set<String> = []

    private var createList: MTDeviceCreateListFn?
    private var registerWithRefcon: MTRegisterContactFrameCallbackWithRefconFn?
    private var registerWithoutRefcon: MTRegisterContactFrameCallbackFn?
    private var deviceStart: MTDeviceStartFn?
    private var deviceStop: MTDeviceStopFn?
    private var deviceIsBuiltIn: MTDeviceIsBuiltInFn?
    private var deviceGetDeviceID: MTDeviceGetDeviceIDFn?
    private var deviceGetSensorSurfaceDimensions: MTDeviceGetSensorSurfaceDimensionsFn?

    var hasStartedDevices: Bool {
        !devices.isEmpty
    }

    init(
        logger: JSONLogger,
        includeAXHitTest: Bool,
        deviceFilter: PrivateDeviceFilter,
        maxTouchFramesPerDevice: Int
    ) {
        self.logger = logger
        self.includeAXHitTest = includeAXHitTest
        self.deviceFilter = deviceFilter
        self.maxTouchFramesPerDevice = maxTouchFramesPerDevice
    }

    deinit {
        stopDevices()
        if let handle {
            dlclose(handle)
        }
    }

    func start() {
        guard loadFramework() else {
            return
        }

        guard let createList, let deviceStart else {
            logger.write([
                "kind": "monitor-unavailable",
                "api": "MultitouchSupport.framework",
                "scope": "private-multitouch",
                "reason": "required symbols unavailable after load"
            ])
            return
        }

        guard let deviceArray = createList()?.takeUnretainedValue() else {
            logger.write([
                "kind": "monitor-unavailable",
                "api": "MTDeviceCreateList",
                "scope": "private-multitouch",
                "reason": "returned nil"
            ])
            return
        }

        let count = CFArrayGetCount(deviceArray)
        logger.write([
            "kind": "private-multitouch-device-list",
            "timestamp": isoTimestamp(),
            "deviceCount": count
        ])

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var startedDevices: [[String: Any]] = []

        for index in 0..<count {
            guard let rawDevice = CFArrayGetValueAtIndex(deviceArray, index) else {
                continue
            }

            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            let metadata = deviceMetadata(device: device, index: index)
            let isBuiltIn = metadata["builtIn"] as? Bool

            guard deviceFilter.includes(isBuiltIn: isBuiltIn) else {
                var skipped = metadata
                skipped["started"] = false
                skipped["startSkippedReason"] = "excluded by --private-device-filter \(deviceFilter.rawValue)"
                startedDevices.append(skipped)
                continue
            }

            if let registerWithRefcon {
                registerWithRefcon(device, PrivateMultitouchBridge.callbackWithRefcon, refcon)
            } else if let registerWithoutRefcon {
                PrivateMultitouchBridge.fallbackProbe = self
                registerWithoutRefcon(device, PrivateMultitouchBridge.callbackWithoutRefcon)
            } else {
                logger.write([
                    "kind": "monitor-unavailable",
                    "api": "MTRegisterContactFrameCallback",
                    "scope": "private-multitouch",
                    "reason": "registration symbol unavailable",
                    "device": metadata
                ])
                continue
            }

            let startResult = deviceStart(device, 0)
            if startResult == 0 {
                devices.append(device)
            }

            var started = metadata
            started["startResult"] = startResult
            started["started"] = startResult == 0
            startedDevices.append(started)
        }

        logger.write([
            "kind": "monitor-installed",
            "api": "MultitouchSupport.framework",
            "scope": "private-multitouch",
            "frameworkPath": Self.frameworkPath,
            "usesPrivateAPI": true,
            "callbackMode": registerWithRefcon == nil ? "global-fallback" : "refcon",
            "deviceFilter": deviceFilter.rawValue,
            "maxTouchFramesPerDevice": maxTouchFramesPerDevice,
            "devices": startedDevices,
            "note": "Private feasibility probe only; device labels are session-local and raw touch-frame logging is capped."
        ])
    }

    fileprivate func handleFrame(device: MTDeviceRef?, touches rawPointer: UnsafeRawPointer?, count: Int, timestamp: Double, frame: Int) {
        let pointer = rawPointer?.assumingMemoryBound(to: MTTouch.self)
        guard let pointer else {
            return
        }

        var touches: [TouchSample] = []
        touches.reserveCapacity(max(0, count))

        for index in 0..<max(0, count) {
            let touch = pointer.advanced(by: index).pointee
            touches.append(TouchSample(
                id: touch.fingerID,
                state: touch.state,
                x: Double(touch.normalizedVector.position.x),
                y: Double(touch.normalizedVector.position.y),
                velocityX: Double(touch.normalizedVector.velocity.x),
                velocityY: Double(touch.normalizedVector.velocity.y),
                size: Double(touch.zTotal),
                majorAxis: Double(touch.majorAxis),
                minorAxis: Double(touch.minorAxis)
            ))
        }

        let pointerLocation = currentPointerLocation()
        let axPayload = includeAXHitTest ? accessibilityHitTest(at: pointerLocation) : nil
        let modifierFlags = CGEvent(source: nil)?.flags.rawValue ?? 0

        let deviceLabel = sessionDeviceLabel(for: device)
        let deviceBuiltIn = deviceBuiltInByLabel[deviceLabel] ?? nil
        var events: [[String: Any]] = []
        lock.lock()
        let recognizer = recognizersByDeviceLabel[deviceLabel] ?? TouchGestureRecognizer()
        recognizersByDeviceLabel[deviceLabel] = recognizer
        let updates = recognizer.process(touches: touches, timestamp: timestamp, frame: frame)
        lock.unlock()

        if shouldEmitTouchFrame(for: deviceLabel) {
            var framePayload: [String: Any] = [
                "kind": "event",
                "timestamp": isoTimestamp(),
                "source": "private-multitouch",
                "type": "touch-frame",
                "usesPrivateAPI": true,
                "deviceLabel": deviceLabel,
                "deviceBuiltIn": deviceBuiltInPayload(deviceBuiltIn),
                "frame": frame,
                "deviceTimestamp": timestamp,
                "touchCount": touches.count,
                "pointerLocation": pointPayload(pointerLocation),
                "modifierFlags": modifierFlags,
                "touches": touches.map { $0.payload }
            ]

            if let axPayload {
                framePayload["accessibilityHitTest"] = axPayload
            }
            events.append(framePayload)
        } else if !touchFrameSuppressionLoggedByLabel.contains(deviceLabel) {
            touchFrameSuppressionLoggedByLabel.insert(deviceLabel)
            events.append([
                "kind": "event",
                "timestamp": isoTimestamp(),
                "source": "private-multitouch",
                "type": "touch-frame-suppressed",
                "usesPrivateAPI": true,
                "deviceLabel": deviceLabel,
                "deviceBuiltIn": deviceBuiltInPayload(deviceBuiltIn),
                "maxTouchFramesPerDevice": maxTouchFramesPerDevice,
                "reason": "per-device raw touch-frame cap reached; derived gesture events continue"
            ])
        }

        for update in updates {
            var payload = update.payload
            payload["timestamp"] = isoTimestamp()
            payload["source"] = "private-multitouch"
            payload["usesPrivateAPI"] = true
            payload["deviceLabel"] = deviceLabel
            payload["deviceBuiltIn"] = deviceBuiltInPayload(deviceBuiltIn)
            payload["pointerLocation"] = pointPayload(pointerLocation)
            payload["modifierFlags"] = modifierFlags
            if let axPayload {
                payload["accessibilityHitTest"] = axPayload
            }
            events.append(payload)
        }

        for event in events {
            logger.write(event)
        }
    }

    private func loadFramework() -> Bool {
        handle = dlopen(Self.frameworkPath, RTLD_NOW)
        guard let handle else {
            logger.write([
                "kind": "monitor-unavailable",
                "api": "dlopen",
                "scope": "private-multitouch",
                "frameworkPath": Self.frameworkPath,
                "reason": dlerrorString()
            ])
            return false
        }

        createList = symbol(handle, "MTDeviceCreateList", as: MTDeviceCreateListFn.self)
        registerWithRefcon = symbol(handle, "MTRegisterContactFrameCallbackWithRefcon", as: MTRegisterContactFrameCallbackWithRefconFn.self)
        registerWithoutRefcon = symbol(handle, "MTRegisterContactFrameCallback", as: MTRegisterContactFrameCallbackFn.self)
        deviceStart = symbol(handle, "MTDeviceStart", as: MTDeviceStartFn.self)
        deviceStop = symbol(handle, "MTDeviceStop", as: MTDeviceStopFn.self)
        deviceIsBuiltIn = symbol(handle, "MTDeviceIsBuiltIn", as: MTDeviceIsBuiltInFn.self)
        deviceGetDeviceID = symbol(handle, "MTDeviceGetDeviceID", as: MTDeviceGetDeviceIDFn.self)
        deviceGetSensorSurfaceDimensions = symbol(handle, "MTDeviceGetSensorSurfaceDimensions", as: MTDeviceGetSensorSurfaceDimensionsFn.self)

        logger.write([
            "kind": "private-multitouch-symbols",
            "timestamp": isoTimestamp(),
            "frameworkPath": Self.frameworkPath,
            "symbols": [
                "MTDeviceCreateList": createList != nil,
                "MTRegisterContactFrameCallbackWithRefcon": registerWithRefcon != nil,
                "MTRegisterContactFrameCallback": registerWithoutRefcon != nil,
                "MTDeviceStart": deviceStart != nil,
                "MTDeviceStop": deviceStop != nil,
                "MTDeviceIsBuiltIn": deviceIsBuiltIn != nil,
                "MTDeviceGetDeviceID": deviceGetDeviceID != nil,
                "MTDeviceGetSensorSurfaceDimensions": deviceGetSensorSurfaceDimensions != nil
            ]
        ])

        return true
    }

    private func stopDevices() {
        guard let deviceStop else {
            return
        }
        for device in devices {
            _ = deviceStop(device)
        }
        devices.removeAll()
    }

    private func deviceMetadata(device: MTDeviceRef, index: Int) -> [String: Any] {
        let label = sessionDeviceLabel(for: device)
        var payload: [String: Any] = [
            "index": index,
            "label": label
        ]

        if let deviceIsBuiltIn {
            let builtIn = deviceIsBuiltIn(device)
            payload["builtIn"] = builtIn
            deviceBuiltInByLabel[label] = builtIn
        } else {
            payload["builtIn"] = "unavailable"
            deviceBuiltInByLabel[label] = nil
        }

        if let deviceGetDeviceID {
            var deviceID: UInt64 = 0
            let result = deviceGetDeviceID(device, &deviceID)
            payload["deviceIDResult"] = result
            payload["deviceID"] = result == 0 ? "redacted" : "unavailable"
        }

        if let deviceGetSensorSurfaceDimensions {
            var width: Int32 = 0
            var height: Int32 = 0
            let result = deviceGetSensorSurfaceDimensions(device, &width, &height)
            payload["sensorDimensionsResult"] = result
            if result == 0 {
                payload["sensorDimensions"] = [
                    "width": width,
                    "height": height
                ]
            }
        }

        return payload
    }

    private func sessionDeviceLabel(for device: MTDeviceRef?) -> String {
        guard let device else {
            return "unknown-device"
        }

        let key = UInt(bitPattern: device)
        if let existing = deviceLabelsByPointer[key] {
            return existing
        }

        let label = "multitouch-\(deviceLabelsByPointer.count + 1)"
        deviceLabelsByPointer[key] = label
        return label
    }

    private func shouldEmitTouchFrame(for deviceLabel: String) -> Bool {
        let count = emittedTouchFrameCountsByLabel[deviceLabel] ?? 0
        guard count < maxTouchFramesPerDevice else {
            return false
        }

        emittedTouchFrameCountsByLabel[deviceLabel] = count + 1
        return true
    }
}

private enum PrivateMultitouchBridge {
    nonisolated(unsafe) static weak var fallbackProbe: PrivateMultitouchProbe?

    nonisolated(unsafe) static let callbackWithRefcon: MTFrameCallbackWithRefcon = { device, touches, count, timestamp, frame, refcon in
        guard let refcon else {
            return
        }
        let probe = Unmanaged<PrivateMultitouchProbe>.fromOpaque(refcon).takeUnretainedValue()
        probe.handleFrame(device: device, touches: touches, count: count, timestamp: timestamp, frame: frame)
    }

    nonisolated(unsafe) static let callbackWithoutRefcon: MTFrameCallback = { device, touches, count, timestamp, frame in
        fallbackProbe?.handleFrame(device: device, touches: touches, count: count, timestamp: timestamp, frame: frame)
    }
}

private struct TouchSample {
    var id: Int32
    var state: UInt32
    var x: Double
    var y: Double
    var velocityX: Double
    var velocityY: Double
    var size: Double
    var majorAxis: Double
    var minorAxis: Double

    var payload: [String: Any] {
        [
            "id": id,
            "state": state,
            "position": [
                "x": rounded(x),
                "y": rounded(y)
            ],
            "velocity": [
                "x": rounded(velocityX),
                "y": rounded(velocityY)
            ],
            "size": rounded(size),
            "majorAxis": rounded(majorAxis),
            "minorAxis": rounded(minorAxis)
        ]
    }
}

private struct TouchCentroid {
    var x: Double
    var y: Double
    var spread: Double
}

private struct DerivedGestureUpdate {
    var kind: String
    var phase: String
    var direction: String
    var magnitude: Double
    var delta: Double
    var touchCount: Int
    var frame: Int
    var deviceTimestamp: Double

    var payload: [String: Any] {
        [
            "kind": kind,
            "type": "derived-pinch",
            "phase": phase,
            "direction": direction,
            "magnitude": rounded(magnitude),
            "delta": rounded(delta),
            "touchCount": touchCount,
            "frame": frame,
            "deviceTimestamp": deviceTimestamp
        ]
    }
}

private final class TouchGestureRecognizer {
    private var active = false
    private var baseSpread: Double = 0
    private var lastSpread: Double = 0
    private var lastDirection = "none"
    private var lastFrame = 0
    private let startThreshold = 0.015
    private let updateThreshold = 0.004

    func process(touches: [TouchSample], timestamp: Double, frame: Int) -> [DerivedGestureUpdate] {
        let activeTouches = touches.filter { $0.state != 5 && $0.state != 7 }
        guard activeTouches.count == 2, let centroid = centroid(for: activeTouches) else {
            if active {
                let endDirection = lastDirection
                active = false
                return [
                    DerivedGestureUpdate(
                        kind: "gesture",
                        phase: "ended",
                        direction: endDirection,
                        magnitude: abs(lastSpread - baseSpread),
                        delta: 0,
                        touchCount: activeTouches.count,
                        frame: frame,
                        deviceTimestamp: timestamp
                    )
                ]
            }
            return []
        }

        if !active {
            active = true
            baseSpread = centroid.spread
            lastSpread = centroid.spread
            lastDirection = "none"
            lastFrame = frame
            return [
                DerivedGestureUpdate(
                    kind: "gesture",
                    phase: "began",
                    direction: "none",
                    magnitude: 0,
                    delta: 0,
                    touchCount: activeTouches.count,
                    frame: frame,
                    deviceTimestamp: timestamp
                )
            ]
        }

        let delta = centroid.spread - lastSpread
        let magnitude = centroid.spread - baseSpread
        lastSpread = centroid.spread
        lastFrame = frame

        guard abs(magnitude) >= startThreshold || abs(delta) >= updateThreshold else {
            return []
        }

        let direction = magnitude > 0 ? "out" : "in"
        lastDirection = direction
        return [
            DerivedGestureUpdate(
                kind: "gesture",
                phase: "changed",
                direction: direction,
                magnitude: abs(magnitude),
                delta: delta,
                touchCount: activeTouches.count,
                frame: frame,
                deviceTimestamp: timestamp
            )
        ]
    }

    private func centroid(for touches: [TouchSample]) -> TouchCentroid? {
        guard touches.count >= 2 else {
            return nil
        }

        let x = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let y = touches.map(\.y).reduce(0, +) / Double(touches.count)
        let spread = touches
            .map { hypot($0.x - x, $0.y - y) }
            .reduce(0, +) / Double(touches.count)

        return TouchCentroid(x: x, y: y, spread: spread)
    }
}

private func permissionSnapshot() -> [String: Any] {
    var snapshot: [String: Any] = [
        "accessibilityTrusted": AXIsProcessTrusted()
    ]

    if #available(macOS 10.15, *) {
        snapshot["listenEventAccessPreflight"] = CGPreflightListenEventAccess()
    }

    return snapshot
}

private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let symbol = dlsym(handle, name) else {
        return nil
    }
    return unsafeBitCast(symbol, to: type)
}

private func dlerrorString() -> String {
    guard let error = dlerror() else {
        return "unknown dlopen/dlsym error"
    }
    return String(cString: error)
}

private func currentPointerLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
}

private func accessibilityHitTest(at point: CGPoint) -> [String: Any] {
    guard AXIsProcessTrusted() else {
        return ["available": false, "reason": "accessibility not trusted"]
    }

    let systemWide = AXUIElementCreateSystemWide()
    var elementRef: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)

    guard error == .success, let element = elementRef else {
        return [
            "available": false,
            "reason": "AXUIElementCopyElementAtPosition failed",
            "error": String(describing: error)
        ]
    }

    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)

    let chain = accessibilityChain(from: element, maxDepth: 6)
    let roles = chain.compactMap { $0["role"] as? String }
    let subroles = chain.compactMap { $0["subrole"] as? String }
    let firstRole = roles.first ?? ""
    return [
        "available": true,
        "point": pointPayload(point),
        "pid": pid,
        "application": applicationPayload(pid: pid),
        "chain": chain,
        "titlebarRelated": roles.contains("AXTitleBar") ||
            subroles.contains("AXTitleBar") ||
            (roles.contains("AXToolbar") && roles.contains("AXWindow")) ||
            firstRole == "AXWindow"
    ]
}

private func accessibilityChain(from element: AXUIElement, maxDepth: Int) -> [[String: Any]] {
    var chain: [[String: Any]] = []
    var current: AXUIElement? = element
    var remainingDepth = maxDepth

    while let element = current, remainingDepth > 0 {
        var item: [String: Any] = [:]
        item["role"] = axString(element, attribute: kAXRoleAttribute as CFString) ?? "unknown"
        item["subrole"] = axString(element, attribute: kAXSubroleAttribute as CFString) ?? ""
        chain.append(item)

        var parentValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
           let parent = parentValue,
           CFGetTypeID(parent) == AXUIElementGetTypeID() {
            current = (parent as! AXUIElement)
        } else {
            current = nil
        }

        remainingDepth -= 1
    }

    return chain
}

private func axString(_ element: AXUIElement, attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value as? String
}

private func applicationPayload(pid: pid_t) -> [String: Any] {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return [
            "pid": pid,
            "available": false
        ]
    }

    return [
        "pid": pid,
        "available": true,
        "bundleIdentifier": app.bundleIdentifier ?? "",
        "localizedName": app.localizedName ?? ""
    ]
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        return nil
    }

    if let nullIndex = buffer.firstIndex(of: 0) {
        buffer.removeSubrange(nullIndex...)
    }
    return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func machineArchitecture() -> String {
    var uts = utsname()
    uname(&uts)
    return withUnsafePointer(to: &uts.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
        }
    }
}

private func isoTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func rectPayload(_ rect: NSRect) -> [String: Double] {
    [
        "x": rect.origin.x,
        "y": rect.origin.y,
        "width": rect.width,
        "height": rect.height
    ]
}

private func pointPayload(_ point: CGPoint) -> [String: Double] {
    [
        "x": point.x,
        "y": point.y
    ]
}

private func rounded(_ value: Double, places: Double = 6) -> Double {
    let scale = pow(10, places)
    return (value * scale).rounded() / scale
}

private func deviceBuiltInPayload(_ isBuiltIn: Bool?) -> Any {
    isBuiltIn ?? "unavailable"
}

private func activeDisplayPayload() -> [[String: Any]] {
    var displayCount: UInt32 = 0
    let countError = CGGetActiveDisplayList(0, nil, &displayCount)
    guard countError == .success, displayCount > 0 else {
        return []
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    let listError = CGGetActiveDisplayList(displayCount, &displays, &displayCount)
    guard listError == .success else {
        return []
    }

    return displays.prefix(Int(displayCount)).enumerated().map { index, displayID in
        [
            "index": index,
            "id": displayID,
            "bounds": rectPayload(CGDisplayBounds(displayID)),
            "pixelsWide": CGDisplayPixelsWide(displayID),
            "pixelsHigh": CGDisplayPixelsHigh(displayID),
            "isMain": displayID == CGMainDisplayID()
        ]
    }
}

let options = ProbeOptions.parse(CommandLine.arguments)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let state = ProbeState(options: options)
state.start()

state.logger.write([
    "kind": "capture-started",
    "timestamp": isoTimestamp(),
    "durationSeconds": options.duration
])

DispatchQueue.main.asyncAfter(deadline: .now() + options.duration) {
    state.logger.write([
        "kind": "capture-ended",
        "timestamp": isoTimestamp()
    ])
    application.terminate(nil)
}

application.run()
