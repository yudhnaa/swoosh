import Foundation
import Testing
@testable import SwooshCore

@Suite
struct SettingsStoreTests {
    @Test
    func defaultsMatchSpecRanges() {
        let settings = SwooshSettings.defaults

        #expect(settings.isPaused == false)
        #expect(settings.launchAtLogin == false)
        #expect(settings.gesturesEnabled)
        #expect(settings.chainTimeoutMilliseconds == 800)
        #expect(settings.gestureIdleTimeoutMilliseconds == 900)
        #expect(settings.overlayPreviewSize == .large)
        #expect(settings.gridSpacing == 0)
        #expect(settings.centerBehavior == .centerAndUnsnap)
        #expect(settings.generalModifier == .control)
        #expect(settings.screenModifier == .command)
        #expect(SwooshSettings.chainTimeoutRange.contains(settings.chainTimeoutMilliseconds))
        #expect(SwooshSettings.gestureIdleTimeoutRange.contains(settings.gestureIdleTimeoutMilliseconds))
        #expect(SwooshSettings.gridSpacingRange.contains(settings.gridSpacing))
    }

    @Test
    func saveNormalizesAndPersistsSettings() throws {
        let fixture = UserDefaultsFixture()
        defer { fixture.cleanup() }
        let store = UserDefaultsSettingsStore(defaults: fixture.defaults)
        var settings = SwooshSettings.defaults
        settings.isPaused = true
        settings.launchAtLogin = true
        settings.chainTimeoutMilliseconds = 10_000
        settings.gestureIdleTimeoutMilliseconds = 99_000
        settings.overlayPreviewSize = .small
        settings.gridSpacing = 100
        settings.sensitivity = -1
        settings.keyboardBindings = [
            .snapLeft: " Command + Option + Left ",
            .moveDisplayRight: " Control + Option + Right "
        ]

        try store.save(settings)
        let loaded = store.load()

        #expect(loaded.isPaused)
        #expect(loaded.launchAtLogin)
        #expect(loaded.chainTimeoutMilliseconds == 1_200)
        #expect(loaded.gestureIdleTimeoutMilliseconds == 2_000)
        #expect(loaded.overlayPreviewSize == .small)
        #expect(loaded.gridSpacing == 32)
        #expect(loaded.sensitivity == 1)
        #expect(loaded.keyboardBindings[.snapLeft] == "command+option+left")
        #expect(loaded.keyboardBindings[.moveDisplayRight] == "option+control+right")

        settings.sensitivity = 99
        try store.save(settings)
        #expect(store.load().sensitivity == 20)
    }

    @Test
    func duplicateKeyboardBindingsAreRejected() throws {
        let fixture = UserDefaultsFixture()
        defer { fixture.cleanup() }
        let store = UserDefaultsSettingsStore(defaults: fixture.defaults)
        var settings = SwooshSettings.defaults
        settings.keyboardBindings = [
            .snapLeft: "control+left",
            .snapRight: " Control + Left "
        ]

        do {
            try store.save(settings)
            Issue.record("Expected duplicate keyboard binding error")
        } catch SettingsStoreError.duplicateKeyboardBindings(let conflicts) {
            #expect(conflicts.count == 1)
            #expect(conflicts[0].binding == "control+left")
        }
    }

    @Test
    func malformedStoredSettingsReturnDefaults() {
        let fixture = UserDefaultsFixture()
        defer { fixture.cleanup() }
        let store = UserDefaultsSettingsStore(defaults: fixture.defaults)
        fixture.defaults.set(Data("not-json".utf8), forKey: UserDefaultsSettingsStore.defaultKey)

        #expect(store.load() == .defaults)
    }

    @Test
    func restoreDefaultsDoesNotTouchUnrelatedSystemPreferenceKeys() throws {
        let fixture = UserDefaultsFixture()
        defer { fixture.cleanup() }
        let store = UserDefaultsSettingsStore(defaults: fixture.defaults)
        fixture.defaults.set(true, forKey: "mock.system.permission.flag")
        var changed = SwooshSettings.defaults
        changed.isPaused = true
        try store.save(changed)

        let restored = try store.restoreDefaults()

        #expect(restored == .defaults)
        #expect(fixture.defaults.bool(forKey: "mock.system.permission.flag"))
    }

    @Test
    func storedSettingsContainNoProhibitedDiagnosticContent() throws {
        let fixture = UserDefaultsFixture()
        defer { fixture.cleanup() }
        let store = UserDefaultsSettingsStore(defaults: fixture.defaults)
        try store.save(.defaults)

        let raw = try #require(store.rawStoredData())
        let stored = String(decoding: raw, as: UTF8.self)

        #expect(!stored.localizedCaseInsensitiveContains("windowTitle"))
        #expect(!stored.localizedCaseInsensitiveContains("documentText"))
        #expect(!stored.localizedCaseInsensitiveContains("screenshot"))
        #expect(!stored.localizedCaseInsensitiveContains("account"))
        #expect(!stored.localizedCaseInsensitiveContains("license"))
    }
}

private struct UserDefaultsFixture {
    let suiteName = "SwooshCoreTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
