import Foundation
import Testing

@Suite(.serialized)
struct PackagingPolicyTests {
    @Test
    func productionDryRunAcceptsLockedBundleIdentifierAndStableIdentity() throws {
        let result = try runBuildScript(
            arguments: ["--dry-run", "--identity", "Test Signing Identity"]
        )

        #expect(result.status == 0)
        #expect(result.output.contains("Bundle ID:     com.yudhnaa.Swoosh"))
    }

    @Test
    func releaseDryRunRejectsPlaceholderBundleIdentifier() throws {
        let result = try runBuildScript(
            arguments: [
                "--dry-run", "--identity", "Test Signing Identity",
                "--bundle-id", "com.example.Swoosh"
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("release builds require the production bundle identifier"))
    }

    @Test
    func adHocSigningRequiresExplicitDevelopmentFlag() throws {
        let result = try runBuildScript(
            arguments: ["--dry-run", "--identity", "-"]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("ad-hoc signing requires the explicit --development-ad-hoc flag"))
    }

    @Test
    func explicitDevelopmentAdHocUsesDebugConfiguration() throws {
        let result = try runBuildScript(
            arguments: ["--dry-run", "--development-ad-hoc"]
        )

        #expect(result.status == 0)
        #expect(result.output.contains("Configuration: debug"))
        #expect(result.output.contains("Signing:       -"))
    }

    private func runBuildScript(arguments: [String]) throws -> (status: Int32, output: String) {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [packageRoot.appendingPathComponent("scripts/build_app.sh").path] + arguments
        process.currentDirectoryURL = packageRoot
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
