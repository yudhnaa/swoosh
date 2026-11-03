import AppKit
import CoreGraphics
import Darwin
import Foundation

public enum GestureCaptureSourceStatus: Equatable, Sendable {
    case stopped
    case running(PrivateCaptureDiagnostics)
    case failed(PrivateCaptureDiagnostics)
}

public struct GestureCaptureSnapshot: Equatable, Sendable {
    public var status: GestureCaptureSourceStatus
    public var generation: Int

    public init(status: GestureCaptureSourceStatus, generation: Int) {
        self.status = status
        self.generation = generation
    }

    public static let stopped = GestureCaptureSnapshot(status: .stopped, generation: 0)
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
    public var inwardSegmentCount: Int
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int
    public var eventID: String
    public var isCancelled: Bool

    public init(
        source: CapturedGestureSource = .unspecified,
        direction: GesturePinchDirection,
        inwardSegmentCount: Int? = nil,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int,
        eventID: String,
        isCancelled: Bool = false
    ) {
        self.source = source
        self.direction = direction
        self.inwardSegmentCount = inwardSegmentCount ?? (direction == .inward ? 1 : 0)
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
    public var inwardSegmentCount: Int
    public var pointer: ScreenPoint
    public var modifiers: Set<ModifierRole>
    public var timestampMilliseconds: Int

    public init(
        source: CapturedGestureSource = .unspecified,
        kind: CapturedGestureProgressKind,
        inwardSegmentCount: Int? = nil,
        pointer: ScreenPoint,
        modifiers: Set<ModifierRole>,
        timestampMilliseconds: Int
    ) {
        self.source = source
        self.kind = kind
        self.inwardSegmentCount = inwardSegmentCount ?? {
            if case .pinch(.inward) = kind {
                return 1
            }
            return 0
        }()
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

@MainActor
public protocol GestureCaptureSource: AnyObject {
    var snapshot: GestureCaptureSnapshot { get }
    func start(handler: @escaping @MainActor @Sendable (CapturedGestureEvent) -> Void) -> GestureCaptureSourceStatus
    func refreshDevices() -> GestureCaptureSourceStatus
    func stop()
}

public extension GestureCaptureSource {
    var status: GestureCaptureSourceStatus { snapshot.status }
    var currentGeneration: Int { snapshot.generation }

    func refreshDevices() -> GestureCaptureSourceStatus {
        status
    }
}

@MainActor
public final class PrivateMultitouchCaptureSource: GestureCaptureSource {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private nonisolated static let nativeOwnership = NativeMultitouchCaptureOwnership()

    private let worker: PrivateMultitouchCaptureWorker
    private var router = MultitouchCaptureEventRouter()
    private let settingsProvider: () -> SwooshSettings
    private let pointerProvider: () -> ScreenPoint
    private let modifierProvider: () -> Set<ModifierRole>
    private let ownershipToken = UUID()
    private var handler: (@MainActor @Sendable (CapturedGestureEvent) -> Void)?
    private var generation = 0
    private var ownsNativeCapture = false

    public private(set) var snapshot: GestureCaptureSnapshot = .stopped

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
        self.worker = PrivateMultitouchCaptureWorker()
    }

    init(
        settingsProvider: @escaping () -> SwooshSettings = { .defaults },
        pointerProvider: @escaping () -> ScreenPoint = {
            let point = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
            return ScreenPoint(x: point.x, y: point.y)
        },
        modifierProvider: @escaping () -> Set<ModifierRole> = {
            PrivateMultitouchCaptureSource.currentModifierRoles()
        },
        worker: PrivateMultitouchCaptureWorker
    ) {
        self.settingsProvider = settingsProvider
        self.pointerProvider = pointerProvider
        self.modifierProvider = modifierProvider
        self.worker = worker
    }

    deinit {
        if ownsNativeCapture {
            Self.nativeOwnership.release(ownershipToken)
        }
        worker.teardown()
    }

    @discardableResult
    public func start(handler: @escaping @MainActor @Sendable (CapturedGestureEvent) -> Void) -> GestureCaptureSourceStatus {
        if self.handler != nil, case .running = snapshot.status {
            return snapshot.status
        }

        invalidateGeneration()
        self.handler = nil
        worker.stop()
        releaseNativeOwnership()
        router.reset()

        guard Self.nativeOwnership.acquire(ownershipToken) else {
            return failStart(
                frameworkAvailable: worker.isFrameworkLoaded,
                requiredSymbolsAvailable: false,
                reason: "Private multitouch capture is already owned by another runtime."
            )
        }
        ownsNativeCapture = true
        self.handler = handler
        let settings = settingsProvider()

        let currentGeneration = generation
        let frameSink: @Sendable (String, CapturedGestureSource, [PrivateTouchSample], Int) -> Void = { [weak self] key, source, samples, frame in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleFrame(key: key, source: source, samples: samples, frame: frame)
                }
            }
        }

        let result = worker.start(
            generation: currentGeneration,
            settings: settings,
            frameSink: frameSink
        )

        for device in result.startedDevices {
            router.register(key: device.key, source: device.source, settings: settings)
        }

        updateSnapshot(result.status)
        return result.status
    }

    @discardableResult
    public func refreshDevices() -> GestureCaptureSourceStatus {
        guard handler != nil else {
            return status
        }

        let settings = settingsProvider()
        guard let result = worker.refreshDevices(generation: generation, settings: settings) else {
            return status
        }

        var cancellationEvents: [CapturedGestureEvent] = []
        for removedKey in result.removedKeys {
            cancellationEvents.append(contentsOf: router.retire(key: removedKey))
        }

        for added in result.addedDevices {
            router.register(key: added.key, source: added.source, settings: settings)
        }

        for event in cancellationEvents {
            handler?(event)
        }

        updateSnapshot(result.status)
        return result.status
    }

    public func stop() {
        guard handler != nil || ownsNativeCapture || snapshot.status != .stopped else {
            return
        }

        invalidateGeneration()
        handler = nil
        worker.stop()
        releaseNativeOwnership()
        router.reset()
        updateSnapshot(.stopped)
    }

    private func handleFrame(
        key: String,
        source: CapturedGestureSource,
        samples: [PrivateTouchSample],
        frame: Int
    ) {
        guard source.generation == generation, handler != nil else {
            return
        }

        let baseContext = CaptureRecognitionContext(
            pointer: pointerProvider(),
            modifiers: modifierProvider(),
            timestampMilliseconds: Self.currentTimestampMilliseconds(),
            frame: frame
        )

        let events = router.process(
            key: key,
            expectedSource: source,
            touches: samples,
            context: baseContext
        )

        let handler = self.handler
        for event in events {
            handler?(event)
        }
    }

    private func failStart(
        frameworkAvailable: Bool,
        requiredSymbolsAvailable: Bool,
        reason: String
    ) -> GestureCaptureSourceStatus {
        worker.stop()
        handler = nil
        releaseNativeOwnership()
        let diagnostics = PrivateCaptureDiagnostics(
            frameworkAvailable: frameworkAvailable,
            requiredSymbolsAvailable: requiredSymbolsAvailable,
            deviceCount: 0,
            started: false,
            reason: reason
        )
        let status = GestureCaptureSourceStatus.failed(diagnostics)
        updateSnapshot(status)
        return status
    }

    private func invalidateGeneration() {
        generation += 1
        updateSnapshot(snapshot.status)
    }

    private func updateSnapshot(_ status: GestureCaptureSourceStatus) {
        snapshot = GestureCaptureSnapshot(status: status, generation: generation)
    }

    private func releaseNativeOwnership() {
        guard ownsNativeCapture else {
            return
        }
        Self.nativeOwnership.release(ownershipToken)
        ownsNativeCapture = false
    }

    private nonisolated static func currentTimestampMilliseconds() -> Int {
        Int((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    nonisolated static func currentTimestampMillisecondsForRouting() -> Int {
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
    private var pendingInwardPinchSegments = 0
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
        pinchThreshold = max(0.004, standardPinchThreshold - (extraSensitivitySteps * 0.0006)) * 1.4
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
        pendingInwardPinchSegments = 0
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
            pendingInwardPinchSegments = 0
            return events
        }

        if let pinchDirection = pendingPinchDirection,
           (pinchDirection == .inward || pendingInwardPinchSegments > 0),
           !moved,
           let lastMovementTimestampMilliseconds,
           context.timestampMilliseconds - lastMovementTimestampMilliseconds >= strokePauseThresholdMilliseconds {
            pendingInwardPinchSegments = completedInwardPinchSegments(including: pinchDirection)
            baseCentroid = centroid
            lastMovementCentroid = centroid
            self.lastMovementTimestampMilliseconds = context.timestampMilliseconds
            pendingPinchDirection = nil
            strokeAnchorCentroid = nil
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
                    pendingInwardPinchSegments = 0
                    updateStrokeAnchor(for: direction, with: centroid)
                case .pinch(let direction):
                    if let pendingPinchDirection,
                       pendingPinchDirection != direction,
                       pendingPinchDirection == .inward,
                       direction == .outward {
                        pendingInwardPinchSegments += 1
                        baseCentroid = centroid
                        self.pendingPinchDirection = direction
                    } else if pendingPinchDirection != direction {
                        baseCentroid = centroid
                        pendingPinchDirection = direction
                    } else {
                        pendingPinchDirection = direction
                    }
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
            let direction = resolvedPinchDirection(for: pendingPinchDirection)
            return [.pinchEnded(CapturedGesturePinch(
                source: context.source,
                direction: direction,
                inwardSegmentCount: completedInwardPinchSegments(including: direction),
                pointer: context.pointer,
                modifiers: context.modifiers,
                timestampMilliseconds: context.timestampMilliseconds,
                eventID: context.eventID(kind: "pinch", parts: "\(sequence)", "\(context.frame)")
            ))]
        }

        if pendingInwardPinchSegments > 0 {
            return [.pinchEnded(CapturedGesturePinch(
                source: context.source,
                direction: .inward,
                inwardSegmentCount: pendingInwardPinchSegments,
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
                inwardSegmentCount: completedInwardPinchSegments(including: pinchDirection),
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
                inwardSegmentCount: completedInwardPinchSegments(including: direction),
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

    private func pinchEvent(direction: GesturePinchDirection, context: CaptureRecognitionContext) -> CapturedGestureEvent {
        segment += 1
        let direction = resolvedPinchDirection(for: direction)
        return .pinchEnded(CapturedGesturePinch(
            source: context.source,
            direction: direction,
            inwardSegmentCount: completedInwardPinchSegments(including: direction),
            pointer: context.pointer,
            modifiers: context.modifiers,
            timestampMilliseconds: context.timestampMilliseconds,
            eventID: context.eventID(kind: "pinch", parts: "\(sequence)", "\(segment)", "\(context.frame)")
        ))
    }

    private func completedInwardPinchSegments(including direction: GesturePinchDirection) -> Int {
        pendingInwardPinchSegments + (direction == .inward ? 1 : 0)
    }

    private func resolvedPinchDirection(for direction: GesturePinchDirection) -> GesturePinchDirection {
        if direction == .outward, pendingInwardPinchSegments > 0 {
            return .inward
        }
        return direction
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

typealias MTDeviceRef = UnsafeMutableRawPointer

struct RegisteredMTDevice: @unchecked Sendable {
    var device: MTDeviceRef
    var key: String
    var source: CapturedGestureSource
}

typealias MTFrameCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeRawPointer?,
    Int,
    Double,
    Int
) -> Void

typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
typealias MTRegisterContactFrameCallbackFn = @convention(c) (MTDeviceRef?, MTFrameCallback?) -> Void
typealias MTUnregisterContactFrameCallbackFn = @convention(c) (MTDeviceRef?, MTFrameCallback?) -> Void
typealias MTDeviceStartFn = @convention(c) (MTDeviceRef?, Int32) -> Int32
typealias MTDeviceStopFn = @convention(c) (MTDeviceRef?) -> Int32
typealias MTDeviceIsBuiltInFn = @convention(c) (MTDeviceRef?) -> Bool
typealias MTDeviceGetDeviceIDFn = @convention(c) (MTDeviceRef?, UnsafeMutablePointer<UInt64>?) -> Int32

struct MultitouchSupportSymbols: @unchecked Sendable {
    var createList: MTDeviceCreateListFn?
    var registerWithoutRefcon: MTRegisterContactFrameCallbackFn?
    var unregisterWithoutRefcon: MTUnregisterContactFrameCallbackFn?
    var deviceStart: MTDeviceStartFn?
    var deviceStop: MTDeviceStopFn?
    var deviceIsBuiltIn: MTDeviceIsBuiltInFn?
    var deviceGetDeviceID: MTDeviceGetDeviceIDFn?

    var hasRequiredSymbols: Bool {
        createList != nil &&
        registerWithoutRefcon != nil &&
        unregisterWithoutRefcon != nil &&
        deviceStart != nil &&
        deviceStop != nil
    }
}

struct WorkerDeviceDescriptor: Equatable, Sendable {
    var key: String
    var source: CapturedGestureSource
}

struct WorkerStartResult: Sendable {
    var status: GestureCaptureSourceStatus
    var startedDevices: [WorkerDeviceDescriptor]
}

struct WorkerRefreshResult: Sendable {
    var removedKeys: Set<String>
    var addedDevices: [WorkerDeviceDescriptor]
    var status: GestureCaptureSourceStatus
}

final class PrivateMultitouchCaptureWorker: @unchecked Sendable {
    private static let defaultFrameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let frameworkPath: String
    private var symbols: MultitouchSupportSymbols?
    private let isMockSymbols: Bool

    private var handle: UnsafeMutableRawPointer?
    private var devices: [RegisteredMTDevice] = []
    private var nextDeviceOrdinal = 0
    private var frameSink: (@Sendable (String, CapturedGestureSource, [PrivateTouchSample], Int) -> Void)?

    init(
        frameworkPath: String = defaultFrameworkPath,
        symbols: MultitouchSupportSymbols? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.swoosh.private-multitouch-capture.worker", qos: .userInteractive)
    ) {
        self.frameworkPath = frameworkPath
        self.symbols = symbols
        self.isMockSymbols = symbols != nil
        self.queue = queue
        queue.setSpecific(key: queueKey, value: ())
    }

    var isFrameworkLoaded: Bool {
        performSync {
            handle != nil || isMockSymbols
        }
    }

    var isCurrentQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    var registeredDevices: [RegisteredMTDevice] {
        performSync {
            devices
        }
    }

    func performSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        } else {
            return try queue.sync(execute: work)
        }
    }

    func performAsync(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private func assertOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    func start(
        generation: Int,
        settings: SwooshSettings,
        frameSink: @escaping @Sendable (String, CapturedGestureSource, [PrivateTouchSample], Int) -> Void
    ) -> WorkerStartResult {
        performSync {
            assertOnQueue()
            stopDevicesInternal()
            self.frameSink = frameSink

            guard loadFramework() else {
                return WorkerStartResult(
                    status: .failed(PrivateCaptureDiagnostics(
                        frameworkAvailable: false,
                        requiredSymbolsAvailable: false,
                        deviceCount: 0,
                        started: false,
                        reason: "MultitouchSupport.framework could not be loaded."
                    )),
                    startedDevices: []
                )
            }

            guard let symbols,
                  symbols.hasRequiredSymbols,
                  let createList = symbols.createList
            else {
                return WorkerStartResult(
                    status: .failed(PrivateCaptureDiagnostics(
                        frameworkAvailable: true,
                        requiredSymbolsAvailable: false,
                        deviceCount: 0,
                        started: false,
                        reason: "Required private multitouch capture symbols are missing."
                    )),
                    startedDevices: []
                )
            }

            guard let deviceArray = createList()?.takeUnretainedValue() else {
                return WorkerStartResult(
                    status: .failed(PrivateCaptureDiagnostics(
                        frameworkAvailable: true,
                        requiredSymbolsAvailable: true,
                        deviceCount: 0,
                        started: false,
                        reason: "MTDeviceCreateList returned no devices."
                    )),
                    startedDevices: []
                )
            }

            let enumerated = enumeratedDeviceMap(from: deviceArray)
            var failedStarts = 0
            var startedDevices: [WorkerDeviceDescriptor] = []

            for key in enumerated.keys.sorted() {
                guard let device = enumerated[key],
                      let descriptor = startDevice(device, key: key, generation: generation, settings: settings, symbols: symbols)
                else {
                    failedStarts += 1
                    continue
                }
                startedDevices.append(descriptor)
            }

            let diagnostics = PrivateCaptureDiagnostics(
                frameworkAvailable: true,
                requiredSymbolsAvailable: true,
                deviceCount: enumerated.count,
                startedDeviceCount: devices.count,
                failedDeviceCount: failedStarts,
                started: !devices.isEmpty,
                reason: captureReason(deviceCount: enumerated.count, startedCount: devices.count, failedCount: failedStarts)
            )
            let status: GestureCaptureSourceStatus = devices.isEmpty ? .failed(diagnostics) : .running(diagnostics)
            return WorkerStartResult(status: status, startedDevices: startedDevices)
        }
    }

    func refreshDevices(generation: Int, settings: SwooshSettings) -> WorkerRefreshResult? {
        performSync {
            assertOnQueue()
            guard loadFramework(),
                  let symbols,
                  symbols.hasRequiredSymbols,
                  let createList = symbols.createList,
                  let deviceArray = createList()?.takeUnretainedValue()
            else {
                return nil
            }

            let enumeratedByKey = enumeratedDeviceMap(from: deviceArray)
            let enumeratedKeys = Set(enumeratedByKey.keys)
            let existingKeys = Set(devices.map(\.key))
            let plan = CaptureDeviceReconciliationPlan(
                enumeratedKeys: Array(enumeratedKeys),
                existingKeys: existingKeys
            )
            let replacedKeys = Set(devices.compactMap { registered -> String? in
                guard let replacement = enumeratedByKey[registered.key], replacement != registered.device else {
                    return nil
                }
                return registered.key
            })
            let removedKeys = plan.removedKeys.union(replacedKeys)
            let addedKeys = plan.addedKeys.union(replacedKeys)

            if !removedKeys.isEmpty {
                for removed in devices where removedKeys.contains(removed.key) {
                    stopDevice(removed, symbols: symbols)
                }
                devices.removeAll { removedKeys.contains($0.key) }
            }

            var failedStarts = 0
            var addedDevices: [WorkerDeviceDescriptor] = []
            for key in addedKeys.sorted() {
                guard let device = enumeratedByKey[key],
                      let descriptor = startDevice(device, key: key, generation: generation, settings: settings, symbols: symbols)
                else {
                    failedStarts += 1
                    continue
                }
                addedDevices.append(descriptor)
            }

            let diagnostics = PrivateCaptureDiagnostics(
                frameworkAvailable: true,
                requiredSymbolsAvailable: true,
                deviceCount: enumeratedByKey.count,
                startedDeviceCount: devices.count,
                failedDeviceCount: failedStarts,
                started: !devices.isEmpty,
                reason: captureReason(deviceCount: enumeratedByKey.count, startedCount: devices.count, failedCount: failedStarts)
            )
            let status: GestureCaptureSourceStatus = devices.isEmpty ? .failed(diagnostics) : .running(diagnostics)
            return WorkerRefreshResult(
                removedKeys: removedKeys,
                addedDevices: addedDevices,
                status: status
            )
        }
    }

    func stop() {
        performSync {
            assertOnQueue()
            stopDevicesInternal()
            frameSink = nil
        }
    }

    func teardown() {
        performSync {
            assertOnQueue()
            stopDevicesInternal()
            frameSink = nil
            if let handle {
                dlclose(handle)
                self.handle = nil
            }
            if !isMockSymbols {
                symbols = nil
            }
        }
    }

    private func stopDevicesInternal() {
        assertOnQueue()
        if let symbols {
            for device in devices {
                stopDevice(device, symbols: symbols)
            }
        } else {
            for device in devices {
                PrivateMultitouchCaptureBridge.registry.remove(device: device.device)
            }
        }
        devices.removeAll()
    }

    private func startDevice(
        _ device: MTDeviceRef,
        key: String,
        generation: Int,
        settings: SwooshSettings,
        symbols: MultitouchSupportSymbols
    ) -> WorkerDeviceDescriptor? {
        assertOnQueue()
        guard let registerWithoutRefcon = symbols.registerWithoutRefcon,
              let unregisterWithoutRefcon = symbols.unregisterWithoutRefcon,
              let deviceStart = symbols.deviceStart
        else {
            return nil
        }

        nextDeviceOrdinal += 1
        let source = CapturedGestureSource(deviceID: "multitouch-\(nextDeviceOrdinal)", generation: generation)
        let frameSink = self.frameSink
        let registration = PrivateMultitouchCallbackRegistration { samples, frame in
            frameSink?(key, source, samples, frame)
        }

        guard PrivateMultitouchCaptureBridge.registry.insert(registration, device: device) else {
            return nil
        }
        registerWithoutRefcon(device, PrivateMultitouchCaptureBridge.callback)
        guard deviceStart(device, 0) == 0 else {
            unregisterWithoutRefcon(device, PrivateMultitouchCaptureBridge.callback)
            PrivateMultitouchCaptureBridge.registry.remove(device: device)
            return nil
        }

        devices.append(RegisteredMTDevice(device: device, key: key, source: source))
        return WorkerDeviceDescriptor(key: key, source: source)
    }

    private func stopDevice(_ registered: RegisteredMTDevice, symbols: MultitouchSupportSymbols) {
        assertOnQueue()
        _ = symbols.deviceStop?(registered.device)
        symbols.unregisterWithoutRefcon?(registered.device, PrivateMultitouchCaptureBridge.callback)
        PrivateMultitouchCaptureBridge.registry.remove(device: registered.device)
    }

    private func loadFramework() -> Bool {
        assertOnQueue()
        if isMockSymbols {
            return symbols != nil
        }
        if handle == nil {
            handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL)
        }
        guard let handle else {
            return false
        }

        if symbols == nil {
            symbols = MultitouchSupportSymbols(
                createList: symbol(handle, "MTDeviceCreateList", as: MTDeviceCreateListFn.self),
                registerWithoutRefcon: symbol(handle, "MTRegisterContactFrameCallback", as: MTRegisterContactFrameCallbackFn.self),
                unregisterWithoutRefcon: symbol(handle, "MTUnregisterContactFrameCallback", as: MTUnregisterContactFrameCallbackFn.self),
                deviceStart: symbol(handle, "MTDeviceStart", as: MTDeviceStartFn.self),
                deviceStop: symbol(handle, "MTDeviceStop", as: MTDeviceStopFn.self),
                deviceIsBuiltIn: symbol(handle, "MTDeviceIsBuiltIn", as: MTDeviceIsBuiltInFn.self),
                deviceGetDeviceID: symbol(handle, "MTDeviceGetDeviceID", as: MTDeviceGetDeviceIDFn.self)
            )
        }
        return true
    }

    private func deviceKey(for device: MTDeviceRef) -> String {
        assertOnQueue()
        var stableDeviceID: UInt64 = 0
        if let deviceGetDeviceID = symbols?.deviceGetDeviceID,
           deviceGetDeviceID(device, &stableDeviceID) == 0,
           stableDeviceID != 0 {
            return "id-\(stableDeviceID)-ptr-\(String(UInt(bitPattern: device), radix: 16))"
        }

        return "ptr-\(String(UInt(bitPattern: device), radix: 16))"
    }

    private func enumeratedDeviceMap(from array: CFArray) -> [String: MTDeviceRef] {
        assertOnQueue()
        var result: [String: MTDeviceRef] = [:]
        for index in 0..<CFArrayGetCount(array) {
            guard let rawDevice = CFArrayGetValueAtIndex(array, index) else {
                continue
            }
            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            let key = deviceKey(for: device)
            result[key] = result[key] ?? device
        }
        return result
    }

    private func captureReason(deviceCount: Int, startedCount: Int, failedCount: Int) -> String {
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
}

final class NativeMultitouchCaptureOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?

    func acquire(_ candidate: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil || owner == candidate else {
            return false
        }
        owner = candidate
        return true
    }

    func release(_ candidate: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if owner == candidate {
            owner = nil
        }
    }

    var isOwned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return owner != nil
    }
}

struct CaptureDeviceReconciliationPlan: Equatable, Sendable {
    var uniqueEnumeratedKeys: Set<String>
    var duplicateKeys: Set<String>
    var addedKeys: Set<String>
    var removedKeys: Set<String>

    init(enumeratedKeys: [String], existingKeys: Set<String>) {
        var unique: Set<String> = []
        var duplicates: Set<String> = []
        for key in enumeratedKeys {
            if !unique.insert(key).inserted {
                duplicates.insert(key)
            }
        }

        uniqueEnumeratedKeys = unique
        duplicateKeys = duplicates
        addedKeys = unique.subtracting(existingKeys)
        removedKeys = existingKeys.subtracting(unique)
    }
}

final class PrivateMultitouchCallbackRegistration: @unchecked Sendable {
    private let delivery: @Sendable ([PrivateTouchSample], Int) -> Void

    init(delivery: @escaping @Sendable ([PrivateTouchSample], Int) -> Void) {
        self.delivery = delivery
    }

    func deliver(_ samples: [PrivateTouchSample], frame: Int) {
        delivery(samples, frame)
    }
}

final class PrivateMultitouchCallbackRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [UInt: PrivateMultitouchCallbackRegistration] = [:]

    func insert(_ registration: PrivateMultitouchCallbackRegistration, device: MTDeviceRef) -> Bool {
        let key = UInt(bitPattern: device)
        lock.lock()
        defer { lock.unlock() }
        guard registrations[key] == nil else {
            return false
        }
        registrations[key] = registration
        return true
    }

    func registration(device: MTDeviceRef) -> PrivateMultitouchCallbackRegistration? {
        let key = UInt(bitPattern: device)
        lock.lock()
        defer { lock.unlock() }
        return registrations[key]
    }

    func remove(device: MTDeviceRef) {
        let key = UInt(bitPattern: device)
        lock.lock()
        registrations.removeValue(forKey: key)
        lock.unlock()
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

enum PrivateMultitouchCaptureBridge {
    static let registry = PrivateMultitouchCallbackRegistry()

    nonisolated(unsafe) static let callback: MTFrameCallback = { device, touches, count, _, frame in
        guard count >= 0, let device, let registration = registry.registration(device: device) else {
            return
        }

        var samples: [PrivateTouchSample] = []
        if count > 0 {
            guard let touches else {
                return
            }
            let pointer = touches.assumingMemoryBound(to: MTTouch.self)
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

        registration.deliver(samples, frame: frame)
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
