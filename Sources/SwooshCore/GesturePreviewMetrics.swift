import Foundation

public struct GesturePreviewLatencySummary: Equatable, Sendable {
    public var count: Int
    public var p95Milliseconds: Int?
    public var latestMilliseconds: Int?

    public init(count: Int, p95Milliseconds: Int?, latestMilliseconds: Int?) {
        self.count = count
        self.p95Milliseconds = p95Milliseconds
        self.latestMilliseconds = latestMilliseconds
    }
}

public final class GesturePreviewLatencyTracker {
    private let capacity: Int
    private var samples: [Int] = []

    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    public var summary: GesturePreviewLatencySummary {
        let sorted = samples.sorted()
        let p95: Int?
        if sorted.isEmpty {
            p95 = nil
        } else {
            let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
            p95 = sorted[index]
        }

        return GesturePreviewLatencySummary(
            count: samples.count,
            p95Milliseconds: p95,
            latestMilliseconds: samples.last
        )
    }

    public func reset() {
        samples.removeAll()
    }

    public func record(recognizedAt: Int, presentedAt: Int) -> GesturePreviewLatencySummary {
        samples.append(max(0, presentedAt - recognizedAt))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        return summary
    }
}
