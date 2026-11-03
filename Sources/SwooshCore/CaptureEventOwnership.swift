import Foundation

public enum CapturePhysicalOwnershipState: Equatable, Sendable {
    case idle
    case owned(CapturedGestureSource)
    case draining(Set<CapturedGestureSource>)
}

public final class CaptureEventOwnershipGate {
    private var owner: CapturedGestureSource?
    private var drainingSources: Set<CapturedGestureSource> = []

    public var physicalState: CapturePhysicalOwnershipState {
        if let owner {
            return .owned(owner)
        }
        if !drainingSources.isEmpty {
            return .draining(drainingSources)
        }
        return .idle
    }

    public init() {}

    public func reset() {
        owner = nil
        drainingSources.removeAll()
    }

    public func shouldAccept(_ event: CapturedGestureEvent) -> Bool {
        let source = event.source
        guard source.isSpecified else {
            return true
        }

        if drainingSources.contains(source) {
            if event.endsContactSequence {
                drainingSources.remove(source)
            }
            return false
        }

        if let owner {
            guard owner == source else {
                if !event.endsContactSequence {
                    drainingSources.insert(source)
                }
                return false
            }
            if event.endsContactSequence {
                self.owner = nil
            }
            return true
        }

        switch physicalState {
        case .idle:
            guard event.startsContactSequence else {
                return false
            }
            owner = source
            return true
        case .draining:
            if !event.endsContactSequence {
                drainingSources.insert(source)
            }
            return false
        case .owned:
            preconditionFailure("Owned state must have an owner")
        }
    }

    public func releaseOwner(for event: CapturedGestureEvent? = nil) {
        guard let owner else {
            return
        }
        if let event {
            guard event.endsContactSequence,
                  !event.source.isSpecified || event.source == owner else {
                return
            }
        }
        self.owner = nil
    }

    /// Completes the logical gesture while retaining physical ownership until
    /// the originating device reports that its contacts have actually ended.
    public func drainOwnerUntilTerminal() {
        guard let owner else {
            return
        }
        drainingSources.insert(owner)
        self.owner = nil
    }
}

public extension CapturedGestureEvent {
    var startsContactSequence: Bool {
        if case .began = self {
            return true
        }
        return false
    }

    var endsContactSequence: Bool {
        switch self {
        case .pinchEnded, .tapEnded, .ended, .deviceEnded, .cancelled, .deviceCancelled:
            true
        case .began, .movement, .deviceMovement, .changed, .strokeEnded:
            false
        }
    }
}
