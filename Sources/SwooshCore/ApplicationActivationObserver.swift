import AppKit
import Foundation

/// Observes AppKit application activation events to trigger lifecycle or permission updates.
@MainActor
public final class ApplicationActivationObserver: LifecycleResource {
    private var token: (any NSObjectProtocol)?
    private let notificationCenter: NotificationCenter
    private let onBecomeActive: @MainActor () -> Void

    public init(
        notificationCenter: NotificationCenter = .default,
        onBecomeActive: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.onBecomeActive = onBecomeActive
    }

    public func start() {
        guard token == nil else { return }
        token = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.onBecomeActive()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.onBecomeActive()
                }
            }
        }
    }

    public func stop() {
        if let token {
            notificationCenter.removeObserver(token)
            self.token = nil
        }
    }

    public func shutdown() {
        stop()
    }
}
