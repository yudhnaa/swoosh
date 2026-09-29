import Testing
@testable import SwooshCore

@Suite
struct GesturePreviewMetricsTests {
    @Test
    func latencyTrackerReportsLatestAndP95ForBoundedWindow() {
        let tracker = GesturePreviewLatencyTracker(capacity: 5)

        for latency in [10, 20, 30, 40, 200] {
            _ = tracker.record(recognizedAt: 1_000, presentedAt: 1_000 + latency)
        }

        #expect(tracker.summary.count == 5)
        #expect(tracker.summary.latestMilliseconds == 200)
        #expect(tracker.summary.p95Milliseconds == 200)

        _ = tracker.record(recognizedAt: 2_000, presentedAt: 2_005)

        #expect(tracker.summary.count == 5)
        #expect(tracker.summary.latestMilliseconds == 5)
        #expect(tracker.summary.p95Milliseconds == 200)
    }

    @Test
    func latencyTrackerClampsNegativeClockSkewAndResets() {
        let tracker = GesturePreviewLatencyTracker()

        _ = tracker.record(recognizedAt: 2_000, presentedAt: 1_990)
        #expect(tracker.summary.latestMilliseconds == 0)
        #expect(tracker.summary.p95Milliseconds == 0)

        tracker.reset()
        #expect(tracker.summary.count == 0)
        #expect(tracker.summary.latestMilliseconds == nil)
        #expect(tracker.summary.p95Milliseconds == nil)
    }
}
