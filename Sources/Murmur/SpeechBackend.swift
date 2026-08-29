import Foundation
@preconcurrency import AVFoundation

/// Which speech engine does the transcribing.
enum BackendKind: String, CaseIterable, Codable {
    /// macOS 26's on-device SpeechAnalyzer. Instant, streaming, few languages.
    case apple
    /// Whisper via CoreML. ~99 languages, a beat slower, no live text.
    case whisper

    var label: String {
        switch self {
        case .apple:   return "Apple (fast, live text)"
        case .whisper: return "Whisper (more languages)"
        }
    }
}

/// What the dictation loop needs from a speech engine.
///
/// Apple's engine streams — buffers in, partial text out. Whisper is batch —
/// it wants the whole utterance at once. The protocol covers both: everyone
/// gets fed buffers, and `supportsLiveText` says whether `onPartial` will
/// ever actually fire.
@MainActor
protocol SpeechBackend: AnyObject {
    var onPartial: (String) -> Void { get set }
    var supportsLiveText: Bool { get }
    /// Whether the model has to be loaded before capture can begin. Batch
    /// engines can buffer audio while they load; streaming ones cannot.
    var needsModelBeforeCapture: Bool { get }
    var currentText: String { get }

    /// Fetch whatever models this backend needs. May take minutes on first run.
    func prepare(locale: Locale, progress: @escaping (String) -> Void) async throws
    func begin(locale: Locale) async throws
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async -> String

    /// Drop the model from memory. Called after a spell of inactivity; the
    /// next dictation loads it again while it records.
    func unloadModel() async
}

@MainActor
enum Backends {
    static func make(_ kind: BackendKind) -> SpeechBackend {
        switch kind {
        case .apple:   return AppleBackend()
        case .whisper: return WhisperBackend()
        }
    }

    static func languages(for kind: BackendKind) -> [Locale] {
        switch kind {
        case .apple:   return AppleBackend.supportedLocales
        case .whisper: return WhisperBackend.supportedLocales
        }
    }

    static func loadCatalog() async {
        await AppleBackend.loadSupportedLocales()
    }

    /// Which locale we'll actually transcribe in.
    ///
    /// An explicit choice wins. Otherwise we walk the user's preferred
    /// languages for one this backend can handle — plenty of system languages
    /// have no Apple model — and fall back to en-US.
    static func resolveLocale(for kind: BackendKind) async -> Locale {
        if kind == .apple && AppleBackend.supportedLocales.isEmpty {
            await AppleBackend.loadSupportedLocales()
        }
        let supported = languages(for: kind)
        guard !supported.isEmpty else { return Locale(identifier: "en-US") }

        func match(_ identifier: String) -> Locale? {
            if let exact = supported.first(where: {
                $0.identifier(.bcp47).caseInsensitiveCompare(identifier) == .orderedSame
            }) { return exact }

            // "en-KZ" has no model, but "en-US" will do fine. Among the
            // regional variants of a language, prefer the user's own region,
            // then the language's usual default — never just the first
            // alphabetically, or an ru-KZ Mac ends up dictating in en-AU.
            let language = identifier.split(separator: "-").first.map(String.init) ?? identifier
            let candidates = supported.filter { $0.language.languageCode?.identifier == language }
            guard !candidates.isEmpty else { return nil }
            if candidates.count == 1 { return candidates[0] }

            if let region = Locale.current.region?.identifier,
               let local = candidates.first(where: { $0.region?.identifier == region }) {
                return local
            }
            let defaults = ["en": "US", "es": "ES", "fr": "FR", "de": "DE",
                            "pt": "BR", "it": "IT", "zh": "CN", "yue": "CN"]
            if let preferred = defaults[language],
               let canonical = candidates.first(where: { $0.region?.identifier == preferred }) {
                return canonical
            }
            return candidates.first
        }

        let chosen = Settings.shared.localeIdentifier
        if !chosen.isEmpty, let locale = match(chosen) { return locale }
        for preferred in Locale.preferredLanguages {
            if let locale = match(preferred) { return locale }
        }
        return match("en-US") ?? supported.first!
    }
}
