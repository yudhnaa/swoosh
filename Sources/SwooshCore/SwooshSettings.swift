import Foundation

public enum CenterBehavior: String, Codable, CaseIterable, Equatable, Sendable {
    case centerAndUnsnap
    case center
    case unsnap
}

public enum OverlayPreviewSize: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case small
    case medium
    case large
}

public enum ModifierRole: String, Codable, CaseIterable, Equatable, Sendable {
    case control
    case command
    case option
    case shift
    case function
}

public enum KeyboardCommand: String, Codable, CaseIterable, Hashable, Sendable {
    case snapLeft
    case snapRight
    case snapTop
    case snapBottom
    case snapTopLeft
    case snapTopRight
    case snapBottomLeft
    case snapBottomRight
    case maximize
    case center
    case unsnap
    case centerAndUnsnap
    case minimize
    case close
    case toggleFullscreen
    case moveDisplayLeft
    case moveDisplayRight
    case moveDisplayUp
    case moveDisplayDown
    case moveSpaceLeft
    case moveSpaceRight
    case moveSpaceUp
    case moveSpaceDown
}

public struct SwooshSettings: Codable, Equatable, Sendable {
    public static let defaultChainTimeoutMilliseconds = 800
    public static let defaultGestureIdleTimeoutMilliseconds = 900
    public static let chainTimeoutRange = 200...1_200
    public static let gestureIdleTimeoutRange = 300...2_000
    public static let gridSpacingRange = 0...32
    public static let sensitivityRange = 1...20

    public var showInDock: Bool
    public var showInMenuBar: Bool
    public var isPaused: Bool
    public var launchAtLogin: Bool
    public var gesturesEnabled: Bool
    public var sensitivity: Int
    public var chainTimeoutMilliseconds: Int
    public var gestureIdleTimeoutMilliseconds: Int
    public var previewsEnabled: Bool
    public var overlayPreviewSize: OverlayPreviewSize
    public var gridSpacing: Int
    public var centerBehavior: CenterBehavior
    public var generalModifier: ModifierRole
    public var screenModifier: ModifierRole
    public var keyboardBindings: [KeyboardCommand: String]

    public init(
        showInDock: Bool = false,
        showInMenuBar: Bool = true,
        isPaused: Bool = false,
        launchAtLogin: Bool = false,
        gesturesEnabled: Bool = true,
        sensitivity: Int = 3,
        chainTimeoutMilliseconds: Int = SwooshSettings.defaultChainTimeoutMilliseconds,
        gestureIdleTimeoutMilliseconds: Int = SwooshSettings.defaultGestureIdleTimeoutMilliseconds,
        previewsEnabled: Bool = true,
        overlayPreviewSize: OverlayPreviewSize = .large,
        gridSpacing: Int = 0,
        centerBehavior: CenterBehavior = .centerAndUnsnap,
        generalModifier: ModifierRole = .control,
        screenModifier: ModifierRole = .command,
        keyboardBindings: [KeyboardCommand: String] = [:]
    ) {
        self.showInDock = showInDock
        self.showInMenuBar = showInMenuBar
        self.isPaused = isPaused
        self.launchAtLogin = launchAtLogin
        self.gesturesEnabled = gesturesEnabled
        self.sensitivity = sensitivity
        self.chainTimeoutMilliseconds = chainTimeoutMilliseconds
        self.gestureIdleTimeoutMilliseconds = gestureIdleTimeoutMilliseconds
        self.previewsEnabled = previewsEnabled
        self.overlayPreviewSize = overlayPreviewSize
        self.gridSpacing = gridSpacing
        self.centerBehavior = centerBehavior
        self.generalModifier = generalModifier
        self.screenModifier = screenModifier
        self.keyboardBindings = keyboardBindings
    }

    public static var defaults: SwooshSettings {
        SwooshSettings()
    }

    public var normalized: SwooshSettings {
        var copy = self
        copy.sensitivity = copy.sensitivity.clamped(to: Self.sensitivityRange)
        copy.chainTimeoutMilliseconds = copy.chainTimeoutMilliseconds.clamped(to: Self.chainTimeoutRange)
        copy.gestureIdleTimeoutMilliseconds = copy.gestureIdleTimeoutMilliseconds.clamped(to: Self.gestureIdleTimeoutRange)
        copy.gridSpacing = copy.gridSpacing.clamped(to: Self.gridSpacingRange)
        copy.keyboardBindings = Self.normalizedBindings(copy.keyboardBindings)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case showInDock
        case showInMenuBar
        case isPaused
        case launchAtLogin
        case gesturesEnabled
        case sensitivity
        case chainTimeoutMilliseconds
        case gestureIdleTimeoutMilliseconds
        case previewsEnabled
        case overlayPreviewSize
        case gridSpacing
        case centerBehavior
        case generalModifier
        case screenModifier
        case keyboardBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            showInDock: try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false,
            showInMenuBar: try container.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true,
            isPaused: try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            gesturesEnabled: try container.decodeIfPresent(Bool.self, forKey: .gesturesEnabled) ?? true,
            sensitivity: try container.decodeIfPresent(Int.self, forKey: .sensitivity) ?? 3,
            chainTimeoutMilliseconds: try container.decodeIfPresent(Int.self, forKey: .chainTimeoutMilliseconds) ?? Self.defaultChainTimeoutMilliseconds,
            gestureIdleTimeoutMilliseconds: try container.decodeIfPresent(Int.self, forKey: .gestureIdleTimeoutMilliseconds) ?? Self.defaultGestureIdleTimeoutMilliseconds,
            previewsEnabled: try container.decodeIfPresent(Bool.self, forKey: .previewsEnabled) ?? true,
            overlayPreviewSize: try container.decodeIfPresent(OverlayPreviewSize.self, forKey: .overlayPreviewSize) ?? .large,
            gridSpacing: try container.decodeIfPresent(Int.self, forKey: .gridSpacing) ?? 0,
            centerBehavior: try container.decodeIfPresent(CenterBehavior.self, forKey: .centerBehavior) ?? .centerAndUnsnap,
            generalModifier: try container.decodeIfPresent(ModifierRole.self, forKey: .generalModifier) ?? .control,
            screenModifier: try container.decodeIfPresent(ModifierRole.self, forKey: .screenModifier) ?? .command,
            keyboardBindings: try container.decodeIfPresent([KeyboardCommand: String].self, forKey: .keyboardBindings) ?? [:]
        )
    }

    public func bindingConflicts() -> [KeyboardBindingConflict] {
        var seen: [String: KeyboardCommand] = [:]
        var conflicts: [KeyboardBindingConflict] = []

        for (command, binding) in keyboardBindings {
            let normalized = Self.normalizedBinding(binding)
            guard !normalized.isEmpty else {
                continue
            }

            if let existing = seen[normalized] {
                conflicts.append(KeyboardBindingConflict(binding: normalized, first: existing, second: command))
            } else {
                seen[normalized] = command
            }
        }

        return conflicts
    }

    public static func normalizedBinding(_ binding: String) -> String {
        KeyboardShortcut(rawValue: binding)?.canonical
            ?? binding
                .split(separator: "+")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .joined(separator: "+")
    }

    private static func normalizedBindings(_ bindings: [KeyboardCommand: String]) -> [KeyboardCommand: String] {
        bindings.reduce(into: [:]) { result, item in
            let normalized = normalizedBinding(item.value)
            if !normalized.isEmpty {
                result[item.key] = normalized
            }
        }
    }
}

public struct KeyboardBindingConflict: Equatable, Sendable {
    public var binding: String
    public var first: KeyboardCommand
    public var second: KeyboardCommand
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
