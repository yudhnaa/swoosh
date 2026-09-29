import Testing
@testable import SwooshCore

@Suite
struct GestureResolverTests {
    @Test
    func unmodifiedSingleSwipeMappingsStageThenCommitOnRelease() {
        let cases: [(GestureDirection, KeyboardCommand)] = [
            (.left, .snapLeft),
            (.right, .snapRight),
            (.up, .maximize),
            (.down, .minimize)
        ]

        for (direction, command) in cases {
            let resolver = GestureSequenceResolver()
            #expect(resolver.process(.begin(start())) == .none)

            let preview = resolver.process(.strokeEnded(stroke(direction, at: 100)))
            let committed = resolver.process(.release(timestampMilliseconds: 120))

            #expect(preview.kind == .preview)
            #expect(preview.intent?.command == command)
            #expect(preview.intent?.target == target)
            #expect(committed.kind == .commit)
            #expect(committed.intent?.command == command)
        }
    }

    @Test
    func unmodifiedDoubleAndOrthogonalSwipeChainsResolveWithoutPrematureCommit() {
        let cases: [([GestureDirection], KeyboardCommand)] = [
            ([.up, .up], .snapTop),
            ([.down, .down], .snapBottom),
            ([.left, .up], .snapTopLeft),
            ([.up, .left], .snapTopLeft),
            ([.right, .up], .snapTopRight),
            ([.up, .right], .snapTopRight),
            ([.left, .down], .snapBottomLeft),
            ([.down, .left], .snapBottomLeft),
            ([.right, .down], .snapBottomRight),
            ([.down, .right], .snapBottomRight)
        ]

        for (directions, command) in cases {
            let resolver = GestureSequenceResolver()
            #expect(resolver.process(.begin(start())) == .none)

            let first = resolver.process(.strokeEnded(stroke(directions[0], at: 100, id: "first")))
            let second = resolver.process(.strokeEnded(stroke(directions[1], at: 200, id: "second")))
            let committed = resolver.process(.release(timestampMilliseconds: 220))

            #expect(first.kind == .preview)
            #expect(second.kind == .preview)
            #expect(second.intent?.command == command)
            #expect(committed.kind == .commit)
            #expect(committed.intent?.command == command)
        }
    }

    @Test
    func downDownProducesBottomHalfWithoutIntermediateMinimizeCommit() {
        let resolver = GestureSequenceResolver()

        #expect(resolver.process(.begin(start())) == .none)
        let first = resolver.process(.strokeEnded(stroke(.down, at: 100, id: "down-1")))
        let second = resolver.process(.strokeEnded(stroke(.down, at: 500, id: "down-2")))
        let committed = resolver.process(.release(timestampMilliseconds: 520))

        #expect(first.kind == .preview)
        #expect(first.intent?.command == .minimize)
        #expect(second.kind == .preview)
        #expect(second.intent?.command == .snapBottom)
        #expect(committed.kind == .commit)
        #expect(committed.intent?.command == .snapBottom)
    }

    @Test
    func pinchMappingsCommitOnlyCompletedNonCancelledGestures() {
        let pinchIn = GestureSequenceResolver()
        #expect(pinchIn.process(.begin(start())) == .none)
        #expect(pinchIn.process(.pinchEnded(pinch(.inward, at: 100))).intent?.command == .close)

        let pinchOut = GestureSequenceResolver()
        #expect(pinchOut.process(.begin(start())) == .none)
        #expect(pinchOut.process(.pinchEnded(pinch(.outward, at: 100))).intent?.command == .toggleFullscreen)

        let cancelled = GestureSequenceResolver()
        #expect(cancelled.process(.begin(start())) == .none)
        let output = cancelled.process(.pinchEnded(pinch(.inward, at: 100, isCancelled: true)))
        #expect(output.kind == .cancel)
        #expect(output.reason == .gestureCancelled)
    }

    @Test
    func modifierModesLatchAtSessionStartAndIgnoreLaterModifierChanges() {
        let general = GestureSequenceResolver()
        #expect(general.process(.begin(start(modifiers: [.control]))) == .none)
        let close = general.process(.strokeEnded(stroke(.down, at: 100, modifiers: [])))
        #expect(close.kind == .commit)
        #expect(close.intent?.command == .close)
        #expect(close.intent?.modifierMode == .general)

        let unmodified = GestureSequenceResolver()
        #expect(unmodified.process(.begin(start(modifiers: []))) == .none)
        let preview = unmodified.process(.strokeEnded(stroke(.down, at: 100, modifiers: [.control])))
        let commit = unmodified.process(.release(timestampMilliseconds: 120))
        #expect(preview.kind == .preview)
        #expect(preview.intent?.command == .minimize)
        #expect(commit.intent?.command == .minimize)
        #expect(commit.intent?.modifierMode == .unmodified)
    }

    @Test
    func screenModifierMapsDirectionalSwipesToDeferredDisplayMovementCommands() {
        let cases: [(GestureDirection, KeyboardCommand)] = [
            (.left, .moveDisplayLeft),
            (.right, .moveDisplayRight),
            (.up, .moveDisplayUp),
            (.down, .moveDisplayDown)
        ]

        for (direction, command) in cases {
            let resolver = GestureSequenceResolver()
            #expect(resolver.process(.begin(start(modifiers: [.command]))) == .none)
            let output = resolver.process(.strokeEnded(stroke(direction, at: 100)))
            #expect(output.kind == .commit)
            #expect(output.intent?.command == command)
            #expect(output.intent?.modifierMode == .screen)
        }
    }

    @Test
    func unsupportedModifierCombinationsPassThroughWithoutAction() {
        let resolver = GestureSequenceResolver()

        let begin = resolver.process(.begin(start(modifiers: [.shift])))
        let strokeAfterPassThrough = resolver.process(.strokeEnded(stroke(.left, at: 100)))

        #expect(begin.kind == .passThrough)
        #expect(strokeAfterPassThrough == .none)
    }

    @Test
    func invalidOverlongAndCancelledSessionsDoNotCommit() {
        let invalid = GestureSequenceResolver()
        #expect(invalid.process(.begin(start())) == .none)
        _ = invalid.process(.strokeEnded(stroke(.left, at: 100, id: "left")))
        let invalidOutput = invalid.process(.strokeEnded(stroke(.right, at: 200, id: "right")))
        #expect(invalidOutput.kind == .cancel)
        #expect(invalidOutput.reason == .invalidChain)
        #expect(invalid.process(.timeout(timestampMilliseconds: 1_000)) == .none)

        let overlong = GestureSequenceResolver()
        #expect(overlong.process(.begin(start())) == .none)
        _ = overlong.process(.strokeEnded(stroke(.up, at: 100, id: "up")))
        _ = overlong.process(.strokeEnded(stroke(.left, at: 200, id: "left")))
        let overlongOutput = overlong.process(.strokeEnded(stroke(.down, at: 300, id: "down")))
        #expect(overlongOutput.kind == .cancel)
        #expect(overlongOutput.reason == .overlongChain)

        for reason in cancellationReasons {
            let resolver = GestureSequenceResolver()
            #expect(resolver.process(.begin(start())) == .none)
            _ = resolver.process(.strokeEnded(stroke(.left, at: 100)))
            let cancelled = resolver.process(.cancel(reason, timestampMilliseconds: 200))
            #expect(cancelled.kind == .cancel)
            #expect(cancelled.reason == reason)
            #expect(resolver.process(.timeout(timestampMilliseconds: 900)) == .none)
        }
    }

    @Test
    func duplicateEndEventsMomentumAndPostCommitEventsCannotCauseExtraActions() {
        let resolver = GestureSequenceResolver()

        #expect(resolver.process(.begin(start())) == .none)
        let first = resolver.process(.strokeEnded(stroke(.left, at: 100, id: "same")))
        let duplicate = resolver.process(.strokeEnded(stroke(.left, at: 101, id: "same")))
        let momentum = resolver.process(.momentum(timestampMilliseconds: 200))
        let committed = resolver.process(.timeout(timestampMilliseconds: 900))
        let afterCommit = resolver.process(.strokeEnded(stroke(.right, at: 1_000, id: "later")))

        #expect(first.kind == .preview)
        #expect(duplicate == .none)
        #expect(momentum == .none)
        #expect(committed.kind == .commit)
        #expect(afterCommit == .none)
    }

    @Test
    func timeoutUsesConfiguredRangeEndpointsAndBounds() {
        let minResolver = GestureSequenceResolver(configuration: GestureResolverConfiguration(chainTimeoutMilliseconds: 200))
        #expect(minResolver.process(.begin(start())) == .none)
        _ = minResolver.process(.strokeEnded(stroke(.left, at: 100)))
        #expect(minResolver.process(.timeout(timestampMilliseconds: 299)) == .none)
        #expect(minResolver.process(.timeout(timestampMilliseconds: 300)).kind == .commit)

        let maxResolver = GestureSequenceResolver(configuration: GestureResolverConfiguration(chainTimeoutMilliseconds: 1_200))
        #expect(maxResolver.process(.begin(start())) == .none)
        _ = maxResolver.process(.strokeEnded(stroke(.right, at: 100)))
        #expect(maxResolver.process(.timeout(timestampMilliseconds: 1_299)) == .none)
        #expect(maxResolver.process(.timeout(timestampMilliseconds: 1_300)).kind == .commit)

        let clamped = GestureSequenceResolver(configuration: GestureResolverConfiguration(chainTimeoutMilliseconds: 10))
        #expect(clamped.process(.begin(start())) == .none)
        _ = clamped.process(.strokeEnded(stroke(.up, at: 100)))
        #expect(clamped.process(.timeout(timestampMilliseconds: 299)) == .none)
        #expect(clamped.process(.timeout(timestampMilliseconds: 300)).kind == .commit)
    }

    @Test
    func missingTargetPassesThroughAndPreservesOtherWindows() {
        let resolver = GestureSequenceResolver()
        let output = resolver.process(.begin(missingTargetStart()))

        #expect(output.kind == .passThrough)
        #expect(resolver.process(.strokeEnded(stroke(.left, at: 100))) == .none)
    }

    private var target: WindowTargetIdentity {
        WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")
    }

    private var cancellationReasons: [GestureCancelReason] {
        [.escape, .gestureCancelled, .permissionLost, .targetLost, .topologyChanged, .paused, .captureFailed]
    }

    private func start(
        target: WindowTargetIdentity? = nil,
        modifiers: Set<ModifierRole> = [],
        at timestamp: Int = 0
    ) -> GestureSessionStart {
        GestureSessionStart(
            target: target ?? self.target,
            modifiers: modifiers,
            timestampMilliseconds: timestamp,
            topologyToken: "topology-a"
        )
    }

    private func missingTargetStart(
        modifiers: Set<ModifierRole> = [],
        at timestamp: Int = 0
    ) -> GestureSessionStart {
        GestureSessionStart(
            target: nil,
            modifiers: modifiers,
            timestampMilliseconds: timestamp,
            topologyToken: "topology-a"
        )
    }

    private func stroke(
        _ direction: GestureDirection,
        at timestamp: Int,
        id: String? = nil,
        modifiers: Set<ModifierRole> = []
    ) -> GestureStroke {
        GestureStroke(direction: direction, timestampMilliseconds: timestamp, eventID: id, modifiers: modifiers)
    }

    private func pinch(
        _ direction: GesturePinchDirection,
        at timestamp: Int,
        id: String? = nil,
        isCancelled: Bool = false,
        modifiers: Set<ModifierRole> = []
    ) -> GesturePinch {
        GesturePinch(
            direction: direction,
            timestampMilliseconds: timestamp,
            eventID: id,
            isCancelled: isCancelled,
            modifiers: modifiers
        )
    }
}
