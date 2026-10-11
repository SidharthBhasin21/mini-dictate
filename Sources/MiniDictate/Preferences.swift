import CoreGraphics
import Foundation
import Security

/// The key that is held to dictate. All three are modifier keys, so they can be watched without swallowing typing.
enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, fn

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }

    /// Set in the event's flags while the key is down.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .fn: return .maskSecondaryFn
        }
    }

    /// Reads naturally after "Hold".
    var name: String {
        switch self {
        case .rightOption: return "right Option"
        case .rightCommand: return "right Command"
        case .fn: return "Fn"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .fn: return "fn"
        }
    }

    var title: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .fn: return "Fn 🌐"
        }
    }
}

enum CleanupProvider: String, CaseIterable, Identifiable {
    case off, anthropic, openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI-compatible"
        }
    }

    var defaultModel: String {
        switch self {
        case .off: return ""
        case .anthropic: return "claude-opus-5-5"
        case .openAI: return "gpt-4o-mini"
        }
    }
}

/// User settings. Choices live in UserDefaults; API keys live in the macOS Keychain.
enum Preferences {
    private static let defaults = UserDefaults.standard
    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"

    static var hotkey: Hotkey {
        get { defaults.string(forKey: "hotkey").flatMap(Hotkey.init(rawValue:)) ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var cleanupProvider: CleanupProvider {
        get { defaults.string(forKey: "cleanupProvider").flatMap(CleanupProvider.init(rawValue:)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "cleanupProvider") }
    }

    static func model(for provider: CleanupProvider) -> String {
        let saved = defaults.string(forKey: "cleanupModel.\(provider.rawValue)") ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }

    static func setModel(_ model: String, for provider: CleanupProvider) {
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: "cleanupModel.\(provider.rawValue)")
    }

    static var openAIBaseURL: String {
        get {
            let saved = defaults.string(forKey: "openAIBaseURL") ?? ""
            return saved.isEmpty ? defaultOpenAIBaseURL : saved
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "openAIBaseURL") }
    }

    // MARK: API keys (Keychain)

    private static func keychainQuery(_ provider: CleanupProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.minidictate.cleanup",
         kSecAttrAccount as String: provider.rawValue]
    }

    static func apiKey(for provider: CleanupProvider) -> String? {
        var query = keychainQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the key, or removes it when `key` is nil or empty. Returns false if the Keychain refused.
    @discardableResult
    static func setAPIKey(_ key: String?, for provider: CleanupProvider) -> Bool {
        SecItemDelete(keychainQuery(provider) as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return true }
        var query = keychainQuery(provider)
        query[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

/// The hotkey the event tap matches against; kept in a global because the tap callback is a C function.
var activeHotkey = Preferences.hotkey
