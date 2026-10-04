import Carbon
import Foundation

public enum KeyboardBindingIssueReason: String, Codable, Equatable, Sendable {
    case duplicate
    case unsupportedFormat
    case unsupportedCommand
    case unsupportedKey
    case missingModifier
    case reservedSystemShortcut
}

public struct KeyboardBindingIssue: Equatable, Sendable {
    public var command: KeyboardCommand
    public var binding: String
    public var reason: KeyboardBindingIssueReason
    public var conflictsWith: KeyboardCommand?

    public init(
        command: KeyboardCommand,
        binding: String,
        reason: KeyboardBindingIssueReason,
        conflictsWith: KeyboardCommand? = nil
    ) {
        self.command = command
        self.binding = binding
        self.reason = reason
        self.conflictsWith = conflictsWith
    }
}

public struct KeyboardShortcut: Hashable, Sendable {
    public static let modifierOrder = ["command", "option", "control", "shift"]
    public static let reservedCanonicalBindings: Set<String> = [
        "command+q",
        "command+w",
        "command+tab",
        "command+space",
        "command+option+escape"
    ]

    public var modifiers: Set<String>
    public var key: String

    public init?(rawValue: String) {
        let tokens = rawValue
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return nil
        }

        let modifierSet = Set(Self.modifierOrder)
        let modifiers = Set(tokens.filter { modifierSet.contains($0) })
        let keys = tokens.filter { !modifierSet.contains($0) }

        guard keys.count == 1 else {
            return nil
        }

        self.modifiers = modifiers
        key = Self.normalizedKey(keys[0])
    }

    public var canonical: String {
        let orderedModifiers = Self.modifierOrder.filter { modifiers.contains($0) }
        return (orderedModifiers + [key]).joined(separator: "+")
    }

    public var isSupported: Bool {
        keyCode != nil && !modifiers.isEmpty
    }

    public var isReserved: Bool {
        Self.reservedCanonicalBindings.contains(canonical)
    }

    public var keyCode: UInt32? {
        Self.keyCodes[key]
    }

    public var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains("command") {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains("option") {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains("control") {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains("shift") {
            flags |= UInt32(shiftKey)
        }
        return flags
    }

    private static func normalizedKey(_ key: String) -> String {
        switch key {
        case "←", "leftarrow":
            "left"
        case "→", "rightarrow":
            "right"
        case "↑", "uparrow":
            "up"
        case "↓", "downarrow":
            "down"
        case "esc":
            "escape"
        case "return":
            "enter"
        default:
            key
        }
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A),
        "b": UInt32(kVK_ANSI_B),
        "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E),
        "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G),
        "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J),
        "k": UInt32(kVK_ANSI_K),
        "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M),
        "n": UInt32(kVK_ANSI_N),
        "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q),
        "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S),
        "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V),
        "w": UInt32(kVK_ANSI_W),
        "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y),
        "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0),
        "1": UInt32(kVK_ANSI_1),
        "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4),
        "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6),
        "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        "left": UInt32(kVK_LeftArrow),
        "right": UInt32(kVK_RightArrow),
        "up": UInt32(kVK_UpArrow),
        "down": UInt32(kVK_DownArrow),
        "space": UInt32(kVK_Space),
        "enter": UInt32(kVK_Return),
        "escape": UInt32(kVK_Escape)
    ]
}

public struct KeyboardBindingValidator {
    public init() {}

    public func issues(for settings: SwooshSettings) -> [KeyboardBindingIssue] {
        var seen: [String: KeyboardCommand] = [:]
        var issues: [KeyboardBindingIssue] = []

        for command in KeyboardCommand.allCases {
            guard let rawBinding = settings.keyboardBindings[command] else {
                continue
            }

            let normalized = SwooshSettings.normalizedBinding(rawBinding)
            guard !normalized.isEmpty else {
                continue
            }

            guard command.isMVPKeyboardCommand else {
                issues.append(KeyboardBindingIssue(command: command, binding: normalized, reason: .unsupportedCommand))
                continue
            }

            guard let shortcut = KeyboardShortcut(rawValue: normalized) else {
                issues.append(KeyboardBindingIssue(command: command, binding: normalized, reason: .unsupportedFormat))
                continue
            }

            if shortcut.modifiers.isEmpty {
                issues.append(KeyboardBindingIssue(command: command, binding: normalized, reason: .missingModifier))
            }

            if shortcut.keyCode == nil {
                issues.append(KeyboardBindingIssue(command: command, binding: normalized, reason: .unsupportedKey))
            }

            if shortcut.isReserved {
                issues.append(KeyboardBindingIssue(command: command, binding: normalized, reason: .reservedSystemShortcut))
            }

            if let existing = seen[shortcut.canonical] {
                issues.append(KeyboardBindingIssue(
                    command: command,
                    binding: shortcut.canonical,
                    reason: .duplicate,
                    conflictsWith: existing
                ))
            } else {
                seen[shortcut.canonical] = command
            }
        }

        return issues
    }
}

public enum KeyboardRegistrationStatus: String, Codable, Equatable, Sendable {
    case registered
    case released
    case failed
    case skipped
}

public struct KeyboardRegistrationRecord: Equatable, Sendable {
    public var command: KeyboardCommand
    public var binding: String
    public var status: KeyboardRegistrationStatus
    public var reason: String?

    public init(command: KeyboardCommand, binding: String, status: KeyboardRegistrationStatus, reason: String? = nil) {
        self.command = command
        self.binding = binding
        self.status = status
        self.reason = reason
    }
}

public protocol KeyboardShortcutRegistering {
    func register(_ binding: String, command: KeyboardCommand) -> KeyboardRegistrationRecord
    func unregister(_ binding: String, command: KeyboardCommand) -> KeyboardRegistrationRecord
    func unregisterAll() -> [KeyboardRegistrationRecord]
}

public final class KeyboardShortcutCoordinator {
    private let registrar: KeyboardShortcutRegistering
    private let validator: KeyboardBindingValidator
    private var activeBindings: [KeyboardCommand: String] = [:]

    public init(
        registrar: KeyboardShortcutRegistering,
        validator: KeyboardBindingValidator = KeyboardBindingValidator()
    ) {
        self.registrar = registrar
        self.validator = validator
    }

    public func apply(_ settings: SwooshSettings) -> [KeyboardRegistrationRecord] {
        if settings.isPaused {
            let released = releaseAll()
            return released
        }

        let normalized = settings.normalized
        let issues = validator.issues(for: normalized)
        if !issues.isEmpty {
            return issues.map {
                KeyboardRegistrationRecord(
                    command: $0.command,
                    binding: $0.binding,
                    status: .failed,
                    reason: $0.reason.rawValue
                )
            }
        }

        var records: [KeyboardRegistrationRecord] = []
        for (command, binding) in activeBindings where normalized.keyboardBindings[command] != binding {
            records.append(registrar.unregister(binding, command: command))
            activeBindings.removeValue(forKey: command)
        }

        for (command, binding) in normalized.keyboardBindings where activeBindings[command] != binding {
            let record = registrar.register(binding, command: command)
            records.append(record)
            if record.status == .registered {
                activeBindings[command] = binding
            }
        }

        return records
    }

    public func releaseAll() -> [KeyboardRegistrationRecord] {
        let records = activeBindings.map { registrar.unregister($0.value, command: $0.key) }
        activeBindings.removeAll()
        return records
    }
}

public final class SystemKeyboardShortcutRegistrar: KeyboardShortcutRegistering {
    private var refs: [KeyboardCommand: EventHotKeyRef] = [:]
    private var ids: [KeyboardCommand: UInt32] = [:]
    private var idToCommand: [UInt32: KeyboardCommand] = [:]
    private var handlerRef: EventHandlerRef?
    private let handler: (KeyboardCommand) -> Void
    private var handlerInstallStatus: OSStatus = noErr
    private var nextID: UInt32 = 1

    public init(handler: @escaping (KeyboardCommand) -> Void = { _ in }) {
        self.handler = handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        handlerInstallStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        handlerRef = installedHandler
    }

    deinit {
        _ = unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    public func register(_ binding: String, command: KeyboardCommand) -> KeyboardRegistrationRecord {
        guard handlerInstallStatus == noErr else {
            return KeyboardRegistrationRecord(
                command: command,
                binding: binding,
                status: .failed,
                reason: "carbonHandlerStatus:\(handlerInstallStatus)"
            )
        }

        guard let shortcut = KeyboardShortcut(rawValue: binding), let keyCode = shortcut.keyCode else {
            return KeyboardRegistrationRecord(command: command, binding: binding, status: .failed, reason: "unsupportedBinding")
        }

        if let existing = refs[command] {
            UnregisterEventHotKey(existing)
            refs.removeValue(forKey: command)
            if let existingID = ids.removeValue(forKey: command) {
                idToCommand.removeValue(forKey: existingID)
            }
        }

        let id = nextID
        let hotKeyID = EventHotKeyID(signature: OSType(UInt32(truncatingIfNeeded: 0x53575348)), id: id)
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            return KeyboardRegistrationRecord(command: command, binding: binding, status: .failed, reason: "carbonStatus:\(status)")
        }

        refs[command] = ref
        ids[command] = id
        idToCommand[id] = command
        return KeyboardRegistrationRecord(command: command, binding: binding, status: .registered)
    }

    public func unregister(_ binding: String, command: KeyboardCommand) -> KeyboardRegistrationRecord {
        if let id = ids.removeValue(forKey: command) {
            idToCommand.removeValue(forKey: id)
        }

        guard let ref = refs.removeValue(forKey: command) else {
            return KeyboardRegistrationRecord(command: command, binding: binding, status: .released)
        }

        let status = UnregisterEventHotKey(ref)
        return status == noErr
            ? KeyboardRegistrationRecord(command: command, binding: binding, status: .released)
            : KeyboardRegistrationRecord(command: command, binding: binding, status: .failed, reason: "carbonStatus:\(status)")
    }

    public func unregisterAll() -> [KeyboardRegistrationRecord] {
        let records = refs.map { command, ref in
            let status = UnregisterEventHotKey(ref)
            return status == noErr
                ? KeyboardRegistrationRecord(command: command, binding: "", status: .released)
                : KeyboardRegistrationRecord(command: command, binding: "", status: .failed, reason: "carbonStatus:\(status)")
        }
        refs.removeAll()
        ids.removeAll()
        idToCommand.removeAll()
        return records
    }

    private func handleHotKey(id: UInt32) {
        guard let command = idToCommand[id] else {
            return
        }

        handler(command)
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }

        let registrar = Unmanaged<SystemKeyboardShortcutRegistrar>
            .fromOpaque(userData)
            .takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else {
            return status
        }

        registrar.handleHotKey(id: hotKeyID.id)
        return noErr
    }
}

public extension KeyboardCommand {
    var isMVPKeyboardCommand: Bool {
        switch self {
        case .moveSpaceUp, .moveSpaceDown:
            false
        default:
            true
        }
    }

    var displayName: String {
        switch self {
        case .snapLeft:
            "Snap Left"
        case .snapRight:
            "Snap Right"
        case .snapTop:
            "Snap Top"
        case .snapBottom:
            "Snap Bottom"
        case .snapTopLeft:
            "Snap Top Left"
        case .snapTopRight:
            "Snap Top Right"
        case .snapBottomLeft:
            "Snap Bottom Left"
        case .snapBottomRight:
            "Snap Bottom Right"
        case .maximize:
            "Maximize"
        case .center:
            "Center"
        case .unsnap:
            "Restore"
        case .centerAndUnsnap:
            "Center and Restore"
        case .minimize:
            "Minimize"
        case .close:
            "Close"
        case .toggleFullscreen:
            "Toggle Full Screen"
        case .moveDisplayLeft:
            "Move to Display Left"
        case .moveDisplayRight:
            "Move to Display Right"
        case .moveDisplayUp:
            "Move to Display Up"
        case .moveDisplayDown:
            "Move to Display Down"
        case .moveSpaceLeft:
            "Move to Space Left"
        case .moveSpaceRight:
            "Move to Space Right"
        case .moveSpaceUp:
            "Move to Space Up"
        case .moveSpaceDown:
            "Move to Space Down"
        }
    }
}

extension KeyboardShortcutCoordinator: LifecycleResource {
    public func shutdown() {
        _ = releaseAll()
    }
}
