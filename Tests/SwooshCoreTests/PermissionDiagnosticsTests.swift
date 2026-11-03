import Foundation
import Testing
@testable import SwooshCore

@Suite
struct PermissionDiagnosticsTests {
    @Test
    func readinessIsReadyWhenAllRequiredMechanismsAreAvailable() {
        let diagnostics = PermissionDiagnostics(
            accessibilityTrusted: true,
            inputMonitoringTrusted: true,
            privateMultitouch: PrivateCaptureDiagnostics(
                frameworkAvailable: true,
                requiredSymbolsAvailable: true,
                deviceCount: 1,
                started: false,
                reason: "available"
            )
        )

        #expect(diagnostics.readiness == .ready)
    }

    @Test
    func readinessReportsMissingPermissionsAndPrivateCaptureReason() throws {
        let diagnostics = PermissionDiagnostics(
            accessibilityTrusted: false,
            inputMonitoringTrusted: false,
            privateMultitouch: .unavailable
        )

        guard case .blocked(let requirements) = diagnostics.readiness else {
            Issue.record("Expected blocked readiness")
            return
        }

        #expect(requirements.map(\.kind) == [.accessibility, .inputMonitoring, .privateMultitouch])
        #expect(requirements[0].settingsURL?.absoluteString.contains("Privacy_Accessibility") == true)
        #expect(requirements[1].settingsURL?.absoluteString.contains("Privacy_ListenEvent") == true)
        #expect(requirements[2].message == "Private multitouch capture is unavailable.")
    }

    @Test
    func cachedReadsDoNotRunSystemPermissionProbes() {
        let accessibilityProbe = LockedCounter()
        let inputProbe = LockedCounter()
        let initial = PermissionStateSnapshot(
            diagnostics: PermissionDiagnostics(
                accessibilityTrusted: true,
                inputMonitoringTrusted: false,
                privateMultitouch: .unavailable
            )
        )
        let service = PermissionStateService(
            initialState: initial,
            accessibilityProbe: {
                accessibilityProbe.increment()
                return false
            },
            inputMonitoringProbe: {
                inputProbe.increment()
                return true
            }
        )

        #expect(service.isAccessibilityTrusted())
        #expect(service.snapshot().accessibilityTrusted)
        #expect(service.state() == initial)
        #expect(accessibilityProbe.value == 0)
        #expect(inputProbe.value == 0)
    }

    @Test
    func systemRefreshDoesNotOverwritePrivateCapabilityDeviceOrCaptureState() {
        let privateDiagnostics = PrivateCaptureDiagnostics(
            frameworkAvailable: true,
            requiredSymbolsAvailable: true,
            deviceCount: 3,
            startedDeviceCount: 2,
            failedDeviceCount: 1,
            started: true,
            reason: "capture active"
        )
        let service = PermissionStateService(
            accessibilityProbe: { true },
            inputMonitoringProbe: { true }
        )
        service.updatePrivateMultitouch(privateDiagnostics)

        let refreshed = service.refreshSystemPermissions()

        #expect(refreshed.accessibilityTrusted)
        #expect(refreshed.inputMonitoringTrusted)
        #expect(refreshed.privateCapability.frameworkAvailable)
        #expect(refreshed.privateCapability.requiredSymbolsAvailable)
        #expect(refreshed.privateDevices.availableDeviceCount == 3)
        #expect(refreshed.privateCapture.started)
        #expect(refreshed.privateCapture.startedDeviceCount == 2)
        #expect(refreshed.privateCapture.failedDeviceCount == 1)
        #expect(refreshed.privateCapture.reason == "capture active")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
