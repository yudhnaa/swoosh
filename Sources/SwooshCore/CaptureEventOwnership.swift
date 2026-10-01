import Foundation

public final class CaptureEventOwnershipGate {
    private var owner: CapturedGestureSource?
    private var ignoredSources: Set<CapturedGestureSource> = []

    public init() {}

    public func reset() {
        owner = nil
        ignoredSources.removeAll()
    }

    public func shouldAccept(_ event: CapturedGestureEvent) -> Bool {
        let source = event.source
        guard source.isSpecified else {
            return true
        }

        if ignoredSources.contains(source) {
            if event.endsContactSequence {
                ignoredSources.remove(source)
            }
            return false
        }

        switch event {
        case .began:
            guard let owner else {
                self.owner = source
                return true
            }
            guard owner == source else {
                ignoredSources.insert(source)
                return false
            }
            return true

        default:
            guard let owner else {
                self.owner = source
                return true
            }
            guard owner == source else {
                ignoredSources.insert(source)
                if event.endsContactSequence {
                    ignoredSources.remove(source)
                }
                return false
            }
            return true
        }
    }

    public func releaseOwner(for event: CapturedGestureEvent? = nil) {
        guard let event else {
            owner = nil
            return
        }

        let source = event.source
        guard source.isSpecified else {
            owner = nil
            return
        }

        if owner == source {
            owner = nil
        }
    }
}

public extension CapturedGestureEvent {
    var endsContactSequence: Bool {
        switch self {
        case .strokeEnded, .pinchEnded, .tapEnded, .ended, .deviceEnded, .cancelled, .deviceCancelled:
            true
        case .began, .movement, .deviceMovement, .changed:
            false
        }
    }
}
