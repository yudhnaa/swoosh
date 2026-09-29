import Foundation

public enum LoginItemRegistrationStatus: String, Codable, Equatable, Sendable {
    case notRegistered
    case registered
    case requiresApproval
    case notFound
    case unavailable
    case error
}

public struct LoginItemRegistrationState: Equatable, Sendable {
    public var status: LoginItemRegistrationStatus
    public var message: String?

    public init(status: LoginItemRegistrationStatus, message: String? = nil) {
        self.status = status
        self.message = message
    }

    public var isEffectivelyEnabled: Bool {
        status == .registered
    }
}

public protocol LoginItemRegistering {
    func state() -> LoginItemRegistrationState
    func setEnabled(_ enabled: Bool) -> LoginItemRegistrationState
}

public final class LoginItemCoordinator {
    private let registrar: LoginItemRegistering

    public init(registrar: LoginItemRegistering) {
        self.registrar = registrar
    }

    public func refresh(settings: SwooshSettings) -> (settings: SwooshSettings, state: LoginItemRegistrationState) {
        reconcile(settings: settings, state: registrar.state())
    }

    public func setEnabled(_ enabled: Bool, settings: SwooshSettings) -> (settings: SwooshSettings, state: LoginItemRegistrationState) {
        let state = registrar.setEnabled(enabled)
        return reconcile(settings: settings, state: state)
    }

    private func reconcile(
        settings: SwooshSettings,
        state: LoginItemRegistrationState
    ) -> (settings: SwooshSettings, state: LoginItemRegistrationState) {
        var reconciled = settings.normalized
        reconciled.launchAtLogin = state.isEffectivelyEnabled
        return (reconciled, state)
    }
}
