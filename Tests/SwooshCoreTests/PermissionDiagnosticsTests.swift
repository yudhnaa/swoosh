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
}
