import AppKit
import CoreGraphics
import Darwin
import Foundation

public enum GestureCaptureSourceStatus: Equatable, Sendable {
    case stopped
    case running(PrivateCaptureDiagnostics)
    case failed(PrivateCaptureDiagnostics)
}

public struct CapturedGestureStart: Equatable, Sendable {
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int

    public init(pointer: ScreenPoint, modifiers: Set<ModifierRole>, timestampMilliseconds: Int) {
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public struct CapturedGestureStroke: Equatable, Sendable {
    public var direction: GestureDirection
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var eventID: String

    public init(
        direction: GestureDirection,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        eventID: String
    ) {
        self.direction = direction
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
        self.eventID = eventID
    }
}

public struct CapturedGesturePinch: Equatable, Sendable {
    public var direction: GesturePinchDirection
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var eventID: String
    public var isCancelled: Bool

    public init(
        direction: GesturePinchDirection,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        eventID: String,
        isCancelled: Bool = false
    ) {
        self.direction = direction
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
        self.eventID = eventID
        self.isCancelled = isCancelled
    }
}

public struct CapturedGestureTap: Equatable, Sendable {
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var eventID: String

    public init(
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        eventID: String
    ) {
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
    public var kind: CapturedGestureProgressKind
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int

    public init(
        kind: CapturedGestureProgressKind,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int
    ) {
        self.kind = kind
        self.pointer = pointer
        self.modifiers = modifiers
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public enum CapturedGestureEvent: Equatable, Sendable {
    case began(CapturedGestureStart)
    case movement(timestampMilliseconds: Int)
    case changed(CapturedGestureProgress)
    case strokeEnded(CapturedGestureStroke)
    case pinchEnded(CapturedGesturePinch)
    case tapEnded(CapturedGestureTap)
    case ended(timestampMilliseconds: Int)
    case cancelled(GestureCancelReason, timestampMilliseconds: Int)
}

public protocol GestureCaptureSource: AnyObject {
    var status: GestureCaptureSourceStatus { get }
    func start(handler: @escaping @Sendable (CapturedGestureEvent) -> Void) -> GestureCaptureSourceStatus
    func stop()
}

public final class PrivateMultitouchCaptureSource: GestureCaptureSource {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private var handle: UnsafeMutableRawPointer?
    private var devices: [MTDeviceRef] = []
    private var recognizer: BuiltInTrackpadGestureRecognizer
    private let settingsProvider: () -> SwooshSettings
    private let pointerProvider: () -> ScreenPoint
    private let modifierProvider: () -> Set<ModifierRole>
    private let lock = NSLock()
    private var handler: (@Sendable (CapturedGestureEvent) -> Void)?

    private var createList: MTDeviceCreateListFn?
    private var registerWithRefcon: MTRegisterContactFrameCallbackWithRefconFn?
    private var registerWithoutRefcon: MTRegisterContactFrameCallbackFn?
    private var deviceStart: MTDeviceStartFn?
    private var deviceStop: MTDeviceStopFn?
    private var deviceIsBuiltIn: MTDeviceIsBuiltInFn?
    private var deviceGetDeviceID: MTDeviceGetDeviceIDFn?

    public private(set) var status: GestureCaptureSourceStatus = .stopped

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
        recognizer = BuiltInTrackpadGestureRecognizer(settings: settingsProvider())
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
        recognizer = BuiltInTrackpadGestureRecognizer(settings: settingsProvider())
        self.handler = handler

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

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let count = CFArrayGetCount(deviceArray)
        for index in 0..<count {
            guard let rawDevice = CFArrayGetValueAtIndex(deviceArray, index) else {
                continue
            }

            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            if let deviceIsBuiltIn, !deviceIsBuiltIn(device) {
                continue
            }

            registerCallback(device, PrivateMultitouchCaptureBridge.callbackWithRefcon, refcon)
            if deviceStart(device, 0) == 0 {
                devices.append(device)
            }
        }

        let diagnostics = PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: count,
            started: !devices.isEmpty,
            reason: devices.isEmpty ? "No built-in multitouch device could be started." : "Built-in multitouch capture is running."
        )
        status = devices.isEmpty ? .failed(diagnostics) : .running(diagnostics)
        return status
    }

    public func stop() {
        stopDevices()
        handler = nil
        recognizer.reset()
        status = .stopped
    }

    fileprivate func handleFrame(touches rawPointer: UnsafeRawPointer?, count: Int, timestamp: Double, frame: Int) {
        guard let rawPointer else {
            return
        }

        let pointer = rawPointer.assumingMemoryBound(to: MTTouch.self)
        var samples: [PrivateTouchSample] = []
        samples.reserveCapacity(max(0, count))
        for index in 0..<max(0, count) {
            let touch = pointer.advanced(by: index).pointee
            samples.append(PrivateTouchSample(
                id: touch.fingerID,
                state: touch.state,
                x: Double(touch.normalizedVector.position.x),
                y: Double(touch.normalizedVector.position.y)
            ))
        }

        let context = CaptureRecognitionContext(
            pointer: pointerProvider(),
            modifiers: modifierProvider(),
            timestampMilliseconds: Self.currentTimestampMilliseconds(),
            frame: frame
        )

        lock.lock()
        let events = recognizer.process(touches: samples, context: context)
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
            return
        }
        for device in devices {
            _ = deviceStop(device)
        }
        devices.removeAll()
    }

    private static func currentTimestampMilliseconds() -> Int {
        Int((Date().timeIntervalSince1970 * 1_000).rounded())
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
    var pointer: ScreenPoint
    var modifiers: Set<ModifierRole>
    var timestampMilliseconds: Int
    var frame: Int
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
                return [.cancelled(.gestureCancelled, timestampMilliseconds: context.timestampMilliseconds)]
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
            events.append(.movement(timestampMilliseconds: context.timestampMilliseconds))
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
                direction: pendingPinchDirection,
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds,
                eventID: "pinch-\(sequence)-\(context.frame)"
            ))]
        }

        if let pendingStrokeDirection {
            return [
                strokeEvent(direction: pendingStrokeDirection, context: context),
                .ended(timestampMilliseconds: context.timestampMilliseconds)
            ]
        }

        if segment > 0 {
            return [.ended(timestampMilliseconds: context.timestampMilliseconds)]
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
                direction: pinchDirection,
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds,
                eventID: "pinch-\(sequence)-\(context.frame)"
            ))]
        }

        guard travel >= swipeThreshold else {
            return [.tapEnded(CapturedGestureTap(
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds,
                eventID: "tap-\(sequence)-\(context.frame)"
            ))]
        }

        let direction: GestureDirection
        if abs(dx) >= abs(dy) {
            direction = dx < 0 ? .left : .right
        } else {
            direction = dy < 0 ? .down : .up
        }

        return [
            strokeEvent(direction: direction, context: context),
            .ended(timestampMilliseconds: context.timestampMilliseconds)
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
            kind: .stroke(direction),
            pointer: context.pointer,
            modifiers: context.modifiers,
            timestampMilliseconds: context.timestampMilliseconds
        ))
    }

    private func strokeEvent(direction: GestureDirection, context: CaptureRecognitionContext) -> CapturedGestureEvent {
        segment += 1
        return .strokeEnded(CapturedGestureStroke(
            direction: direction,
            pointer: context.pointer,
            modifiers: context.modifiers,
            timestampMilliseconds: context.timestampMilliseconds,
            eventID: "stroke-\(sequence)-\(segment)-\(context.frame)"
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
        let capture = Unmanaged<PrivateMultitouchCaptureSource>.fromOpaque(refcon).takeUnretainedValue()
        capture.handleFrame(touches: touches, count: count, timestamp: timestamp, frame: frame)
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
