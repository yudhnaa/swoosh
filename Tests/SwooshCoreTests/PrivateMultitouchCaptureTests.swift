import Testing
@testable import SwooshCore

@Suite
struct PrivateMultitouchCaptureTests {
    @Test
    func recognizerEmitsSanitizedPinchFromSpreadChange() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        let began = recognizer.process(touches: twoTouches(spread: 0.20), context: context(frame: 1))
        let changed = recognizer.process(touches: twoTouches(spread: 0.12), context: context(frame: 2))
        let ended = recognizer.process(touches: [], context: context(frame: 3))

        #expect(began == [.began(CapturedGestureStart(pointer: pointer, modifiers: [.control], timestampMilliseconds: 1_000))])
        #expect(changed.count == 2)
        #expect(changed[0].isMovement == true)
        #expect(changed[1].progressKind == .pinch(.inward))
        #expect(ended.count == 1)
        #expect(ended[0].pinchDirection == .inward)
        #expect(ended[0].eventID?.hasPrefix("pinch-") == true)
    }

    @Test
    func recognizerEmitsSanitizedSwipeWhenCentroidMovesWithoutPinch() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerX: 0.20, centerY: 0.40, spread: 0.10), context: context(frame: 1))
        let changed = recognizer.process(touches: twoTouches(centerX: 0.44, centerY: 0.42, spread: 0.10), context: context(frame: 2))
        let ended = recognizer.process(touches: [], context: context(frame: 3))

        #expect(changed.count == 2)
        #expect(changed[0].isMovement == true)
        #expect(changed[1].progressKind == .stroke(.right))
        #expect(ended.count == 2)
        #expect(ended[0].strokeDirection == .right)
        #expect(ended[0].eventID?.hasPrefix("stroke-") == true)
        #expect(ended[1].isEnd == true)
    }

    @Test
    func recognizerSegmentsContinuousSwipeWhenMovementPauses() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerY: 0.20, spread: 0.10), context: context(frame: 1, timestamp: 1_000))
        _ = recognizer.process(touches: twoTouches(centerY: 0.44, spread: 0.10), context: context(frame: 2, timestamp: 1_040))
        let pause = recognizer.process(touches: twoTouches(centerY: 0.44, spread: 0.10), context: context(frame: 3, timestamp: 1_240))
        _ = recognizer.process(touches: twoTouches(centerY: 0.70, spread: 0.10), context: context(frame: 4, timestamp: 1_280))
        let ended = recognizer.process(touches: [], context: context(frame: 5, timestamp: 1_320))

        #expect(pause.count == 1)
        #expect(pause[0].strokeDirection == .up)
        #expect(ended.count == 2)
        #expect(ended[0].strokeDirection == .up)
        #expect(ended[1].isEnd == true)
    }

    @Test
    func recognizerSwitchesDirectionDuringContinuousReversal() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerX: 0.50, spread: 0.10), context: context(frame: 1))
        let left = recognizer.process(touches: twoTouches(centerX: 0.30, spread: 0.10), context: context(frame: 2))
        let right = recognizer.process(touches: twoTouches(centerX: 0.46, spread: 0.10), context: context(frame: 3))
        let ended = recognizer.process(touches: [], context: context(frame: 4))

        #expect(left.last?.progressKind == .stroke(.left))
        #expect(right.last?.progressKind == .stroke(.right))
        #expect(ended.count == 2)
        #expect(ended[0].strokeDirection == .right)
        #expect(ended[1].isEnd == true)
    }

    @Test
    func recognizerRebasesMultiStepContinuousTransitions() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerX: 0.50, centerY: 0.30, spread: 0.10), context: context(frame: 1))
        let up = recognizer.process(touches: twoTouches(centerX: 0.50, centerY: 0.50, spread: 0.10), context: context(frame: 2))
        let left = recognizer.process(touches: twoTouches(centerX: 0.30, centerY: 0.50, spread: 0.10), context: context(frame: 3))
        let right = recognizer.process(touches: twoTouches(centerX: 0.46, centerY: 0.50, spread: 0.10), context: context(frame: 4))
        let down = recognizer.process(touches: twoTouches(centerX: 0.46, centerY: 0.34, spread: 0.10), context: context(frame: 5))
        let ended = recognizer.process(touches: [], context: context(frame: 6))

        #expect(up.last?.progressKind == .stroke(.up))
        #expect(left.last?.progressKind == .stroke(.left))
        #expect(right.last?.progressKind == .stroke(.right))
        #expect(down.last?.progressKind == .stroke(.down))
        #expect(ended.count == 2)
        #expect(ended[0].strokeDirection == .down)
        #expect(ended[1].isEnd == true)
    }

    @Test
    func recognizerPrefersSwipeWhenCentroidMovementDominatesSpreadDrift() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerX: 0.70, centerY: 0.40, spread: 0.10), context: context(frame: 1))
        _ = recognizer.process(touches: twoTouches(centerX: 0.42, centerY: 0.40, spread: 0.17), context: context(frame: 2))
        let ended = recognizer.process(touches: [], context: context(frame: 3))

        #expect(ended.count == 2)
        #expect(ended[0].strokeDirection == .left)
        #expect(ended[0].pinchDirection == nil)
        #expect(ended[1].isEnd == true)
    }

    @Test
    func recognizerAllowsPinchWithSmallCentroidDrift() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerX: 0.50, centerY: 0.40, spread: 0.10), context: context(frame: 1))
        _ = recognizer.process(touches: twoTouches(centerX: 0.54, centerY: 0.41, spread: 0.18), context: context(frame: 2))
        let ended = recognizer.process(touches: [], context: context(frame: 3))

        #expect(ended.count == 1)
        #expect(ended[0].pinchDirection == .outward)
        #expect(ended[0].strokeDirection == nil)
    }

    @Test
    func recognizerEmitsTapForSubthresholdMovementAndCanStartAgain() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerX: 0.30, centerY: 0.30, spread: 0.10), context: context(frame: 1))
        _ = recognizer.process(touches: twoTouches(centerX: 0.32, centerY: 0.31, spread: 0.10), context: context(frame: 2))
        let tapped = recognizer.process(touches: [], context: context(frame: 3))
        let beganAgain = recognizer.process(touches: twoTouches(spread: 0.30), context: context(frame: 4))

        #expect(tapped.count == 1)
        #expect(tapped[0].isTap == true)
        #expect(tapped[0].eventID?.hasPrefix("tap-") == true)
        #expect(beganAgain.first?.isBegin == true)
    }

    @Test
    func sensitivityLowersSwipeThreshold() {
        var low = SwooshSettings.defaults
        low.sensitivity = 1
        var high = SwooshSettings.defaults
        high.sensitivity = 20

        let lowRecognizer = BuiltInTrackpadGestureRecognizer(settings: low)
        let highRecognizer = BuiltInTrackpadGestureRecognizer(settings: high)

        _ = lowRecognizer.process(touches: twoTouches(centerX: 0.20, spread: 0.10), context: context(frame: 1))
        _ = lowRecognizer.process(touches: twoTouches(centerX: 0.34, spread: 0.10), context: context(frame: 2))
        let lowEnded = lowRecognizer.process(touches: [], context: context(frame: 3))

        _ = highRecognizer.process(touches: twoTouches(centerX: 0.20, spread: 0.10), context: context(frame: 1))
        _ = highRecognizer.process(touches: twoTouches(centerX: 0.34, spread: 0.10), context: context(frame: 2))
        let highEnded = highRecognizer.process(touches: [], context: context(frame: 3))

        #expect(lowEnded.first?.isTap == true)
        #expect(highEnded.first?.strokeDirection == .right)
    }

    @Test
    func maximumSensitivityRecognizesShorterSwipeThanStandardMaximum() {
        var standardMaximum = SwooshSettings.defaults
        standardMaximum.sensitivity = 10
        var extraSensitive = SwooshSettings.defaults
        extraSensitive.sensitivity = 20

        let standardRecognizer = BuiltInTrackpadGestureRecognizer(settings: standardMaximum)
        let extraSensitiveRecognizer = BuiltInTrackpadGestureRecognizer(settings: extraSensitive)

        _ = standardRecognizer.process(touches: twoTouches(centerX: 0.20, spread: 0.10), context: context(frame: 1))
        _ = standardRecognizer.process(touches: twoTouches(centerX: 0.24, spread: 0.10), context: context(frame: 2))
        let standardEnded = standardRecognizer.process(touches: [], context: context(frame: 3))

        _ = extraSensitiveRecognizer.process(touches: twoTouches(centerX: 0.20, spread: 0.10), context: context(frame: 1))
        _ = extraSensitiveRecognizer.process(touches: twoTouches(centerX: 0.24, spread: 0.10), context: context(frame: 2))
        let extraSensitiveEnded = extraSensitiveRecognizer.process(touches: [], context: context(frame: 3))

        #expect(standardEnded.first?.isTap == true)
        #expect(extraSensitiveEnded.first?.strokeDirection == .right)
    }

    @Test
    func recognizerIgnoresThreeFingerGestureWhenInactive() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        let began = recognizer.process(touches: threeTouches(centerX: 0.40, spread: 0.10), context: context(frame: 1))
        let changed = recognizer.process(touches: threeTouches(centerX: 0.70, spread: 0.10), context: context(frame: 2))
        let ended = recognizer.process(touches: [], context: context(frame: 3))

        #expect(began.isEmpty)
        #expect(changed.isEmpty)
        #expect(ended.isEmpty)
    }

    @Test
    func recognizerCancelsActiveGestureWhenThirdFingerAppears() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(centerX: 0.30, spread: 0.10), context: context(frame: 1))
        let cancelled = recognizer.process(touches: threeTouches(centerX: 0.32, spread: 0.10), context: context(frame: 2))
        let beganAgain = recognizer.process(touches: twoTouches(centerX: 0.50, spread: 0.10), context: context(frame: 3))

        #expect(cancelled.count == 1)
        #expect(cancelled[0].cancelReason == .gestureCancelled)
        #expect(beganAgain.first?.isBegin == true)
    }

    @Test
    func routerKeepsBuiltInAndExternalRecognizersIndependent() {
        let router = MultitouchCaptureEventRouter()
        let builtIn = CapturedGestureSource(deviceID: "multitouch-1", generation: 3)
        let external = CapturedGestureSource(deviceID: "multitouch-2", generation: 3)
        router.register(key: "built-in", source: builtIn)
        router.register(key: "external", source: external)

        _ = router.process(
            key: "built-in",
            touches: twoTouches(centerX: 0.20, spread: 0.10),
            context: context(frame: 1, timestamp: 1_000)
        )
        _ = router.process(
            key: "external",
            touches: twoTouches(centerX: 0.70, spread: 0.10),
            context: context(frame: 1, timestamp: 1_010)
        )

        let builtInEnd = router.process(
            key: "built-in",
            touches: twoTouches(centerX: 0.44, spread: 0.10),
            context: context(frame: 2, timestamp: 1_020)
        ) + router.process(
            key: "built-in",
            touches: [],
            context: context(frame: 3, timestamp: 1_030)
        )
        let externalEnd = router.process(
            key: "external",
            touches: twoTouches(centerX: 0.42, spread: 0.10),
            context: context(frame: 2, timestamp: 1_040)
        ) + router.process(
            key: "external",
            touches: [],
            context: context(frame: 3, timestamp: 1_050)
        )

        #expect(builtInEnd.contains { $0.progressKind == .stroke(.right) })
        #expect(builtInEnd.contains { $0.strokeDirection == .right })
        #expect(builtInEnd.compactMap(\.eventID).allSatisfy { $0.hasPrefix("multitouch-1-g3-") })
        #expect(externalEnd.contains { $0.progressKind == .stroke(.left) })
        #expect(externalEnd.contains { $0.strokeDirection == .left })
        #expect(externalEnd.compactMap(\.eventID).allSatisfy { $0.hasPrefix("multitouch-2-g3-") })
    }

    @Test
    func routerDoesNotCombineContactsAcrossDevices() {
        let router = MultitouchCaptureEventRouter()
        router.register(key: "built-in", source: CapturedGestureSource(deviceID: "multitouch-1", generation: 4))
        router.register(key: "external", source: CapturedGestureSource(deviceID: "multitouch-2", generation: 4))

        let builtIn = router.process(
            key: "built-in",
            touches: [PrivateTouchSample(id: 1, state: 2, x: 0.20, y: 0.50)],
            context: context(frame: 1)
        )
        let external = router.process(
            key: "external",
            touches: [PrivateTouchSample(id: 1, state: 2, x: 0.80, y: 0.50)],
            context: context(frame: 1)
        )

        #expect(builtIn.isEmpty)
        #expect(external.isEmpty)
    }

    @Test
    func routerIgnoresUnknownDevicesAndHandlesZeroContactRelease() {
        let router = MultitouchCaptureEventRouter()
        let source = CapturedGestureSource(deviceID: "multitouch-1", generation: 5)
        router.register(key: "known", source: source)

        let unknown = router.process(
            key: "unknown",
            touches: twoTouches(centerX: 0.20, spread: 0.10),
            context: context(frame: 1)
        )
        let began = router.process(
            key: "known",
            touches: twoTouches(centerX: 0.20, spread: 0.10),
            context: context(frame: 1)
        )
        let ended = router.process(
            key: "known",
            touches: [],
            context: context(frame: 2)
        )

        #expect(unknown.isEmpty)
        #expect(began.first?.source == source)
        #expect(ended.count == 1)
        #expect(ended.first?.isTap == true)
        #expect(ended.first?.source == source)
    }

    @Test
    func ownershipGateIgnoresCompetingDeviceThroughRelease() {
        let gate = CaptureEventOwnershipGate()
        let first = CapturedGestureSource(deviceID: "multitouch-1", generation: 6)
        let second = CapturedGestureSource(deviceID: "multitouch-2", generation: 6)

        #expect(gate.shouldAccept(.began(CapturedGestureStart(source: first, pointer: pointer, modifiers: [], timestampMilliseconds: 1_000))))
        #expect(!gate.shouldAccept(.began(CapturedGestureStart(source: second, pointer: pointer, modifiers: [], timestampMilliseconds: 1_010))))
        #expect(!gate.shouldAccept(.strokeEnded(CapturedGestureStroke(source: second, direction: .left, pointer: pointer, modifiers: [], timestampMilliseconds: 1_020, eventID: "second"))))
        #expect(gate.shouldAccept(.strokeEnded(CapturedGestureStroke(source: first, direction: .right, pointer: pointer, modifiers: [], timestampMilliseconds: 1_030, eventID: "first"))))

        gate.releaseOwner(for: .strokeEnded(CapturedGestureStroke(source: first, direction: .right, pointer: pointer, modifiers: [], timestampMilliseconds: 1_030, eventID: "first")))

        #expect(gate.shouldAccept(.began(CapturedGestureStart(source: second, pointer: pointer, modifiers: [], timestampMilliseconds: 1_040))))
    }

    @Test
    func ownershipGateReleasesOwnerForTerminalTap() {
        let gate = CaptureEventOwnershipGate()
        let first = CapturedGestureSource(deviceID: "multitouch-1", generation: 7)
        let second = CapturedGestureSource(deviceID: "multitouch-2", generation: 7)

        #expect(gate.shouldAccept(.began(CapturedGestureStart(source: first, pointer: pointer, modifiers: [], timestampMilliseconds: 1_000))))

        gate.releaseOwner(for: .tapEnded(CapturedGestureTap(
            source: first,
            pointer: pointer,
            modifiers: [],
            timestampMilliseconds: 1_010,
            eventID: "first-tap"
        )))

        #expect(gate.shouldAccept(.began(CapturedGestureStart(source: second, pointer: pointer, modifiers: [], timestampMilliseconds: 1_020))))
    }

    private var pointer: ScreenPoint {
        ScreenPoint(x: 500, y: 300)
    }

    private func context(frame: Int, timestamp: Int = 1_000) -> CaptureRecognitionContext {
        CaptureRecognitionContext(
            pointer: pointer,
            modifiers: [.control],
            timestampMilliseconds: timestamp,
            frame: frame
        )
    }

    private func twoTouches(
        centerX: Double = 0.50,
        centerY: Double = 0.50,
        spread: Double
    ) -> [PrivateTouchSample] {
        [
            PrivateTouchSample(id: 1, state: 2, x: centerX - spread, y: centerY),
            PrivateTouchSample(id: 2, state: 2, x: centerX + spread, y: centerY)
        ]
    }

    private func threeTouches(
        centerX: Double = 0.50,
        centerY: Double = 0.50,
        spread: Double
    ) -> [PrivateTouchSample] {
        [
            PrivateTouchSample(id: 1, state: 2, x: centerX - spread, y: centerY),
            PrivateTouchSample(id: 2, state: 2, x: centerX + spread, y: centerY),
            PrivateTouchSample(id: 3, state: 2, x: centerX, y: centerY + spread)
        ]
    }
}

private extension CapturedGestureEvent {
    var isBegin: Bool {
        if case .began = self {
            return true
        }
        return false
    }

    var strokeDirection: GestureDirection? {
        if case .strokeEnded(let stroke) = self {
            return stroke.direction
        }
        return nil
    }

    var pinchDirection: GesturePinchDirection? {
        if case .pinchEnded(let pinch) = self {
            return pinch.direction
        }
        return nil
    }

    var eventID: String? {
        switch self {
        case .strokeEnded(let stroke):
            stroke.eventID
        case .pinchEnded(let pinch):
            pinch.eventID
        case .tapEnded(let tap):
            tap.eventID
        case .began, .movement, .deviceMovement, .changed, .ended, .deviceEnded, .cancelled, .deviceCancelled:
            nil
        }
    }

    var isTap: Bool {
        if case .tapEnded = self {
            return true
        }
        return false
    }

    var isMovement: Bool {
        if case .movement = self {
            return true
        }
        if case .deviceMovement = self {
            return true
        }
        return false
    }

    var isEnd: Bool {
        if case .ended = self {
            return true
        }
        if case .deviceEnded = self {
            return true
        }
        return false
    }

    var progressKind: CapturedGestureProgressKind? {
        if case .changed(let progress) = self {
            return progress.kind
        }
        return nil
    }

    var cancelReason: GestureCancelReason? {
        if case .cancelled(let reason, _) = self {
            return reason
        }
        if case .deviceCancelled(let cancellation) = self {
            return cancellation.reason
        }
        return nil
    }

}
