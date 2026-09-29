public struct DependencyCredit: Equatable, Sendable {
    public var name: String
    public var purpose: String

    public init(name: String, purpose: String) {
        self.name = name
        self.purpose = purpose
    }
}

public enum DependencyCredits {
    public static let current: [DependencyCredit] = [
        DependencyCredit(name: "Creator", purpose: "Yudhna"),
        DependencyCredit(name: "GitHub", purpose: "https://github.com/yudhnaa/swoosh"),
        DependencyCredit(name: "Contact", purpose: "hoanganhduy75@gmail.com")
    ]
}
