import Foundation
import Testing
@testable import SwooshCore

@Suite
struct WindowTargetResolverTests {
    @Test
    func pointerResolutionRequiresAccessibilityPermission() {
        let resolver = makeResolver(accessibilityTrusted: false)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 10, y: 10)).failureValue == .permissionDenied)
    }

    @Test
    func pointerResolutionAcceptsTitlebarRelatedWindowChrome() throws {
        let chrome = element(role: "AXToolbar", path: ["AXToolbar", "AXWindow", "AXApplication"], frame: windowFrame)
        let resolver = makeResolver(hitTest: chrome)

        let target = try #require(resolver.targetUnderPointer(at: ScreenPoint(x: 10, y: 10)).successValue)

        #expect(target.identity == chrome.identity)
        #expect(target.source == WindowTargetSource.pointerTitlebar)
    }

    @Test
    func pointerResolutionAcceptsWindowTitleStaticText() throws {
        let title = element(role: "AXStaticText", path: ["AXStaticText", "AXWindow", "AXApplication"], frame: windowFrame)
        let resolver = makeResolver(hitTest: title)

        let target = try #require(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 112)).successValue)

        #expect(target.identity == title.identity)
        #expect(target.source == WindowTargetSource.pointerTitlebar)
    }

    @Test
    func pointerResolutionRejectsContentInsideWindow() {
        let content = element(role: "AXTextArea", path: ["AXTextArea", "AXScrollArea", "AXWindow", "AXApplication"])
        let resolver = makeResolver(hitTest: content)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 10, y: 10)).failureValue == .excludedSurface("AXTextArea"))
    }

    @Test
    func pointerResolutionRejectsStaticTextInsideContent() {
        let content = element(role: "AXStaticText", path: ["AXStaticText", "AXScrollArea", "AXWindow", "AXApplication"], frame: windowFrame)
        let resolver = makeResolver(hitTest: content)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 220)).failureValue == .excludedSurface("AXStaticText"))
    }

    @Test
    func pointerResolutionRejectsGenericWindowHitOutsideTitlebarBand() {
        let content = element(role: "AXWindow", path: ["AXWindow", "AXApplication"], frame: windowFrame)
        let resolver = makeResolver(hitTest: content)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 260)).failureValue == .excludedSurface("AXWindow"))
    }

    @Test
    func pointerResolutionAcceptsGenericWindowHitInsideTitlebarBand() throws {
        let titlebar = element(role: "AXWindow", path: ["AXWindow", "AXApplication"], frame: windowFrame)
        let resolver = makeResolver(hitTest: titlebar)

        let target = try #require(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 112)).successValue)

        #expect(target.identity == titlebar.identity)
    }

    @Test
    func pointerResolutionAcceptsDirectChromeGroupsInsideTitlebarBand() throws {
        let chrome = element(role: "AXGroup", path: ["AXGroup", "AXWindow", "AXApplication"], frame: windowFrame)
        let resolver = makeResolver(hitTest: chrome)

        let target = try #require(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 112)).successValue)

        #expect(target.identity == chrome.identity)
        #expect(target.source == .pointerTitlebar)
    }

    @Test
    func pointerResolutionRejectsDirectChromeGroupsOutsideTitlebarBand() {
        let content = element(role: "AXGroup", path: ["AXGroup", "AXWindow", "AXApplication"], frame: windowFrame)
        let resolver = makeResolver(hitTest: content)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 260)).failureValue == .excludedSurface("AXGroup"))
    }

    @Test
    func pointerResolutionAcceptsNestedChromeGroupsInsideTitlebarBand() throws {
        let chrome = element(
            role: "AXGroup",
            path: ["AXGroup", "AXGroup", "AXWindow", "AXApplication"],
            frame: windowFrame
        )
        let resolver = makeResolver(hitTest: chrome)

        let target = try #require(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 112)).successValue)

        #expect(target.identity == chrome.identity)
        #expect(target.source == .pointerTitlebar)
    }

    @Test
    func pointerResolutionRejectsNestedChromeGroupsOutsideTitlebarBand() {
        let content = element(
            role: "AXGroup",
            path: ["AXGroup", "AXGroup", "AXWindow", "AXApplication"],
            frame: windowFrame
        )
        let resolver = makeResolver(hitTest: content)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 260)).failureValue == .excludedSurface("AXGroup"))
    }

    @Test
    func pointerResolutionAcceptsElectronTitlebarChromeInsideWebAreaBand() throws {
        let chrome = element(
            role: "AXStaticText",
            path: ["AXStaticText", "AXGroup", "AXWebArea", "AXWindow", "AXApplication"],
            frame: windowFrame
        )
        let resolver = makeResolver(hitTest: chrome)

        let target = try #require(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 112)).successValue)

        #expect(target.identity == chrome.identity)
        #expect(target.source == .pointerTitlebar)
    }

    @Test
    func pointerResolutionRejectsElectronChromeOutsideTitlebarBand() {
        let content = element(
            role: "AXStaticText",
            path: ["AXStaticText", "AXGroup", "AXWebArea", "AXWindow", "AXApplication"],
            frame: windowFrame
        )
        let resolver = makeResolver(hitTest: content)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 120, y: 260)).failureValue == .excludedSurface("AXStaticText"))
    }

    @Test
    func pointerResolutionRejectsMenusAndPopovers() {
        let menu = element(role: "AXMenu", path: ["AXMenu", "AXApplication"])
        let resolver = makeResolver(hitTest: menu)

        #expect(resolver.targetUnderPointer(at: ScreenPoint(x: 10, y: 10)).failureValue == .excludedSurface("AXMenu"))
    }

    @Test
    func keyboardResolutionUsesFrontmostWindow() throws {
        let window = element(role: "AXWindow", path: ["AXWindow", "AXApplication"], actions: ["AXRaise"])
        let resolver = makeResolver(frontmost: window)

        let target = try #require(resolver.frontmostKeyboardTarget().successValue)

        #expect(target.identity == window.identity)
        #expect(target.requireAction("AXRaise").failureValue == nil)
        #expect(target.requireAction("AXPress").failureValue == .unsupported("AXPress"))
    }

    @Test
    func pointerResolutionCanFallbackToFrontmostWindow() throws {
        let frontmost = element(role: "AXWindow", path: ["AXWindow", "AXApplication"], actions: ["AXRaise"], frame: windowFrame)
        let resolver = makeResolver(frontmost: frontmost)

        let target = try #require(resolver.targetUnderPointer(
            at: ScreenPoint(x: 120, y: 112),
            fallingBackToFrontmost: true
        ).successValue)

        #expect(target.identity == frontmost.identity)
        #expect(target.source == .pointerTitlebar)
    }

    @Test
    func pointerResolutionDoesNotFallbackToFrontmostContent() {
        let frontmost = element(role: "AXWindow", path: ["AXWindow", "AXApplication"], actions: ["AXRaise"], frame: windowFrame)
        let resolver = makeResolver(frontmost: frontmost)

        #expect(resolver.targetUnderPointer(
            at: ScreenPoint(x: 120, y: 260),
            fallingBackToFrontmost: true
        ).failureValue == .excludedSurface("AXWindow"))
    }

    @Test
    func pointerResolutionDoesNotFallbackWhenHitTestFindsContent() {
        let content = element(role: "AXTextArea", path: ["AXTextArea", "AXScrollArea", "AXWindow", "AXApplication"], frame: windowFrame)
        let frontmost = element(role: "AXWindow", path: ["AXWindow", "AXApplication"], actions: ["AXRaise"], frame: windowFrame)
        let resolver = makeResolver(hitTest: content, frontmost: frontmost)

        #expect(resolver.targetUnderPointer(
            at: ScreenPoint(x: 120, y: 112),
            fallingBackToFrontmost: true
        ).failureValue == .excludedSurface("AXTextArea"))
    }

    @Test
    func pointerResolutionDoesNotFallbackUnlessRequested() {
        let frontmost = element(role: "AXWindow", path: ["AXWindow", "AXApplication"])
        let resolver = makeResolver(frontmost: frontmost)

        #expect(resolver.targetUnderPointer(
            at: ScreenPoint(x: 10, y: 10),
            fallingBackToFrontmost: false
        ).failureValue == .noTarget)
    }

    @Test
    func latchedTargetSessionFailsWhenOriginalWindowIsLost() {
        let window = element(role: "AXWindow", path: ["AXWindow", "AXApplication"])
        let client = MockAccessibilityClient(frontmost: window, liveIdentities: [])
        let resolver = makeResolver(client: client)
        let target = WindowTarget(identity: window.identity, source: .frontmostKeyboard, rolePath: window.rolePath, availableActions: [])

        let session = resolver.beginSession(with: target)

        #expect(session.requireLiveTarget().failureValue == .targetLost)
    }
}

private func makeResolver(
    accessibilityTrusted: Bool = true,
    hitTest: AccessibilityElementSnapshot? = nil,
    frontmost: AccessibilityElementSnapshot? = nil
) -> WindowTargetResolver {
    makeResolver(
        permissions: StaticPermissionProvider(accessibilityTrusted: accessibilityTrusted),
        client: MockAccessibilityClient(hitTest: hitTest, frontmost: frontmost)
    )
}

private func makeResolver(
    permissions: StaticPermissionProvider = StaticPermissionProvider(accessibilityTrusted: true),
    client: MockAccessibilityClient
) -> WindowTargetResolver {
    WindowTargetResolver(permissions: permissions, client: client)
}

private func element(
    pid: pid_t = 42,
    id: String = "window-1",
    role: String,
    path: [String],
    actions: Set<String> = [],
    frame: GeometryRect? = nil
) -> AccessibilityElementSnapshot {
    AccessibilityElementSnapshot(
        processIdentifier: pid,
        elementIdentifier: id,
        role: role,
        rolePath: path,
        actions: actions,
        frame: frame
    )
}

private var windowFrame: GeometryRect {
    GeometryRect(x: 100, y: 100, width: 900, height: 600)
}

private struct StaticPermissionProvider: PermissionSnapshotProviding {
    var accessibilityTrusted: Bool

    func snapshot() -> PermissionDiagnostics {
        PermissionDiagnostics(
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringTrusted: true,
            privateMultitouch: PrivateCaptureDiagnostics(
                frameworkAvailable: true,
                requiredSymbolsAvailable: true,
                deviceCount: 1,
                started: false,
                reason: "available"
            )
        )
    }
}

private final class MockAccessibilityClient: AccessibilityTargetClient {
    var hitTestElement: AccessibilityElementSnapshot?
    var frontmostElement: AccessibilityElementSnapshot?
    var liveIdentities: Set<WindowTargetIdentity>

    init(
        hitTest: AccessibilityElementSnapshot? = nil,
        frontmost: AccessibilityElementSnapshot? = nil,
        liveIdentities: Set<WindowTargetIdentity>? = nil
    ) {
        hitTestElement = hitTest
        frontmostElement = frontmost
        self.liveIdentities = liveIdentities ?? Set([hitTest, frontmost].compactMap { $0?.identity })
    }

    func hitTest(at point: ScreenPoint) -> AccessibilityElementSnapshot? {
        hitTestElement
    }

    func frontmostWindow() -> AccessibilityElementSnapshot? {
        frontmostElement
    }

    func isAlive(_ identity: WindowTargetIdentity) -> Bool {
        liveIdentities.contains(identity)
    }
}

private extension Result where Failure == WindowTargetFailure {
    var successValue: Success? {
        switch self {
        case .success(let value):
            value
        case .failure:
            nil
        }
    }

    var failureValue: Failure? {
        switch self {
        case .success:
            nil
        case .failure(let failure):
            failure
        }
    }
}
