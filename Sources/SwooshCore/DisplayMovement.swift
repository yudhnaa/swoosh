import Foundation

public enum DisplayMoveDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum WindowLayoutPlacement: Equatable, Sendable {
    case snapped(SnapDestination)
    case unsnapped
}

public enum DisplayMovementStatus: String, Codable, Equatable, Sendable {
    case planned
    case unavailable
    case topologyChanged
}

public struct DisplayMovementResult: Equatable, Sendable {
    public var status: DisplayMovementStatus
    public var sourceDisplay: DisplayGeometry?
    public var destinationDisplay: DisplayGeometry?
    public var frame: GeometryRect?
    public var reason: String?

    public init(
        status: DisplayMovementStatus,
        sourceDisplay: DisplayGeometry? = nil,
        destinationDisplay: DisplayGeometry? = nil,
        frame: GeometryRect? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.sourceDisplay = sourceDisplay
        self.destinationDisplay = destinationDisplay
        self.frame = frame
        self.reason = reason
    }
}

public struct DisplayTopologySnapshot: Equatable, Sendable {
    public var displays: [DisplayGeometry]

    public init(displays: [DisplayGeometry]) {
        self.displays = displays.sorted { lhs, rhs in
            lhs.id < rhs.id
        }
    }

    public func matches(_ currentDisplays: [DisplayGeometry]) -> Bool {
        self == DisplayTopologySnapshot(displays: currentDisplays)
    }
}

public struct StagedWindowOperation: Equatable, Sendable {
    public var target: WindowTargetIdentity
    public var frame: GeometryRect
    public var topology: DisplayTopologySnapshot

    public init(target: WindowTargetIdentity, frame: GeometryRect, displays: [DisplayGeometry]) {
        self.target = target
        self.frame = frame
        topology = DisplayTopologySnapshot(displays: displays)
    }

    public func validate(currentDisplays: [DisplayGeometry]) -> DisplayMovementStatus {
        topology.matches(currentDisplays) ? .planned : .topologyChanged
    }
}

public struct DisplayMovementPlanner {
    private let snapEngine: SnapGeometryEngine

    public init(snapEngine: SnapGeometryEngine = SnapGeometryEngine()) {
        self.snapEngine = snapEngine
    }

    public func planMove(
        frame currentFrame: GeometryRect,
        placement: WindowLayoutPlacement,
        direction: DisplayMoveDirection,
        displays: [DisplayGeometry],
        gridSpacing: Int
    ) -> DisplayMovementResult {
        guard let sourceDisplay = display(containing: currentFrame, in: displays) else {
            return DisplayMovementResult(
                status: .unavailable,
                reason: "The current window frame is not reachable on any active display."
            )
        }

        guard let destinationDisplay = neighbor(from: sourceDisplay, direction: direction, displays: displays) else {
            return DisplayMovementResult(
                status: .unavailable,
                sourceDisplay: sourceDisplay,
                reason: "No active display is available in the requested direction."
            )
        }

        let destinationFrame: GeometryRect
        switch placement {
        case .snapped(let destination):
            destinationFrame = snapEngine.frame(for: destination, on: destinationDisplay, gridSpacing: gridSpacing)
        case .unsnapped:
            destinationFrame = mappedUnsnappedFrame(
                currentFrame,
                from: sourceDisplay.usableFrame,
                to: destinationDisplay.usableFrame
            )
        }

        return DisplayMovementResult(
            status: .planned,
            sourceDisplay: sourceDisplay,
            destinationDisplay: destinationDisplay,
            frame: destinationFrame
        )
    }

    public func planRestore(
        originalFrame: GeometryRect,
        originalDisplayID: String?,
        currentFrame: GeometryRect,
        displays: [DisplayGeometry]
    ) -> GeometryRect? {
        guard !displays.isEmpty else {
            return nil
        }

        if let originalDisplayID,
           let originalDisplay = displays.first(where: { $0.id == originalDisplayID }) {
            return originalFrame.clamped(to: originalDisplay.usableFrame)
        }

        let reachableDisplay = display(containing: currentFrame, in: displays) ?? nearestDisplay(to: currentFrame, in: displays)
        return originalFrame.clamped(to: reachableDisplay.usableFrame)
    }

    public func display(containing frame: GeometryRect, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        let center = frame.center
        if let containing = displays.first(where: { $0.frame.contains(center) }) {
            return containing
        }

        return nearestDisplay(to: frame, in: displays)
    }

    public func neighbor(
        from source: DisplayGeometry,
        direction: DisplayMoveDirection,
        displays: [DisplayGeometry]
    ) -> DisplayGeometry? {
        displays
            .filter { $0.id != source.id }
            .compactMap { candidate -> DisplayCandidate? in
                guard let directionalDistance = directionalDistance(from: source.frame, to: candidate.frame, direction: direction) else {
                    return nil
                }

                return DisplayCandidate(
                    display: candidate,
                    directionalDistance: directionalDistance,
                    perpendicularDistance: perpendicularDistance(from: source.frame, to: candidate.frame, direction: direction),
                    perpendicularCenterDistance: perpendicularCenterDistance(from: source.frame, to: candidate.frame, direction: direction)
                )
            }
            .sorted()
            .first?
            .display
    }

    private func mappedUnsnappedFrame(_ frame: GeometryRect, from source: GeometryRect, to destination: GeometryRect) -> GeometryRect {
        let width = min(frame.width, destination.width)
        let height = min(frame.height, destination.height)
        let x = destination.x + originFraction(frame.x, sourceStart: source.x, sourceSize: source.width, itemSize: frame.width) * max(0, destination.width - width)
        let y = destination.y + originFraction(frame.y, sourceStart: source.y, sourceSize: source.height, itemSize: frame.height) * max(0, destination.height - height)

        return GeometryRect(x: x, y: y, width: width, height: height).clamped(to: destination)
    }

    private func originFraction(_ origin: Double, sourceStart: Double, sourceSize: Double, itemSize: Double) -> Double {
        let movableRange = sourceSize - itemSize
        guard movableRange > 0 else {
            return 0.5
        }

        return min(max((origin - sourceStart) / movableRange, 0), 1)
    }

    private func nearestDisplay(to frame: GeometryRect, in displays: [DisplayGeometry]) -> DisplayGeometry {
        displays.min { lhs, rhs in
            let lhsDistance = frame.center.distance(to: lhs.frame.center)
            let rhsDistance = frame.center.distance(to: rhs.frame.center)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            return lhs.id < rhs.id
        }!
    }

    private func directionalDistance(from source: GeometryRect, to candidate: GeometryRect, direction: DisplayMoveDirection) -> Double? {
        switch direction {
        case .left:
            guard candidate.center.x < source.center.x else {
                return nil
            }
            return max(0, source.x - candidate.maxX)
        case .right:
            guard candidate.center.x > source.center.x else {
                return nil
            }
            return max(0, candidate.x - source.maxX)
        case .up:
            guard candidate.center.y > source.center.y else {
                return nil
            }
            return max(0, candidate.y - source.maxY)
        case .down:
            guard candidate.center.y < source.center.y else {
                return nil
            }
            return max(0, source.y - candidate.maxY)
        }
    }

    private func perpendicularDistance(from source: GeometryRect, to candidate: GeometryRect, direction: DisplayMoveDirection) -> Double {
        switch direction {
        case .left, .right:
            return axisGap(sourceMin: source.y, sourceMax: source.maxY, candidateMin: candidate.y, candidateMax: candidate.maxY)
        case .up, .down:
            return axisGap(sourceMin: source.x, sourceMax: source.maxX, candidateMin: candidate.x, candidateMax: candidate.maxX)
        }
    }

    private func perpendicularCenterDistance(from source: GeometryRect, to candidate: GeometryRect, direction: DisplayMoveDirection) -> Double {
        switch direction {
        case .left, .right:
            return abs(source.center.y - candidate.center.y)
        case .up, .down:
            return abs(source.center.x - candidate.center.x)
        }
    }

    private func axisGap(sourceMin: Double, sourceMax: Double, candidateMin: Double, candidateMax: Double) -> Double {
        if candidateMax < sourceMin {
            return sourceMin - candidateMax
        }

        if candidateMin > sourceMax {
            return candidateMin - sourceMax
        }

        return 0
    }
}

private struct DisplayCandidate: Comparable {
    var display: DisplayGeometry
    var directionalDistance: Double
    var perpendicularDistance: Double
    var perpendicularCenterDistance: Double

    static func < (lhs: DisplayCandidate, rhs: DisplayCandidate) -> Bool {
        if lhs.directionalDistance != rhs.directionalDistance {
            return lhs.directionalDistance < rhs.directionalDistance
        }

        if lhs.perpendicularDistance != rhs.perpendicularDistance {
            return lhs.perpendicularDistance < rhs.perpendicularDistance
        }

        if lhs.perpendicularCenterDistance != rhs.perpendicularCenterDistance {
            return lhs.perpendicularCenterDistance < rhs.perpendicularCenterDistance
        }

        return lhs.display.id < rhs.display.id
    }
}

private extension GeometryRect {
    var center: GeometryPoint {
        GeometryPoint(x: x + width / 2, y: y + height / 2)
    }

    func contains(_ point: GeometryPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }
}

private extension GeometryPoint {
    func distance(to other: GeometryPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}
