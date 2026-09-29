import Foundation
import Testing
@testable import SwooshCore

@Suite
struct WindowGeometryTests {
    private let engine = SnapGeometryEngine()
    private let display = DisplayGeometry(
        id: "main",
        frame: GeometryRect(x: 0, y: 0, width: 1512, height: 982),
        usableFrame: GeometryRect(x: 0, y: 38, width: 1512, height: 944),
        scaleFactor: 2
    )

    @Test
    func allMvpSnapDestinationsMatchSpecFormulaWithoutGap() {
        let expected: [SnapDestination: GeometryRect] = [
            .leftHalf: GeometryRect(x: 0, y: 38, width: 756, height: 944),
            .rightHalf: GeometryRect(x: 756, y: 38, width: 756, height: 944),
            .bottomHalf: GeometryRect(x: 0, y: 38, width: 1512, height: 472),
            .topHalf: GeometryRect(x: 0, y: 510, width: 1512, height: 472),
            .bottomLeft: GeometryRect(x: 0, y: 38, width: 756, height: 472),
            .bottomRight: GeometryRect(x: 756, y: 38, width: 756, height: 472),
            .topLeft: GeometryRect(x: 0, y: 510, width: 756, height: 472),
            .topRight: GeometryRect(x: 756, y: 510, width: 756, height: 472),
            .maximize: GeometryRect(x: 0, y: 38, width: 1512, height: 944)
        ]

        for destination in SnapDestination.allCases {
            #expect(engine.frame(for: destination, on: display, gridSpacing: 0).isWithin(0.001, of: expected[destination]!))
        }
    }

    @Test
    func gridGapUsesSpecCellFormulaAndSettingBounds() {
        let rightHalf = engine.frame(for: .rightHalf, on: display, gridSpacing: 12)
        let maximized = engine.frame(for: .maximize, on: display, gridSpacing: 12)
        let clampedFromOversizedSetting = engine.frame(for: .maximize, on: display, gridSpacing: 1_000)
        let clampedToSettingRange = engine.frame(for: .maximize, on: display, gridSpacing: 32)

        #expect(rightHalf.isWithin(0.001, of: GeometryRect(x: 762, y: 50, width: 738, height: 920)))
        #expect(maximized.isWithin(0.001, of: GeometryRect(x: 12, y: 50, width: 1488, height: 920)))
        #expect(clampedFromOversizedSetting == clampedToSettingRange)
    }

    @Test
    func tinyDisplaysClampGapToKeepCellsPositive() {
        let tiny = DisplayGeometry(
            id: "tiny",
            frame: GeometryRect(x: 0, y: 0, width: 30, height: 30),
            usableFrame: GeometryRect(x: 0, y: 0, width: 30, height: 30)
        )

        let frame = engine.frame(for: .bottomRight, on: tiny, gridSpacing: 32)

        #expect(frame.width > 0)
        #expect(frame.height > 0)
        #expect(frame.maxX <= tiny.usableFrame.maxX)
        #expect(frame.maxY <= tiny.usableFrame.maxY)
    }

    @Test
    func appliedFrameReadbackReportsExactConstrainedAndUnsupported() {
        let requested = GeometryRect(x: 0, y: 0, width: 500, height: 400)
        let exact = engine.evaluateAppliedFrame(requested: requested, applied: GeometryRect(x: 1.5, y: 0, width: 500, height: 398.2))
        let constrained = engine.evaluateAppliedFrame(requested: requested, applied: GeometryRect(x: 0, y: 0, width: 460, height: 400))
        let unsupported = engine.evaluateAppliedFrame(requested: requested, applied: nil)
        let minimumConstrained = engine.evaluateAppliedFrame(
            requested: GeometryRect(x: 0, y: 0, width: 100, height: 100),
            applied: GeometryRect(x: 0, y: 0, width: 140, height: 120),
            minimumSize: GeometrySize(width: 140, height: 120)
        )

        #expect(exact.status == .exact)
        #expect(constrained.status == .constrained)
        #expect(unsupported.status == .unsupported)
        #expect(minimumConstrained.status == .constrained)
    }

    @Test
    func coordinateConversionHandlesDisplayOffsetsAndNegativeOrigins() {
        let converter = CoordinateConverter()
        let displayFrame = GeometryRect(x: -300, y: -900, width: 1600, height: 900)
        let appKitFrame = GeometryRect(x: -100, y: -850, width: 500, height: 300)

        let accessibilityFrame = converter.appKitToAccessibility(appKitFrame, on: displayFrame)
        let roundTripped = converter.accessibilityToAppKit(accessibilityFrame, on: displayFrame)

        #expect(accessibilityFrame == GeometryRect(x: -100, y: 550, width: 500, height: 300))
        #expect(roundTripped == appKitFrame)
    }

    @Test
    func successfulSnapsPreserveFirstOriginalFrameAcrossThreeSnaps() throws {
        let history = WindowFrameHistory()
        let target = targetIdentity()
        let original = GeometryRect(x: 40, y: 80, width: 900, height: 600)
        let firstSnap = engine.evaluateAppliedFrame(
            requested: engine.frame(for: .leftHalf, on: display, gridSpacing: 0),
            applied: engine.frame(for: .leftHalf, on: display, gridSpacing: 0)
        )
        let secondOriginal = GeometryRect(x: 0, y: 38, width: 756, height: 944)
        let secondSnap = engine.evaluateAppliedFrame(
            requested: engine.frame(for: .topRight, on: display, gridSpacing: 0),
            applied: engine.frame(for: .topRight, on: display, gridSpacing: 0)
        )
        let thirdOriginal = engine.frame(for: .topRight, on: display, gridSpacing: 0)
        let thirdSnap = engine.evaluateAppliedFrame(
            requested: engine.frame(for: .bottomRight, on: display, gridSpacing: 0),
            applied: engine.frame(for: .bottomRight, on: display, gridSpacing: 0)
        )

        history.recordSuccessfulSnap(target: target, originalFrame: original, result: firstSnap)
        history.recordSuccessfulSnap(target: target, originalFrame: secondOriginal, result: secondSnap)
        history.recordSuccessfulSnap(target: target, originalFrame: thirdOriginal, result: thirdSnap)

        #expect(history.originalFrame(for: target) == original)
        #expect(history.plan(.unsnap, target: target, currentFrame: engine.frame(for: .bottomRight, on: display, gridSpacing: 0), reachableDisplay: display) == .planned(original))
    }

    @Test
    func manualResizeAfterSnapBecomesNewRestoreOrigin() {
        let history = WindowFrameHistory()
        let target = targetIdentity()
        let original = GeometryRect(x: 40, y: 80, width: 900, height: 600)
        let snapped = engine.frame(for: .leftHalf, on: display, gridSpacing: 0)
        let manual = GeometryRect(x: 120, y: 140, width: 700, height: 500)
        let firstSnap = engine.evaluateAppliedFrame(requested: snapped, applied: snapped)

        history.recordSuccessfulSnap(target: target, originalFrame: original, result: firstSnap)

        #expect(history.plan(.unsnap, target: target, currentFrame: manual, reachableDisplay: display) == .planned(manual))
        #expect(history.originalFrame(for: target) == manual)
        #expect(history.plan(.centerAndUnsnap, target: target, currentFrame: manual, reachableDisplay: display) == .planned(manual.centered(in: display.usableFrame)))
    }

    @Test
    func failedSnapsDoNotCorruptOriginalFrameHistory() {
        let history = WindowFrameHistory()
        let target = targetIdentity()
        let failed = GeometryApplyResult(
            requestedFrame: GeometryRect(x: 0, y: 0, width: 500, height: 500),
            appliedFrame: nil,
            status: .unsupported
        )

        history.recordSuccessfulSnap(target: target, originalFrame: GeometryRect(x: 1, y: 2, width: 3, height: 4), result: failed)

        #expect(history.originalFrame(for: target) == nil)
    }

    @Test
    func centerAndUnsnapVariantsFollowMissingHistoryRulesAndClampRestore() {
        let history = WindowFrameHistory()
        let target = targetIdentity()
        let current = GeometryRect(x: 0, y: 38, width: 500, height: 400)
        let offscreenOriginal = GeometryRect(x: -2_000, y: 5_000, width: 900, height: 600)
        let successful = engine.evaluateAppliedFrame(requested: current, applied: current)

        #expect(history.plan(.unsnap, target: target, currentFrame: current, reachableDisplay: display) == .noOp)
        #expect(history.plan(.centerAndUnsnap, target: target, currentFrame: current, reachableDisplay: display) == .planned(current.centered(in: display.usableFrame)))

        history.recordSuccessfulSnap(target: target, originalFrame: offscreenOriginal, result: successful)

        #expect(history.plan(.unsnap, target: target, currentFrame: current, reachableDisplay: display) == .planned(offscreenOriginal.clamped(to: display.usableFrame)))
        #expect(history.plan(.center, target: target, currentFrame: current, reachableDisplay: display) == .planned(current.centered(in: display.usableFrame)))
        #expect(history.plan(.centerAndUnsnap, target: target, currentFrame: current, reachableDisplay: display) == .planned(offscreenOriginal.centered(in: display.usableFrame)))
    }

    @Test
    func staleTargetsCanBeRemovedFromHistory() {
        let history = WindowFrameHistory()
        let live = targetIdentity(id: "live")
        let stale = targetIdentity(id: "stale")
        let result = engine.evaluateAppliedFrame(
            requested: display.usableFrame,
            applied: display.usableFrame
        )

        history.recordSuccessfulSnap(target: live, originalFrame: GeometryRect(x: 10, y: 10, width: 300, height: 200), result: result)
        history.recordSuccessfulSnap(target: stale, originalFrame: GeometryRect(x: 20, y: 20, width: 300, height: 200), result: result)
        history.clearStaleTargets(keeping: [live])

        #expect(history.originalFrame(for: live) != nil)
        #expect(history.originalFrame(for: stale) == nil)
    }

    private func targetIdentity(id: String = "window") -> WindowTargetIdentity {
        WindowTargetIdentity(processIdentifier: 42, elementIdentifier: id)
    }
}
