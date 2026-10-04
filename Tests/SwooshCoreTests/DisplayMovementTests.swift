import Foundation
import Testing
@testable import SwooshCore

@Suite
struct DisplayMovementTests {
    private let planner = DisplayMovementPlanner()

    @Test
    func neighborSelectionUsesDirectionalPerpendicularAndStableIdentityOrdering() throws {
        let source = display("main", x: 0, y: 0, width: 1000, height: 700)
        let rightFar = display("right-far", x: 1300, y: 0, width: 900, height: 700)
        let rightNearHigh = display("right-near-high", x: 1100, y: 900, width: 900, height: 700)
        let rightNearAlignedB = display("b-right-near", x: 1100, y: 0, width: 900, height: 700)
        let rightNearAlignedA = display("a-right-near", x: 1100, y: 0, width: 900, height: 700)

        let directionWinner = try #require(planner.neighbor(
            from: source,
            direction: .right,
            displays: [source, rightFar, rightNearHigh]
        ))
        let perpendicularWinner = try #require(planner.neighbor(
            from: source,
            direction: .right,
            displays: [source, rightNearHigh, rightNearAlignedB]
        ))
        let identityWinner = try #require(planner.neighbor(
            from: source,
            direction: .right,
            displays: [source, rightNearAlignedB, rightNearAlignedA]
        ))

        #expect(directionWinner.id == "right-near-high")
        #expect(perpendicularWinner.id == "b-right-near")
        #expect(identityWinner.id == "a-right-near")
    }

    @Test
    func absentNeighborReturnsUnavailableWithoutFrame() {
        let source = display("main", x: 0, y: 0, width: 1000, height: 700)
        let current = GeometryRect(x: 100, y: 100, width: 400, height: 300)

        let result = planner.planMove(
            frame: current,
            placement: .unsnapped,
            direction: .left,
            displays: [source],
            gridSpacing: 0
        )

        #expect(result.status == .unavailable)
        #expect(result.frame == nil)
        #expect(result.sourceDisplay?.id == "main")
    }

    @Test
    func snappedWindowsPreserveLayoutFractionOnMixedScaleDestination() throws {
        let source = display("main", x: 0, y: 0, width: 1512, height: 982, usableY: 38, usableHeight: 944, scale: 2)
        let destination = display("external", x: 1512, y: -120, width: 1920, height: 1080, usableY: -80, usableHeight: 1040, scale: 1)
        let current = SnapGeometryEngine().frame(for: .leftHalf, on: source, gridSpacing: 0)

        let result = planner.planMove(
            frame: current,
            placement: .snapped(.leftHalf),
            direction: .right,
            displays: [source, destination],
            gridSpacing: 0
        )

        let planned = try #require(result.frame)
        #expect(result.status == .planned)
        #expect(result.destinationDisplay?.id == "external")
        #expect(planned == SnapGeometryEngine().frame(for: .leftHalf, on: destination, gridSpacing: 0))
    }

    @Test
    func unsnappedWindowsRetainSizeWherePossibleAndClampIntoDestination() throws {
        let source = display("main", x: 0, y: 0, width: 1000, height: 800)
        let destination = display("small", x: 1000, y: 0, width: 300, height: 240)
        let current = GeometryRect(x: 700, y: 500, width: 500, height: 400)

        let result = planner.planMove(
            frame: current,
            placement: .unsnapped,
            direction: .right,
            displays: [source, destination],
            gridSpacing: 0
        )

        let planned = try #require(result.frame)
        #expect(planned == destination.usableFrame)
        #expect(planned.clamped(to: destination.usableFrame) == planned)
    }

    @Test
    func verticalAndNegativeOriginLayoutsUseGeometryNotConnectionOrder() throws {
        let source = display("main", x: 0, y: 0, width: 1200, height: 800)
        let upper = display("upper", x: -300, y: 800, width: 900, height: 700)
        let lower = display("lower", x: -600, y: -900, width: 1600, height: 900)

        let up = try #require(planner.neighbor(from: source, direction: .up, displays: [lower, source, upper]))
        let down = try #require(planner.neighbor(from: source, direction: .down, displays: [upper, source, lower]))

        #expect(up.id == "upper")
        #expect(down.id == "lower")
    }

    @Test
    func offsetLShapedLayoutMovesOutOfMiddleDisplayInBothDirections() throws {
        let display2 = display("2-middle", x: 0, y: 0, width: 1512, height: 982)
        let display1 = display("1-right", x: 1512, y: -180, width: 1728, height: 972)
        let display3 = display("3-lower", x: 0, y: -1_080, width: 1512, height: 1_080)
        let displays = [display1, display2, display3]
        let current = GeometryRect(x: 420, y: 260, width: 700, height: 520)

        let right = planner.planMove(
            frame: current,
            placement: .unsnapped,
            direction: .right,
            displays: displays,
            gridSpacing: 0
        )
        let down = planner.planMove(
            frame: current,
            placement: .unsnapped,
            direction: .down,
            displays: displays,
            gridSpacing: 0
        )

        let rightFrame = try #require(right.frame)
        let downFrame = try #require(down.frame)
        #expect(right.destinationDisplay?.id == "1-right")
        #expect(down.destinationDisplay?.id == "3-lower")
        #expect(containsCenter(of: rightFrame, in: display1.frame))
        #expect(containsCenter(of: downFrame, in: display3.frame))
    }

    @Test
    func topologySnapshotsInvalidateStagedOperationsOnFrameScaleOrCountChange() {
        let target = WindowTargetIdentity(processIdentifier: 42, elementIdentifier: "window")
        let main = display("main", x: 0, y: 0, width: 1000, height: 700)
        let external = display("external", x: 1000, y: 0, width: 1000, height: 700, scale: 2)
        let staged = StagedWindowOperation(
            target: target,
            frame: GeometryRect(x: 1000, y: 0, width: 500, height: 700),
            displays: [main, external]
        )

        #expect(staged.validate(currentDisplays: [external, main]) == .planned)
        #expect(staged.validate(currentDisplays: [main]) == .topologyChanged)
        #expect(staged.validate(currentDisplays: [main, display("external", x: 1000, y: 0, width: 900, height: 700, scale: 2)]) == .topologyChanged)
        #expect(staged.validate(currentDisplays: [main, display("external", x: 1000, y: 0, width: 1000, height: 700, scale: 1)]) == .topologyChanged)
    }

    @Test
    func missingOriginalDisplayClampsRestoreToCurrentReachableDisplay() throws {
        let currentDisplay = display("main", x: 0, y: 0, width: 900, height: 700)
        let missingOriginal = GeometryRect(x: -1800, y: 80, width: 1000, height: 800)
        let current = GeometryRect(x: 100, y: 100, width: 400, height: 300)

        let restore = try #require(planner.planRestore(
            originalFrame: missingOriginal,
            originalDisplayID: "external-that-disconnected",
            currentFrame: current,
            displays: [currentDisplay]
        ))

        #expect(restore == GeometryRect(x: 0, y: 0, width: 900, height: 700))
    }

    @Test
    func existingOriginalDisplayReceivesClampedRestoreEvenWhenCurrentWindowMoved() throws {
        let originalDisplay = display("original", x: -1200, y: 0, width: 1200, height: 800)
        let currentDisplay = display("main", x: 0, y: 0, width: 900, height: 700)
        let original = GeometryRect(x: -1300, y: 650, width: 500, height: 300)
        let current = GeometryRect(x: 100, y: 100, width: 400, height: 300)

        let restore = try #require(planner.planRestore(
            originalFrame: original,
            originalDisplayID: "original",
            currentFrame: current,
            displays: [currentDisplay, originalDisplay]
        ))

        #expect(restore == GeometryRect(x: -1200, y: 500, width: 500, height: 300))
    }

    private func display(
        _ id: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        usableY: Double? = nil,
        usableHeight: Double? = nil,
        scale: Double = 1
    ) -> DisplayGeometry {
        DisplayGeometry(
            id: id,
            frame: GeometryRect(x: x, y: y, width: width, height: height),
            usableFrame: GeometryRect(x: x, y: usableY ?? y, width: width, height: usableHeight ?? height),
            scaleFactor: scale
        )
    }

    private func containsCenter(of frame: GeometryRect, in displayFrame: GeometryRect) -> Bool {
        let centerX = frame.x + frame.width / 2
        let centerY = frame.y + frame.height / 2
        return centerX >= displayFrame.x &&
            centerX <= displayFrame.maxX &&
            centerY >= displayFrame.y &&
            centerY <= displayFrame.maxY
    }
}
