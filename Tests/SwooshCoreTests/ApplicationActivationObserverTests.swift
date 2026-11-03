import AppKit
import Foundation
import Testing
@testable import SwooshCore

@MainActor
@Suite
struct ApplicationActivationObserverTests {
    @Test
    func activationRefreshIsRegisteredOnceAndStopsCleanly() async {
        let center = NotificationCenter()
        var refreshCount = 0
        let observer = ApplicationActivationObserver(notificationCenter: center) {
            refreshCount += 1
        }

        observer.start()
        observer.start()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(refreshCount == 1)

        observer.stop()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(refreshCount == 1)

        observer.start()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(refreshCount == 2)

        observer.shutdown()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(refreshCount == 2)
    }

    private func settle() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}
