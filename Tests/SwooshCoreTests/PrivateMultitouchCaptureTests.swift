import Foundation
import Testing
@testable import SwooshCore

@Suite(.serialized)
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
    func recognizerSegmentsContinuousInwardPinchesOnOutwardReset() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(spread: 0.24), context: context(frame: 1, timestamp: 1_000))
        _ = recognizer.process(touches: twoTouches(spread: 0.14), context: context(frame: 2, timestamp: 1_040))
        let outwardReset = recognizer.process(touches: twoTouches(spread: 0.24), context: context(frame: 3, timestamp: 1_080))
        let secondPinch = recognizer.process(touches: twoTouches(spread: 0.14), context: context(frame: 4, timestamp: 1_120))
        let ended = recognizer.process(touches: [], context: context(frame: 5, timestamp: 1_160))

        #expect(!outwardReset.contains { $0.pinchDirection == .inward })
        #expect(secondPinch.last?.progressKind == .pinch(.inward))
        #expect(secondPinch.last?.progressInwardSegmentCount == 2)
        #expect(ended.count == 1)
        #expect(ended[0].pinchDirection == .inward)
        #expect(ended[0].inwardSegmentCount == 2)
    }

    @Test
    func recognizerDoesNotEmitPinchActionDuringFingerDownPause() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(spread: 0.24), context: context(frame: 1, timestamp: 1_000))
        _ = recognizer.process(touches: twoTouches(spread: 0.14), context: context(frame: 2, timestamp: 1_040))
        let paused = recognizer.process(touches: twoTouches(spread: 0.14), context: context(frame: 3, timestamp: 1_240))
        let ended = recognizer.process(touches: [], context: context(frame: 4, timestamp: 1_280))

        #expect(!paused.contains { $0.pinchDirection == .inward })
        #expect(ended.count == 1)
        #expect(ended[0].pinchDirection == .inward)
    }

    @Test
    func recognizerCountsPauseSeparatedInwardPinchesWithoutFingerRelease() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(spread: 0.24), context: context(frame: 1, timestamp: 1_000))
        _ = recognizer.process(touches: twoTouches(spread: 0.14), context: context(frame: 2, timestamp: 1_040))
        let paused = recognizer.process(touches: twoTouches(spread: 0.14), context: context(frame: 3, timestamp: 1_240))
        let secondPinch = recognizer.process(touches: twoTouches(spread: 0.06), context: context(frame: 4, timestamp: 1_280))
        let ended = recognizer.process(touches: [], context: context(frame: 5, timestamp: 1_320))

        #expect(!paused.contains { $0.pinchDirection == .inward })
        #expect(secondPinch.last?.progressKind == .pinch(.inward))
        #expect(secondPinch.last?.progressInwardSegmentCount == 2)
        #expect(ended.count == 1)
        #expect(ended[0].pinchDirection == .inward)
        #expect(ended[0].inwardSegmentCount == 2)
    }

    @Test
    func recognizerDoesNotCommitSmallPinchBelowRaisedThreshold() {
        let recognizer = BuiltInTrackpadGestureRecognizer()

        _ = recognizer.process(touches: twoTouches(spread: 0.20), context: context(frame: 1))
        _ = recognizer.process(touches: twoTouches(spread: 0.16), context: context(frame: 2))
        let ended = recognizer.process(touches: [], context: context(frame: 3))

        #expect(ended.count == 1)
        #expect(ended[0].isTap == true)
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

        gate.drainOwnerUntilTerminal()
        #expect(!gate.shouldAccept(.began(CapturedGestureStart(source: second, pointer: pointer, modifiers: [], timestampMilliseconds: 1_040))))
        #expect(!gate.shouldAccept(.deviceEnded(CapturedGestureEnd(source: second, timestampMilliseconds: 1_050))))
        #expect(!gate.shouldAccept(.deviceEnded(CapturedGestureEnd(source: first, timestampMilliseconds: 1_060))))
        #expect(gate.shouldAccept(.began(CapturedGestureStart(source: second, pointer: pointer, modifiers: [], timestampMilliseconds: 1_070))))
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

    @Test
    func ownershipGateDrainsCompetingPhysicalContactsBeforeReacquiring() {
        let gate = CaptureEventOwnershipGate()
        let owner = CapturedGestureSource(deviceID: "multitouch-1", generation: 8)
        let competitor = CapturedGestureSource(deviceID: "multitouch-2", generation: 8)
        let lateCompetitor = CapturedGestureSource(deviceID: "multitouch-3", generation: 8)

        #expect(gate.shouldAccept(.began(CapturedGestureStart(source: owner, pointer: pointer, modifiers: [], timestampMilliseconds: 1_000))))
        #expect(!gate.shouldAccept(.began(CapturedGestureStart(source: competitor, pointer: pointer, modifiers: [], timestampMilliseconds: 1_010))))
        #expect(gate.physicalState == .owned(owner))

        gate.releaseOwner(for: .deviceEnded(CapturedGestureEnd(source: owner, timestampMilliseconds: 1_020)))
        #expect(gate.physicalState == .draining([competitor]))
        #expect(!gate.shouldAccept(.began(CapturedGestureStart(source: lateCompetitor, pointer: pointer, modifiers: [], timestampMilliseconds: 1_030))))
        #expect(gate.physicalState == .draining([competitor, lateCompetitor]))

        #expect(!gate.shouldAccept(.deviceEnded(CapturedGestureEnd(source: competitor, timestampMilliseconds: 1_040))))
        #expect(gate.physicalState == .draining([lateCompetitor]))
        #expect(!gate.shouldAccept(.deviceEnded(CapturedGestureEnd(source: lateCompetitor, timestampMilliseconds: 1_050))))
        #expect(gate.physicalState == .idle)
        #expect(gate.shouldAccept(.began(CapturedGestureStart(source: competitor, pointer: pointer, modifiers: [], timestampMilliseconds: 1_060))))
    }

    @Test
    func nativeCaptureOwnershipAllowsOnlyOneRuntimeAtATime() {
        let ownership = NativeMultitouchCaptureOwnership()
        let first = UUID()
        let second = UUID()

        #expect(ownership.acquire(first))
        #expect(ownership.acquire(first))
        #expect(!ownership.acquire(second))
        ownership.release(second)
        #expect(ownership.isOwned)
        ownership.release(first)
        #expect(!ownership.isOwned)
        #expect(ownership.acquire(second))
    }

    @Test
    func deviceReconciliationDeduplicatesKeysWithoutTrapping() {
        let plan = CaptureDeviceReconciliationPlan(
            enumeratedKeys: ["built-in", "external", "built-in", "external"],
            existingKeys: ["built-in", "removed"]
        )

        #expect(plan.uniqueEnumeratedKeys == ["built-in", "external"])
        #expect(plan.duplicateKeys == ["built-in", "external"])
        #expect(plan.addedKeys == ["external"])
        #expect(plan.removedKeys == ["removed"])
    }

    @Test
    func captureSnapshotKeepsStatusAndGenerationAtomic() {
        let diagnostics = PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: 2,
            startedDeviceCount: 2,
            started: true,
            reason: "running"
        )
        let snapshot = GestureCaptureSnapshot(status: .running(diagnostics), generation: 11)

        #expect(snapshot.status == .running(diagnostics))
        #expect(snapshot.generation == 11)
    }

    @Test
    func callbackRegistryDropsLateLookupAfterUnregister() {
        let registry = PrivateMultitouchCallbackRegistry()
        let device = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { device.deallocate() }
        let registration = PrivateMultitouchCallbackRegistration { _, _ in }

        #expect(registry.insert(registration, device: device))
        #expect(registry.registration(device: device) != nil)
        registry.remove(device: device)
        #expect(registry.registration(device: device) == nil)
    }

    @Test
    func pointerReuseCannotRouteInflightCallbackToNewRegistration() {
        let registry = PrivateMultitouchCallbackRegistry()
        let device = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { device.deallocate() }
        let first = CallbackDeliveryRecorder()
        let second = CallbackDeliveryRecorder()
        let firstRegistration = PrivateMultitouchCallbackRegistration { _, _ in first.record() }
        let secondRegistration = PrivateMultitouchCallbackRegistration { _, _ in second.record() }

        #expect(registry.insert(firstRegistration, device: device))
        let inflight = registry.registration(device: device)
        registry.remove(device: device)
        #expect(registry.insert(secondRegistration, device: device))

        inflight?.deliver([], frame: 1)
        #expect(first.count == 1)
        #expect(second.count == 0)

        registry.registration(device: device)?.deliver([], frame: 2)
        #expect(first.count == 1)
        #expect(second.count == 1)
    }

    @Test
    func workerExecutesTasksSeriallyAndInFIFOOrder() {
        let worker = PrivateMultitouchCaptureWorker()
        let recorder = WorkerExecutionRecorder()

        let iterations = 20
        for i in 0..<iterations {
            if i % 2 == 0 {
                worker.performAsync {
                    #expect(worker.isCurrentQueue)
                    recorder.record(i)
                }
            } else {
                worker.performSync {
                    #expect(worker.isCurrentQueue)
                    recorder.record(i)
                }
            }
        }

        worker.performSync {
            #expect(worker.isCurrentQueue)
        }

        #expect(recorder.values == Array(0..<iterations))
    }

    @Test
    func workerPerformSyncAvoidsReentrancyDeadlock() {
        let worker = PrivateMultitouchCaptureWorker()

        let result = worker.performSync {
            #expect(worker.isCurrentQueue)
            let inner1 = worker.performSync {
                #expect(worker.isCurrentQueue)
                let inner2 = worker.performSync {
                    #expect(worker.isCurrentQueue)
                    return 42
                }
                return inner2 + 10
            }
            return inner1 + 100
        }

        #expect(result == 152)
    }

    @Test
    func workerLifecycleStartsAndStopsDevicesWithMockSymbols() {
        let storage = MockMTDeviceStorage.shared
        storage.reset()
        let device1 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let device2 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            device1.deallocate()
            device2.deallocate()
            storage.reset()
        }
        storage.devices = [device1, device2]
        storage.deviceIDs = [
            UInt(bitPattern: device1): 101,
            UInt(bitPattern: device2): 102
        ]

        let symbols = mockMultitouchSymbols()
        let worker = PrivateMultitouchCaptureWorker(symbols: symbols)

        let startResult = worker.start(generation: 1, settings: .defaults) { _, _, _, _ in }
        guard case .running(let diagnostics) = startResult.status else {
            Issue.record("Expected worker to be running")
            return
        }

        #expect(diagnostics.deviceCount == 2)
        #expect(diagnostics.startedDeviceCount == 2)
        #expect(diagnostics.failedDeviceCount == 0)
        #expect(storage.startedDevices == [device1, device2])
        #expect(storage.registeredDevices == [device1, device2])
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device1) != nil)
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device2) != nil)

        worker.stop()
        #expect(storage.stoppedDevices == [device1, device2])
        #expect(storage.unregisteredDevices == [device1, device2])
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device1) == nil)
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device2) == nil)

        worker.teardown()
    }

    @Test
    func workerPartialFailureReportsDiagnosticsAndRetainsWorkingDevices() {
        let storage = MockMTDeviceStorage.shared
        storage.reset()
        let device1 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let device2 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            device1.deallocate()
            device2.deallocate()
            storage.reset()
        }
        storage.devices = [device1, device2]
        storage.failStartFor = [device2]

        let symbols = mockMultitouchSymbols()
        let worker = PrivateMultitouchCaptureWorker(symbols: symbols)

        let startResult = worker.start(generation: 2, settings: .defaults) { _, _, _, _ in }
        guard case .running(let diagnostics) = startResult.status else {
            Issue.record("Expected worker to be running partially")
            return
        }

        #expect(diagnostics.deviceCount == 2)
        #expect(diagnostics.startedDeviceCount == 1)
        #expect(diagnostics.failedDeviceCount == 1)
        #expect(diagnostics.reason.contains("1 device(s) failed to start"))
        #expect(startResult.startedDevices.count == 1)
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device1) != nil)
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device2) == nil)

        worker.stop()
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device1) == nil)
    }

    @Test
    func workerZeroDeviceFailureReportsFailedStatus() {
        let storage = MockMTDeviceStorage.shared
        storage.reset()
        let device1 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            device1.deallocate()
            storage.reset()
        }
        storage.devices = [device1]
        storage.failStartFor = [device1]

        let symbols = mockMultitouchSymbols()
        let worker = PrivateMultitouchCaptureWorker(symbols: symbols)

        let startResult = worker.start(generation: 3, settings: .defaults) { _, _, _, _ in }
        guard case .failed(let diagnostics) = startResult.status else {
            Issue.record("Expected worker to report failure when all devices fail")
            return
        }

        #expect(diagnostics.startedDeviceCount == 0)
        #expect(diagnostics.failedDeviceCount == 1)
        #expect(!diagnostics.started)
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device1) == nil)

        worker.stop()
    }

    @Test
    func workerReconciliationHandlesAddedAndRemovedDevices() {
        let storage = MockMTDeviceStorage.shared
        storage.reset()
        let device1 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let device2 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let device3 = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            device1.deallocate()
            device2.deallocate()
            device3.deallocate()
            storage.reset()
        }
        storage.devices = [device1, device2]
        storage.deviceIDs = [
            UInt(bitPattern: device1): 201,
            UInt(bitPattern: device2): 202,
            UInt(bitPattern: device3): 203
        ]

        let symbols = mockMultitouchSymbols()
        let worker = PrivateMultitouchCaptureWorker(symbols: symbols)

        _ = worker.start(generation: 4, settings: .defaults) { _, _, _, _ in }
        #expect(worker.registeredDevices.count == 2)

        // Reconcile: device1 is removed, device3 is added
        storage.devices = [device2, device3]
        guard let refresh = worker.refreshDevices(generation: 4, settings: .defaults) else {
            Issue.record("Expected refresh result")
            return
        }

        #expect(refresh.removedKeys.count == 1)
        #expect(refresh.addedDevices.count == 1)
        #expect(storage.stoppedDevices.contains(device1))
        #expect(storage.unregisteredDevices.contains(device1))
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device1) == nil)
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device2) != nil)
        #expect(PrivateMultitouchCaptureBridge.registry.registration(device: device3) != nil)

        worker.stop()
    }

    @Test
    @MainActor
    func captureSourceStartAndStopAreIdempotent() {
        let storage = MockMTDeviceStorage.shared
        storage.reset()
        let device = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            device.deallocate()
            storage.reset()
        }
        storage.devices = [device]
        storage.deviceIDs = [UInt(bitPattern: device): 300]

        let worker = PrivateMultitouchCaptureWorker(symbols: mockMultitouchSymbols())
        let source = PrivateMultitouchCaptureSource(worker: worker)

        let first = source.start { _ in }
        let generationAfterFirstStart = source.currentGeneration
        let second = source.start { _ in }

        #expect(first == second)
        #expect(source.currentGeneration == generationAfterFirstStart)
        #expect(storage.startedDevices == [device])
        #expect(storage.registeredDevices == [device])

        source.stop()
        let generationAfterFirstStop = source.currentGeneration
        source.stop()

        #expect(source.currentGeneration == generationAfterFirstStop)
        #expect(storage.stoppedDevices == [device])
        #expect(storage.unregisteredDevices == [device])
    }

    @Test
    @MainActor
    func captureSourceRejectsQueuedFramesFromStaleGeneration() async {
        let storage = MockMTDeviceStorage.shared
        storage.reset()
        let device = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            device.deallocate()
            storage.reset()
        }
        storage.devices = [device]
        storage.deviceIDs = [UInt(bitPattern: device): 301]

        let symbols = mockMultitouchSymbols()
        let worker = PrivateMultitouchCaptureWorker(symbols: symbols)
        let source = PrivateMultitouchCaptureSource(
            settingsProvider: { .defaults },
            pointerProvider: { ScreenPoint(x: 100, y: 100) },
            modifierProvider: { [] },
            worker: worker
        )

        let recorder = EventListRecorder()
        let status = source.start { event in
            recorder.record(event)
        }
        guard case .running = status else {
            Issue.record("Expected source running")
            return
        }
        #expect(source.currentGeneration == 1)

        guard let reg = PrivateMultitouchCaptureBridge.registry.registration(device: device) else {
            Issue.record("Expected registration")
            return
        }

        // Send two touches for began gesture
        reg.deliver([
            PrivateTouchSample(id: 1, state: 2, x: 0.40, y: 0.50),
            PrivateTouchSample(id: 2, state: 2, x: 0.60, y: 0.50)
        ], frame: 1)

        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.isBegin == true)

        // Stop the source: generation increments to 2 and handler is cleared
        source.stop()
        #expect(source.currentGeneration == 2)
        #expect(source.snapshot.status == .stopped)
        #expect(source.snapshot.generation == 2)

        // Late delivery with stale registration
        reg.deliver([
            PrivateTouchSample(id: 1, state: 2, x: 0.40, y: 0.50),
            PrivateTouchSample(id: 2, state: 2, x: 0.60, y: 0.50)
        ], frame: 2)

        try? await Task.sleep(nanoseconds: 30_000_000)
        // No new events received
        #expect(recorder.events.count == 1)
    }

    @Test
    @MainActor
    func captureSourcePreservesFIFOOrderOnMainActor() async {
        let storage = MockMTDeviceStorage.shared
        storage.reset()
        let device = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            device.deallocate()
            storage.reset()
        }
        storage.devices = [device]
        storage.deviceIDs = [UInt(bitPattern: device): 401]

        let symbols = mockMultitouchSymbols()
        let worker = PrivateMultitouchCaptureWorker(symbols: symbols)
        let source = PrivateMultitouchCaptureSource(
            settingsProvider: { .defaults },
            pointerProvider: { ScreenPoint(x: 100, y: 100) },
            modifierProvider: { [] },
            worker: worker
        )

        let recorder = EventListRecorder()
        _ = source.start { event in
            recorder.record(event)
        }

        guard let reg = PrivateMultitouchCaptureBridge.registry.registration(device: device) else {
            Issue.record("Expected registration")
            return
        }

        // Deliver sequence: began -> swipe right -> tap ended
        reg.deliver([
            PrivateTouchSample(id: 1, state: 2, x: 0.20, y: 0.50),
            PrivateTouchSample(id: 2, state: 2, x: 0.30, y: 0.50)
        ], frame: 1)

        reg.deliver([
            PrivateTouchSample(id: 1, state: 2, x: 0.44, y: 0.50),
            PrivateTouchSample(id: 2, state: 2, x: 0.54, y: 0.50)
        ], frame: 2)

        reg.deliver([], frame: 3)

        try? await Task.sleep(nanoseconds: 50_000_000)
        let events = recorder.events
        #expect(events.count >= 2)
        #expect(events.first?.isBegin == true)
        #expect(events.last?.isEnd == true)

        source.stop()
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

private final class CallbackDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class WorkerExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: [Int] = []

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    func record(_ val: Int) {
        lock.lock()
        sequence.append(val)
        lock.unlock()
    }
}

private final class EventListRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CapturedGestureEvent] = []

    var events: [CapturedGestureEvent] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    func record(_ event: CapturedGestureEvent) {
        lock.lock()
        list.append(event)
        lock.unlock()
    }
}

private final class MockMTDeviceStorage: @unchecked Sendable {
    static let shared = MockMTDeviceStorage()

    var devices: [MTDeviceRef] = []
    var startedDevices: [MTDeviceRef] = []
    var stoppedDevices: [MTDeviceRef] = []
    var registeredDevices: [MTDeviceRef] = []
    var unregisteredDevices: [MTDeviceRef] = []
    var failStartFor: Set<MTDeviceRef> = []
    var deviceIDs: [UInt: UInt64] = [:]

    func reset() {
        devices.removeAll()
        startedDevices.removeAll()
        stoppedDevices.removeAll()
        registeredDevices.removeAll()
        unregisteredDevices.removeAll()
        failStartFor.removeAll()
        deviceIDs.removeAll()
    }
}

private let mockCreateList: MTDeviceCreateListFn = {
    let storage = MockMTDeviceStorage.shared
    var values: [UnsafeRawPointer?] = storage.devices.map { UnsafeRawPointer($0) }
    let array = values.withUnsafeMutableBufferPointer { buffer in
        CFArrayCreate(
            kCFAllocatorDefault,
            buffer.baseAddress,
            CFIndex(buffer.count),
            nil
        )
    }
    return Unmanaged.passRetained(array!)
}

private let mockRegisterWithoutRefcon: MTRegisterContactFrameCallbackFn = { device, callback in
    guard let device else { return }
    MockMTDeviceStorage.shared.registeredDevices.append(device)
}

private let mockUnregisterWithoutRefcon: MTUnregisterContactFrameCallbackFn = { device, callback in
    guard let device else { return }
    MockMTDeviceStorage.shared.unregisteredDevices.append(device)
}

private let mockDeviceStart: MTDeviceStartFn = { device, mode in
    guard let device else { return -1 }
    let storage = MockMTDeviceStorage.shared
    if storage.failStartFor.contains(device) {
        return -1
    }
    storage.startedDevices.append(device)
    return 0
}

private let mockDeviceStop: MTDeviceStopFn = { device in
    guard let device else { return -1 }
    MockMTDeviceStorage.shared.stoppedDevices.append(device)
    return 0
}

private let mockDeviceIsBuiltIn: MTDeviceIsBuiltInFn = { _ in
    true
}

private let mockDeviceGetDeviceID: MTDeviceGetDeviceIDFn = { device, outID in
    guard let device, let outID else { return -1 }
    let key = UInt(bitPattern: device)
    if let id = MockMTDeviceStorage.shared.deviceIDs[key] {
        outID.pointee = id
        return 0
    }
    outID.pointee = 12345
    return 0
}

private func mockMultitouchSymbols() -> MultitouchSupportSymbols {
    MultitouchSupportSymbols(
        createList: mockCreateList,
        registerWithoutRefcon: mockRegisterWithoutRefcon,
        unregisterWithoutRefcon: mockUnregisterWithoutRefcon,
        deviceStart: mockDeviceStart,
        deviceStop: mockDeviceStop,
        deviceIsBuiltIn: mockDeviceIsBuiltIn,
        deviceGetDeviceID: mockDeviceGetDeviceID
    )
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

    var inwardSegmentCount: Int? {
        if case .pinchEnded(let pinch) = self {
            return pinch.inwardSegmentCount
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

    var progressInwardSegmentCount: Int? {
        if case .changed(let progress) = self {
            return progress.inwardSegmentCount
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
