import Testing
@testable import SwooshCore

@Suite
struct LoginItemTests {
    @Test
    func refreshReflectsEffectiveSystemRegistrationState() {
        var settings = SwooshSettings.defaults
        settings.launchAtLogin = true
        let registrar = LoginRegistrarProbe(state: LoginItemRegistrationState(status: .notRegistered))
        let coordinator = LoginItemCoordinator(registrar: registrar)

        let snapshot = coordinator.refresh(settings: settings)

        #expect(snapshot.settings.launchAtLogin == false)
        #expect(snapshot.state.status == .notRegistered)
    }

    @Test
    func setEnabledStoresOnlyEffectivelyRegisteredState() {
        var settings = SwooshSettings.defaults
        let registrar = LoginRegistrarProbe(state: LoginItemRegistrationState(status: .notRegistered))
        registrar.nextSetState = LoginItemRegistrationState(
            status: .requiresApproval,
            message: "Needs user approval"
        )
        let coordinator = LoginItemCoordinator(registrar: registrar)

        let approval = coordinator.setEnabled(true, settings: settings)

        #expect(registrar.setRequests == [true])
        #expect(approval.settings.launchAtLogin == false)
        #expect(approval.state.status == .requiresApproval)
        #expect(approval.state.message == "Needs user approval")

        settings.launchAtLogin = false
        registrar.nextSetState = LoginItemRegistrationState(status: .registered)
        let registered = coordinator.setEnabled(true, settings: settings)

        #expect(registered.settings.launchAtLogin)
        #expect(registered.state.status == .registered)
    }

    @Test
    func disablingLoginItemClearsPersistedIntent() {
        var settings = SwooshSettings.defaults
        settings.launchAtLogin = true
        let registrar = LoginRegistrarProbe(state: LoginItemRegistrationState(status: .registered))
        registrar.nextSetState = LoginItemRegistrationState(status: .notRegistered)
        let coordinator = LoginItemCoordinator(registrar: registrar)

        let snapshot = coordinator.setEnabled(false, settings: settings)

        #expect(registrar.setRequests == [false])
        #expect(snapshot.settings.launchAtLogin == false)
        #expect(snapshot.state.status == .notRegistered)
    }
}

private final class LoginRegistrarProbe: LoginItemRegistering {
    var currentState: LoginItemRegistrationState
    var nextSetState: LoginItemRegistrationState?
    var setRequests: [Bool] = []

    init(state: LoginItemRegistrationState) {
        currentState = state
    }

    func state() -> LoginItemRegistrationState {
        currentState
    }

    func setEnabled(_ enabled: Bool) -> LoginItemRegistrationState {
        setRequests.append(enabled)
        if let nextSetState {
            currentState = nextSetState
        } else {
            currentState = LoginItemRegistrationState(status: enabled ? .registered : .notRegistered)
        }
        return currentState
    }
}
