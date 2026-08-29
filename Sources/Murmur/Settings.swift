import Foundation
import AppKit

/// Which physical key you hold down to dictate.
enum TriggerKey: String, CaseIterable, Codable {
    case rightOption
    case leftOption
    case rightCommand
    case fn

    var label: String {
        switch self {
        case .rightOption:  return "Right ⌥"
        case .leftOption:   return "Left ⌥"
        case .rightCommand: return "Right ⌘"
        case .fn:           return "fn"
        }
    }

    /// Virtual keycode reported by the `flagsChanged` event for this key.
    var keyCode: Int64 {
        switch self {
        case .leftOption:   return 58
        case .rightOption:  return 61
        case .rightCommand: return 54
        case .fn:           return 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .leftOption, .rightOption:  return .maskAlternate
        case .rightCommand:              return .maskCommand
        case .fn:                        return .maskSecondaryFn
        }
    }
}

/// Hold-to-talk, or tap-to-start and tap-to-stop.
enum ActivationMode: String, CaseIterable, Codable {
    case hold, toggle

    var label: String {
        switch self {
        case .hold:   return "Hold the key"
        case .toggle: return "Tap to start, tap to stop"
        }
    }
}

/// How the transcript gets cleaned up before it lands in your app.
enum CleanupMode: String, CaseIterable, Codable {
    case off        // raw transcript, exactly as heard
    case local      // on-device Foundation Model
    case remote     // OpenAI-compatible endpoint (Groq, OpenAI, llama.cpp, ...)

    var label: String {
        switch self {
        case .off:    return "Off (raw transcript)"
        case .local:  return "On-device model"
        case .remote: return "Remote API"
        }
    }
}

/// Plain UserDefaults-backed settings. Deliberately boring.
final class Settings {
    static let shared = Settings()

    /// Sentinel for `localeIdentifier` meaning "let the engine detect it".
    /// Distinct from empty, which means "infer from my system languages".
    static let autoDetectLocale = "auto-detect"
    private let defaults = UserDefaults.standard

    private enum Key {
        static let trigger = "trigger"
        static let cleanup = "cleanup"
        static let locale = "locale"
        static let minimumHold = "minimumHold"
        static let playSounds = "playSounds"
        static let remoteBaseURL = "remoteBaseURL"
        static let remoteModel = "remoteModel"
        static let vocabulary = "vocabulary"
        static let backend = "backend"
        static let whisperModel = "whisperModel"
        static let saveHistory = "saveHistory"
        static let hasLaunched = "hasLaunched"
        static let unloadAfterIdle = "unloadAfterIdle"
        static let useAccessibilityInsert = "useAccessibilityInsert"
        static let activation = "activation"
        static let editTrigger = "editTrigger"
        static let idleMinutes = "idleMinutes"
    }

    var trigger: TriggerKey {
        get { TriggerKey(rawValue: defaults.string(forKey: Key.trigger) ?? "") ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: Key.trigger) }
    }

    /// Which speech engine transcribes. Apple's is faster but covers far
    /// fewer languages; Whisper covers nearly everything.
    var backend: BackendKind {
        get { BackendKind(rawValue: defaults.string(forKey: Key.backend) ?? "") ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    /// Empty means "let WhisperKit pick what this Mac can handle".
    var whisperModel: String {
        get { defaults.string(forKey: Key.whisperModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.whisperModel) }
    }

    var cleanup: CleanupMode {
        get { CleanupMode(rawValue: defaults.string(forKey: Key.cleanup) ?? "") ?? .local }
        set { defaults.set(newValue.rawValue, forKey: Key.cleanup) }
    }

    /// Empty means "pick the best supported match for my system languages".
    /// Not every system language has an on-device model, so we can't just
    /// default to Locale.current — see Transcriber.resolveLocale.
    var localeIdentifier: String {
        get { defaults.string(forKey: Key.locale) ?? "" }
        set { defaults.set(newValue, forKey: Key.locale) }
    }

    /// Taps shorter than this are treated as accidental and discarded.
    var minimumHold: TimeInterval {
        get { defaults.object(forKey: Key.minimumHold) as? TimeInterval ?? 0.25 }
        set { defaults.set(newValue, forKey: Key.minimumHold) }
    }

    var playSounds: Bool {
        get { defaults.object(forKey: Key.playSounds) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }

    var remoteBaseURL: String {
        get { defaults.string(forKey: Key.remoteBaseURL) ?? "https://api.groq.com/openai/v1" }
        set { defaults.set(newValue, forKey: Key.remoteBaseURL) }
    }

    var remoteModel: String {
        get { defaults.string(forKey: Key.remoteModel) ?? "llama-3.3-70b-versatile" }
        set { defaults.set(newValue, forKey: Key.remoteModel) }
    }

    /// Hold the key down, or tap once to start and again to stop.
    var activation: ActivationMode {
        get { ActivationMode(rawValue: defaults.string(forKey: Key.activation) ?? "") ?? .hold }
        set { defaults.set(newValue.rawValue, forKey: Key.activation) }
    }

    /// Key for rewriting the current selection by voice. Nil disables it.
    var editTrigger: TriggerKey? {
        get {
            guard let raw = defaults.string(forKey: Key.editTrigger), raw != "none" else { return nil }
            return TriggerKey(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue ?? "none", forKey: Key.editTrigger) }
    }

    /// Try the Accessibility API before the pasteboard. Off by default —
    /// it silently fails in Electron apps, which is worse than clipboard churn.
    var useAccessibilityInsert: Bool {
        get { defaults.object(forKey: Key.useAccessibilityInsert) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.useAccessibilityInsert) }
    }

    /// The Whisper model is a few hundred MB resident. Drop it when unused.
    var unloadAfterIdle: Bool {
        get { defaults.object(forKey: Key.unloadAfterIdle) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.unloadAfterIdle) }
    }

    var idleMinutes: Int {
        get { defaults.object(forKey: Key.idleMinutes) as? Int ?? 5 }
        set { defaults.set(newValue, forKey: Key.idleMinutes) }
    }

    /// False on the very first run, so we can show the window rather than
    /// leave someone hunting for a menu bar icon that may be behind the notch.
    var hasLaunched: Bool {
        get { defaults.bool(forKey: Key.hasLaunched) }
        set { defaults.set(newValue, forKey: Key.hasLaunched) }
    }

    /// Transcripts are kept in plain text on disk. Some people won't want that.
    var saveHistory: Bool {
        get { defaults.object(forKey: Key.saveHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.saveHistory) }
    }

    /// Proper nouns / jargon the transcriber keeps getting wrong.
    var vocabulary: [String] {
        get { defaults.stringArray(forKey: Key.vocabulary) ?? [] }
        set { defaults.set(newValue, forKey: Key.vocabulary) }
    }
}
