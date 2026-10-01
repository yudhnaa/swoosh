import AppKit
import CoreGraphics
import Darwin
import Foundation

public enum GestureCaptureSourceStatus: Equatable, Sendable {
    case stopped
    case running(PrivateCaptureDiagnostics)
    case failed(PrivateCaptureDiagnostics)
}

public struct CapturedGestureSource: Equatable, Hashable, Sendable {
    public var deviceID: String
    public var generation: Int

    public init(deviceID: String, generation: Int) {
        self.deviceID = deviceID
        self.generation = generation
    }

    public static let unspecified = CapturedGestureSource(deviceID: "unspecified", generation: 0)

    public var isSpecified: Bool {
        self != .unspecified
    }
}

public struct CapturedGestureStart: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int

    public init(
        source: CapturedGestureSource = .unspecified,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int
    ) {
        self.source = source
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public struct CapturedGestureStroke: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var direction: GestureDirection
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var eventID: String

    public init(
        source: CapturedGestureSource = .unspecified,
        direction: GestureDirection,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        eventID: String
    ) {
        self.source = source
        self.direction = direction
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
        self.eventID = eventID
    }
}

public struct CapturedGesturePinch: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var direction: GesturePinchDirection
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var eventID: String
    public var isCancelled: Bool

    public init(
        source: CapturedGestureSource = .unspecified,
        direction: GesturePinchDirection,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        eventID: String,
        isCancelled: Bool = false
    ) {
        self.source = source
        self.direction = direction
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
        self.eventID = eventID
        self.isCancelled = isCancelled
    }
}

public struct CapturedGestureTap: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var eventID: String

    public init(
        source: CapturedGestureSource = .unspecified,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        eventID: String
    ) {
        self.source = source
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
        self.eventID = eventID
    }
}

public enum CapturedGestureProgressKind: Equatable, Sendable {
    case stroke(GestureDirection)
    case pinch(GesturePinchDirection)
}

public struct CapturedGestureProgress: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var kind: CapturedGestureProgressKind
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int

    public init(
        source: CapturedGestureSource = .unspecified,
        kind: CapturedGestureProgressKind,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int
    ) {
        self.source = source
        self.kind = kind
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public struct CapturedGestureMovement: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var timestampMilliseconds: Int

    public init(source: CapturedGestureSource = .unspecified, timestampMilliseconds: Int) {
        self.source = source
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public struct CapturedGestureEnd: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var timestampMilliseconds: Int

    public init(source: CapturedGestureSource = .unspecified, timestampMilliseconds: Int) {
        self.source = source
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public struct CapturedGestureCancellation: Equatable, Sendable {
    public var source: CapturedGestureSource
    public var reason: GestureCancelReason
    public var timestampMilliseconds: Int

    public init(
        source: CapturedGestureSource = .unspecified,
        reason: GestureCancelReason,
        timestampMilliseconds: Int
    ) {
        self.source = source
        self.reason = reason
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public enum CapturedGestureEvent: Equatable, Sendable {
    case began(CapturedGestureStart)
    case movement(timestampMilliseconds: Int)
    case deviceMovement(CapturedGestureMovement)
    case changed(CapturedGestureProgress)
    case strokeEnded(CapturedGestureStroke)
    case pinchEnded(CapturedGesturePinch)
    case tapEnded(CapturedGestureTap)
    case ended(timestampMilliseconds: Int)
    case deviceEnded(CapturedGestureEnd)
    case cancelled(GestureCancelReason, timestampMilliseconds: Int)
    case deviceCancelled(CapturedGestureCancellation)

    public var source: CapturedGestureSource {
        switch self {
        case .began(let start):
            start.source
        case .movement:
            .unspecified
        case .deviceMovement(let movement):
            movement.source
        case .changed(let progress):
            progress.source
        case .strokeEnded(let stroke):
            stroke.source
        case .pinchEnded(let pinch):
            pinch.source
        case .tapEnded(let tap):
            tap.source
        case .ended:
            .unspecified
        case .deviceEnded(let end):
            end.source
        case .cancelled:
            .unspecified
        case .deviceCancelled(let cancellation):
            cancellation.source
        }
    }

    public var timestampMilliseconds: Int {
        switch self {
        case .began(let start):
            start.timestampMilliseconds
        case .movement(let timestampMilliseconds):
            timestampMilliseconds
        case .deviceMovement(let movement):
            movement.timestampMilliseconds
        case .changed(let progress):
            progress.timestampMilliseconds
        case .strokeEnded(let stroke):
            stroke.timestampMilliseconds
        case .pinchEnded(let pinch):
            pinch.timestampMilliseconds
        case .tapEnded(let tap):
            tap.timestampMilliseconds
        case .ended(let timestampMilliseconds):
            timestampMilliseconds
        case .deviceEnded(let end):
            end.timestampMilliseconds
        case .cancelled(_, let timestampMilliseconds):
            timestampMilliseconds
        case .deviceCancelled(let cancellation):
            cancellation.timestampMilliseconds
        }
    }
}

public protocol GestureCaptureSource: AnyObject {
    var status: GestureCaptureSourceStatus { get }
    var currentGeneration: Int { get }
    func start(handler: @escaping @Sendable (CapturedGestureEvent) -> Void) -> GestureCaptureSourceStatus
    func refreshDevices() -> GestureCaptureSourceStatus
    func stop()
}

public extension GestureCaptureSource {
    var currentGeneration: Int { 0 }

    func refreshDevices() -> GestureCaptureSourceStatus {
        status
    }
}

public final class PrivateMultitouchCaptureSource: GestureCaptureSource {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private var handle: UnsafeMutableRawPointer?
    private var devices: [RegisteredMTDevice] = []
    private var callbackContexts: [PrivateMultitouchDeviceCallbackContext] = []
    private var retiredCallbackContexts: [PrivateMultitouchDeviceCallbackContext] = []
    private var router = MultitouchCaptureEventRouter()
    private let settingsProvider: () -> SwooshSettings
    private let pointerProvider: () -> ScreenPoint
    private let modifierProvider: () -> Set<ModifierRole>
    private let lock = NSLock()
    private var handler: (@Sendable (CapturedGestureEvent) -> Void)?
    private var generation = 0
    private var nextDeviceOrdinal = 0

    private var createList: MTDeviceCreateListFn?
    private var registerWithRefcon: MTRegisterContactFrameCallbackWithRefconFn?
    private var registerWithoutRefcon: MTRegisterContactFrameCallbackFn?
    private var deviceStart: MTDeviceStartFn?
    private var deviceStop: MTDeviceStopFn?
    private var deviceIsBuiltIn: MTDeviceIsBuiltInFn?
    private var deviceGetDeviceID: MTDeviceGetDeviceIDFn?

    public private(set) var status: GestureCaptureSourceStatus = .stopped
    public var currentGeneration: Int {
        generation
    }

    public init(
        settingsProvider: @escaping () -> SwooshSettings = { .defaults },
        pointerProvider: @escaping () -> ScreenPoint = {
            let point = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
            return ScreenPoint(x: point.x, y: point.y)
        },
        modifierProvider: @escaping () -> Set<ModifierRole> = {
            PrivateMultitouchCaptureSource.currentModifierRoles()
        }
    ) {
        self.settingsProvider = settingsProvider
        self.pointerProvider = pointerProvider
        self.modifierProvider = modifierProvider
    }

    deinit {
        stop()
        if let handle {
            dlclose(handle)
        }
    }

    @discardableResult
    public func start(handler: @escaping @Sendable (CapturedGestureEvent) -> Void) -> GestureCaptureSourceStatus {
        stopDevices()
        generation += 1
        router.reset()
        self.handler = handler
        let settings = settingsProvider()

        guard loadFramework() else {
            let diagnostics = PrivateCaptureDiagnostics(
                frameworkAvailable: false,
                requiredSymbolsAvailable: false,
                deviceCount: 0,
                started: false,
                reason: "MultitouchSupport.framework could not be loaded."
            )
            status = .failed(diagnostics)
            return status
        }

        guard let createList, let deviceStart, let registerCallback = registerWithRefcon else {
            let diagnostics = PrivateCaptureDiagnostics(
                frameworkAvailable: true,
                requiredSymbolsAvailable: false,
                deviceCount: 0,
                started: false,
                reason: "Required private multitouch capture symbols are missing."
            )
            status = .failed(diagnostics)
            return status
        }

        guard let deviceArray = createList()?.takeUnretainedValue() else {
            let diagnostics = PrivateCaptureDiagnostics(
                frameworkAvailable: true,
                requiredSymbolsAvailable: true,
                deviceCount: 0,
                started: false,
                reason: "MTDeviceCreateList returned no devices."
            )
            status = .failed(diagnostics)
            return status
        }

        let count = CFArrayGetCount(deviceArray)
        var failedStarts = 0
        for index in 0..<count {
            guard let rawDevice = CFArrayGetValueAtIndex(deviceArray, index) else {
                continue
            }

            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            let key = deviceKey(for: device)
            if startDevice(device, key: key, settings: settings, registerCallback: registerCallback, deviceStart: deviceStart) {
            } else {
                failedStarts += 1
            }
        }

        let diagnostics = PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: count,
            startedDeviceCount: devices.count,
            failedDeviceCount: failedStarts,
            started: !devices.isEmpty,
            reason: Self.captureReason(deviceCount: count, startedCount: devices.count, failedCount: failedStarts)
        )
        status = devices.isEmpty ? .failed(diagnostics) : .running(diagnostics)
        return status
    }

    @discardableResult
    public func refreshDevices() -> GestureCaptureSourceStatus {
        guard handler != nil else {
            return status
        }

        guard loadFramework(),
              let createList,
              let deviceStart,
              let deviceStop,
              let registerCallback = registerWithRefcon,
              let deviceArray = createList()?.takeUnretainedValue()
        else {
            return status
        }

        let settings = settingsProvider()
        let enumeratedDevices = (0..<CFArrayGetCount(deviceArray)).compactMap { index -> MTDeviceRef? in
            guard let rawDevice = CFArrayGetValueAtIndex(deviceArray, index) else {
                return nil
            }
            return UnsafeMutableRawPointer(mutating: rawDevice)
        }
        let enumeratedByKey = Dictionary(uniqueKeysWithValues: enumeratedDevices.map { (deviceKey(for: $0), $0) })
        let enumeratedKeys = Set(enumeratedByKey.keys)
        let existingKeys = Set(devices.map(\.key))
        let removedKeys = existingKeys.subtracting(enumeratedKeys)
        let addedKeys = enumeratedKeys.subtracting(existingKeys)

        var cancellationEvents: [CapturedGestureEvent] = []
        if !removedKeys.isEmpty {
            for removed in devices where removedKeys.contains(removed.key) {
                _ = deviceStop(removed.device)
                cancellationEvents.append(contentsOf: router.retire(key: removed.key))
            }
            devices.removeAll { removedKeys.contains($0.key) }
        }

        var failedStarts = 0
        for key in addedKeys.sorted() {
            guard let device = enumeratedByKey[key],
                  startDevice(device, key: key, settings: settings, registerCallback: registerCallback, deviceStart: deviceStart)
            else {
                failedStarts += 1
                continue
            }
        }

        for event in cancellationEvents {
            handler?(event)
        }

        let diagnostics = PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: enumeratedDevices.count,
            startedDeviceCount: devices.count,
            failedDeviceCount: failedStarts,
            started: !devices.isEmpty,
            reason: Self.captureReason(deviceCount: enumeratedDevices.count, startedCount: devices.count, failedCount: failedStarts)
        )
        status = devices.isEmpty ? .failed(diagnostics) : .running(diagnostics)
        return status
    }

    public func stop() {
        stopDevices()
        generation += 1
        handler = nil
        router.reset()
        status = .stopped
    }

    fileprivate func handleFrame(
        key: String,
        source: CapturedGestureSource,
        touches rawPointer: UnsafeRawPointer?,
        count: Int,
        timestamp: Double,
        frame: Int
    ) {
        guard count >= 0 else {
            return
        }

        var samples: [PrivateTouchSample] = []
        if count > 0 {
            guard let rawPointer else {
                return
            }

            let pointer = rawPointer.assumingMemoryBound(to: MTTouch.self)
            samples.reserveCapacity(count)
            for index in 0..<count {
                let touch = pointer.advanced(by: index).pointee
                samples.append(PrivateTouchSample(
                    id: touch.fingerID,
                    state: touch.state,
                    x: Double(touch.normalizedVector.position.x),
                    y: Double(touch.normalizedVector.position.y)
                ))
            }
        }

        let baseContext = CaptureRecognitionContext(
            pointer: pointerProvider(),
            modifiers: modifierProvider(),
            timestampMilliseconds: Self.currentTimestampMilliseconds(),
            frame: frame
        )

        lock.lock()
        let events = router.process(
            key: key,
            expectedSource: source,
            touches: samples,
            context: baseContext
        )
        lock.unlock()

        for event in events {
            handler?(event)
        }
    }

    private func loadFramework() -> Bool {
        if handle == nil {
            handle = dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL)
        }
        guard let handle else {
            return false
        }

        createList = symbol(handle, "MTDeviceCreateList", as: MTDeviceCreateListFn.self)
        registerWithRefcon = symbol(handle, "MTRegisterContactFrameCallbackWithRefcon", as: MTRegisterContactFrameCallbackWithRefconFn.self)
        registerWithoutRefcon = symbol(handle, "MTRegisterContactFrameCallback", as: MTRegisterContactFrameCallbackFn.self)
        deviceStart = symbol(handle, "MTDeviceStart", as: MTDeviceStartFn.self)
        deviceStop = symbol(handle, "MTDeviceStop", as: MTDeviceStopFn.self)
        deviceIsBuiltIn = symbol(handle, "MTDeviceIsBuiltIn", as: MTDeviceIsBuiltInFn.self)
        deviceGetDeviceID = symbol(handle, "MTDeviceGetDeviceID", as: MTDeviceGetDeviceIDFn.self)
        return true
    }

    private func stopDevices() {
        guard let deviceStop else {
            devices.removeAll()
            callbackContexts.removeAll()
            router.reset()
            return
        }
        for device in devices {
            _ = deviceStop(device.device)
        }
        devices.removeAll()
        retiredCallbackContexts.append(contentsOf: callbackContexts)
        if retiredCallbackContexts.count > 64 {
            retiredCallbackContexts.removeFirst(retiredCallbackContexts.count - 64)
        }
        callbackContexts.removeAll()
        router.reset()
    }

    private func startDevice(
        _ device: MTDeviceRef,
        key: String,
        settings: SwooshSettings,
        registerCallback: MTRegisterContactFrameCallbackWithRefconFn,
        deviceStart: MTDeviceStartFn
    ) -> Bool {
        nextDeviceOrdinal += 1
        let source = CapturedGestureSource(deviceID: "multitouch-\(nextDeviceOrdinal)", generation: generation)
        let callbackContext = PrivateMultitouchDeviceCallbackContext(
            capture: self,
            key: key,
            source: source
        )
        callbackContexts.append(callbackContext)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(callbackContext).toOpaque())
        registerCallback(device, PrivateMultitouchCaptureBridge.callbackWithRefcon, refcon)
        guard deviceStart(device, 0) == 0 else {
            callbackContexts.removeAll { $0 === callbackContext }
            retiredCallbackContexts.append(callbackContext)
            return false
        }

        devices.append(RegisteredMTDevice(device: device, key: key, source: source))
        router.register(key: key, source: source, settings: settings)
        return true
    }

    private func deviceKey(for device: MTDeviceRef) -> String {
        var stableDeviceID: UInt64 = 0
        if let deviceGetDeviceID,
           deviceGetDeviceID(device, &stableDeviceID) == 0,
           stableDeviceID != 0 {
            return "id-\(stableDeviceID)"
        }

        return "ptr-\(String(UInt(bitPattern: device), radix: 16))"
    }

    private static func captureReason(deviceCount: Int, startedCount: Int, failedCount: Int) -> String {
        guard deviceCount > 0 else {
            return "No multitouch devices were reported."
        }
        guard startedCount > 0 else {
            return "No multitouch device could be started."
        }
        if failedCount > 0 {
            return "Private multitouch capture is running on \(startedCount) device(s); \(failedCount) device(s) failed to start."
        }
        return "Private multitouch capture is running on \(startedCount) device(s)."
    }

    private static func currentTimestampMilliseconds() -> Int {
        Int((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    static func currentTimestampMillisecondsForRouting() -> Int {
        currentTimestampMilliseconds()
    }

    public static func currentModifierRoles() -> Set<ModifierRole> {
        let flags = CGEvent(source: nil)?.flags ?? []
        var roles: Set<ModifierRole> = []
        if flags.contains(.maskControl) {
            roles.insert(.control)
        }
        if flags.contains(.maskCommand) {
            roles.insert(.command)
        }
        if flags.contains(.maskAlternate) {
            roles.insert(.option)
        }
        if flags.contains(.maskShift) {
            roles.insert(.shift)
        }
        if flags.contains(.maskSecondaryFn) {
            roles.insert(.function)
        }
        return roles
    }
}

extension PrivateMultitouchCaptureSource: LifecycleResource {
    public func shutdown() {
        stop()
    }
}

struct CaptureRecognitionContext: Equatable, Sendable {
    var source: CapturedGestureSource
    var pointer: ScreenPoint
    var modifiers: Set<ModifierRole>
    var timestampMilliseconds: Int
    var frame: Int

    init(
        source: CapturedGestureSource = .unspecified,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        frame: Int
    ) {
        self.source = source
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
        self.frame = frame
    }

    func eventID(kind: String, parts: String...) -> String {
        let suffix = ([kind] + parts).joined(separator: "-")
        guard source.isSpecified else {
            return suffix
        }
        return "\(source.deviceID)-g\(source.generation)-\(suffix)"
    }
}

struct PrivateTouchSample: Equatable, Sendable {
    var id: Int32
    var state: UInt32
    var x: Double
    var y: Double

    var isActive: Bool {
        state != 5 && state != 7
    }
}

final class BuiltInTrackpadGestureRecognizer {
    private var active = false
    private var began = false
    private var baseCentroid: TouchCentroid?
    private var lastCentroid: TouchCentroid?
    private var lastMovementCentroid: TouchCentroid?
    private var lastMovementTimestampMilliseconds: Int?
    private var strokeAnchorCentroid: TouchCentroid?
    private var pendingStrokeDirection: GestureDirection?
    private var pendingPinchDirection: GesturePinchDirection?
    private var sequence = 0
    private var segment = 0
    private let pinchThreshold: Double
    private let swipeThreshold: Double
    private let movementEpsilon = 0.006
    private let strokePauseThresholdMilliseconds = 180

    init(settings: SwooshSettings = .defaults) {
        let sensitivity = settings.normalized.sensitivity
        let standardSensitivitySteps = Double(min(sensitivity - 1, 9))
        let extraSensitivitySteps = Double(max(sensitivity - 10, 0))
        let standardPinchThreshold = max(0.010, 0.04 - (standardSensitivitySteps * 0.0035))
        let standardSwipeThreshold = max(0.050, 0.18 - (standardSensitivitySteps * 0.014))
        pinchThreshold = max(0.004, standardPinchThreshold - (extraSensitivitySteps * 0.0006))
        swipeThreshold = max(0.025, standardSwipeThreshold - (extraSensitivitySteps * 0.003))
    }

    func reset() {
        active = false
        began = false
        baseCentroid = nil
        lastCentroid = nil
        lastMovementCentroid = nil
        lastMovementTimestampMilliseconds = nil
        strokeAnchorCentroid = nil
        pendingStrokeDirection = nil
        pendingPinchDirection = nil
        segment = 0
    }

    func process(touches: [PrivateTouchSample], context: CaptureRecognitionContext) -> [CapturedGestureEvent] {
        let activeTouches = touches.filter(\.isActive)
        guard activeTouches.count == 2 else {
            if activeTouches.count > 2, active {
                reset()
                guard context.source.isSpecified else {
                    return [.cancelled(.gestureCancelled, timestampMilliseconds: context.timestampMilliseconds)]
                }
                return [.deviceCancelled(CapturedGestureCancellation(
                    source: context.source,
                    reason: .gestureCancelled,
                    timestampMilliseconds: context.timestampMilliseconds
                ))]
            }
            if activeTouches.count > 2 {
                return []
            }
            return finish(context: context)
        }

        guard let centroid = TouchCentroid(touches: activeTouches) else {
            return finish(context: context)
        }

        if !active {
            active = true
            began = true
            baseCentroid = centroid
            lastCentroid = centroid
            lastMovementCentroid = centroid
            lastMovementTimestampMilliseconds = context.timestampMilliseconds
            strokeAnchorCentroid = centroid
            sequence += 1
            return [.began(CapturedGestureStart(
                source: context.source,
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds
            ))]
        }

        var events: [CapturedGestureEvent] = []
        let moved = hasSignificantMovement(from: lastMovementCentroid, to: centroid)
        if moved {
            lastMovementCentroid = centroid
            lastMovementTimestampMilliseconds = context.timestampMilliseconds
            if context.source.isSpecified {
                events.append(.deviceMovement(CapturedGestureMovement(
                    source: context.source,
                    timestampMilliseconds: context.timestampMilliseconds
                )))
            } else {
                events.append(.movement(timestampMilliseconds: context.timestampMilliseconds))
            }
        }

        lastCentroid = centroid
        if let strokeDirection = pendingStrokeDirection,
           !moved,
           let lastMovementTimestampMilliseconds,
           context.timestampMilliseconds - lastMovementTimestampMilliseconds >= strokePauseThresholdMilliseconds {
            events.append(strokeEvent(direction: strokeDirection, context: context))
            baseCentroid = centroid
            lastMovementCentroid = centroid
            self.lastMovementTimestampMilliseconds = context.timestampMilliseconds
            strokeAnchorCentroid = centroid
            pendingStrokeDirection = nil
            pendingPinchDirection = nil
            return events
        }

        if moved, let progress = progressEvent(from: progressReferenceCentroid(), to: centroid, context: context) {
            switch progress {
            case .changed(let capturedProgress):
                switch capturedProgress.kind {
                case .stroke(let direction):
                    if pendingStrokeDirection != direction {
                        baseCentroid = progressReferenceCentroid()
                    }
                    pendingStrokeDirection = direction
                    pendingPinchDirection = nil
                    updateStrokeAnchor(for: direction, with: centroid)
                case .pinch(let direction):
                    pendingPinchDirection = direction
                    pendingStrokeDirection = nil
                    strokeAnchorCentroid = nil
                }
            default:
                break
            }
            events.append(progress)
        } else if moved, let pendingStrokeDirection {
            updateStrokeAnchor(for: pendingStrokeDirection, with: centroid)
        }

        return events
    }

    private func finish(context: CaptureRecognitionContext) -> [CapturedGestureEvent] {
        guard active, began, let base = baseCentroid, let last = lastCentroid else {
            reset()
            return []
        }

        defer { reset() }

        if let pendingPinchDirection {
            return [.pinchEnded(CapturedGesturePinch(
                source: context.source,
                direction: pendingPinchDirection,
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds,
                eventID: context.eventID(kind: "pinch", parts: "\(sequence)", "\(context.frame)")
            ))]
        }

        if let pendingStrokeDirection {
            let ended: CapturedGestureEvent = context.source.isSpecified
                ? .deviceEnded(CapturedGestureEnd(source: context.source, timestampMilliseconds: context.timestampMilliseconds))
                : .ended(timestampMilliseconds: context.timestampMilliseconds)
            return [
                strokeEvent(direction: pendingStrokeDirection, context: context),
                ended
            ]
        }

        if segment > 0 {
            guard context.source.isSpecified else {
                return [.ended(timestampMilliseconds: context.timestampMilliseconds)]
            }
            return [.deviceEnded(CapturedGestureEnd(
                source: context.source,
                timestampMilliseconds: context.timestampMilliseconds
            ))]
        }

        let dx = last.x - base.x
        let dy = last.y - base.y
        let travel = hypot(dx, dy)
        let spreadDelta = last.spread - base.spread
        let spreadTravel = abs(spreadDelta)
        let isPinchDominant = spreadTravel >= pinchThreshold &&
            (travel < swipeThreshold || spreadTravel >= travel * 0.70)

        if isPinchDominant {
            let pinchDirection: GesturePinchDirection = spreadDelta < 0 ? .inward : .outward
            return [.pinchEnded(CapturedGesturePinch(
                source: context.source,
                direction: pinchDirection,
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds,
                eventID: context.eventID(kind: "pinch", parts: "\(sequence)", "\(context.frame)")
            ))]
        }

        guard travel >= swipeThreshold else {
            return [.tapEnded(CapturedGestureTap(
                source: context.source,
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds,
                eventID: context.eventID(kind: "tap", parts: "\(sequence)", "\(context.frame)")
            ))]
        }

        let direction: GestureDirection
        if abs(dx) >= abs(dy) {
            direction = dx < 0 ? .left : .right
        } else {
            direction = dy < 0 ? .down : .up
        }

        let ended: CapturedGestureEvent = context.source.isSpecified
            ? .deviceEnded(CapturedGestureEnd(source: context.source, timestampMilliseconds: context.timestampMilliseconds))
            : .ended(timestampMilliseconds: context.timestampMilliseconds)
        return [
            strokeEvent(direction: direction, context: context),
            ended
        ]
    }

    private func progressEvent(
        from base: TouchCentroid?,
        to current: TouchCentroid,
        context: CaptureRecognitionContext
    ) -> CapturedGestureEvent? {
        guard let base else {
            return nil
        }

        let dx = current.x - base.x
        let dy = current.y - base.y
        let travel = hypot(dx, dy)
        let spreadDelta = current.spread - base.spread
        let spreadTravel = abs(spreadDelta)
        let isPinchDominant = spreadTravel >= pinchThreshold &&
            (travel < swipeThreshold || spreadTravel >= travel * 0.70)

        if isPinchDominant {
            let direction: GesturePinchDirection = spreadDelta < 0 ? .inward : .outward
            return .changed(CapturedGestureProgress(
                source: context.source,
                kind: .pinch(direction),
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds
            ))
        }

        guard travel >= swipeThreshold else {
            return nil
        }

        let direction: GestureDirection
        if abs(dx) >= abs(dy) {
            direction = dx < 0 ? .left : .right
        } else {
            direction = dy < 0 ? .down : .up
        }

        return .changed(CapturedGestureProgress(
            source: context.source,
            kind: .stroke(direction),
            pointer: context.pointer,
            modifiers: context.modifiers,
            timestampMilliseconds: context.timestampMilliseconds
        ))
    }

    private func strokeEvent(direction: GestureDirection, context: CaptureRecognitionContext) -> CapturedGestureEvent {
        segment += 1
        return .strokeEnded(CapturedGestureStroke(
            source: context.source,
            direction: direction,
            pointer: context.pointer,
            modifiers: context.modifiers,
            timestampMilliseconds: context.timestampMilliseconds,
            eventID: context.eventID(kind: "stroke", parts: "\(sequence)", "\(segment)", "\(context.frame)")
        ))
    }

    private func hasSignificantMovement(from previous: TouchCentroid?, to current: TouchCentroid) -> Bool {
        guard let previous else {
            return true
        }

        return hypot(current.x - previous.x, current.y - previous.y) >= movementEpsilon
            || abs(current.spread - previous.spread) >= movementEpsilon
    }

    private func progressReferenceCentroid() -> TouchCentroid? {
        pendingStrokeDirection == nil ? baseCentroid : strokeAnchorCentroid ?? baseCentroid
    }

    private func updateStrokeAnchor(for direction: GestureDirection, with centroid: TouchCentroid) {
        guard let anchor = strokeAnchorCentroid else {
            strokeAnchorCentroid = centroid
            return
        }

        switch direction {
        case .left:
            if centroid.x < anchor.x {
                strokeAnchorCentroid = centroid
            }
        case .right:
            if centroid.x > anchor.x {
                strokeAnchorCentroid = centroid
            }
        case .up:
            if centroid.y > anchor.y {
                strokeAnchorCentroid = centroid
            }
        case .down:
            if centroid.y < anchor.y {
                strokeAnchorCentroid = centroid
            }
        }
    }
}

private typealias MTDeviceRef = UnsafeMutableRawPointer

private struct RegisteredMTDevice {
    var device: MTDeviceRef
    var key: String
    var source: CapturedGestureSource
}

private final class PrivateMultitouchDeviceCallbackContext {
    weak var capture: PrivateMultitouchCaptureSource?
    var key: String
    var source: CapturedGestureSource

    init(capture: PrivateMultitouchCaptureSource, key: String, source: CapturedGestureSource) {
        self.capture = capture
        self.key = key
        self.source = source
    }
}

final class MultitouchCaptureEventRouter {
    private var devices: [String: RoutedCaptureDevice] = [:]

    func register(key: String, source: CapturedGestureSource, settings: SwooshSettings = .defaults) {
        devices[key] = RoutedCaptureDevice(
            source: source,
            recognizer: BuiltInTrackpadGestureRecognizer(settings: settings)
        )
    }

    func reset() {
        devices.removeAll()
    }

    func retire(key: String) -> [CapturedGestureEvent] {
        guard let device = devices.removeValue(forKey: key) else {
            return []
        }

        return [.deviceCancelled(CapturedGestureCancellation(
            source: device.source,
            reason: .captureFailed,
            timestampMilliseconds: PrivateMultitouchCaptureSource.currentTimestampMillisecondsForRouting()
        ))]
    }

    func process(
        key: String,
        expectedSource: CapturedGestureSource? = nil,
        touches: [PrivateTouchSample],
        context: CaptureRecognitionContext
    ) -> [CapturedGestureEvent] {
        guard let device = devices[key],
              expectedSource == nil || device.source == expectedSource,
              device.source.generation == context.source.generation || context.source == .unspecified
        else {
            return []
        }

        let sourcedContext = CaptureRecognitionContext(
            source: device.source,
            pointer: context.pointer,
            modifiers: context.modifiers,
            timestampMilliseconds: context.timestampMilliseconds,
            frame: context.frame
        )
        let events = device.recognizer.process(touches: touches, context: sourcedContext)
        return events
    }
}

private struct RoutedCaptureDevice {
    var source: CapturedGestureSource
    var recognizer: BuiltInTrackpadGestureRecognizer
}

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

private enum PrivateMultitouchCaptureBridge {
    nonisolated(unsafe) static let callbackWithRefcon: MTFrameCallbackWithRefcon = { _, touches, count, timestamp, frame, refcon in
        guard let refcon else {
            return
        }
        let context = Unmanaged<PrivateMultitouchDeviceCallbackContext>.fromOpaque(refcon).takeUnretainedValue()
        context.capture?.handleFrame(
            key: context.key,
            source: context.source,
            touches: touches,
            count: count,
            timestamp: timestamp,
            frame: frame
        )
    }
}

private struct TouchCentroid: Equatable, Sendable {
    var x: Double
    var y: Double
    var spread: Double

    init?(touches: [PrivateTouchSample]) {
        guard touches.count >= 2 else {
            return nil
        }

        let centroidX = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let centroidY = touches.map(\.y).reduce(0, +) / Double(touches.count)
        x = centroidX
        y = centroidY
        spread = touches
            .map { hypot($0.x - centroidX, $0.y - centroidY) }
            .reduce(0, +) / Double(touches.count)
    }
}

private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let symbol = dlsym(handle, name) else {
        return nil
    }
    return unsafeBitCast(symbol, to: type)
}
