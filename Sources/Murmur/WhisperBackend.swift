import Foundation
@preconcurrency import AVFoundation
@preconcurrency import WhisperKit

/// Whisper via CoreML. Slower than Apple's engine and batch rather than
/// streaming, but it covers ~99 languages — including the ones Apple skips.
///
/// The model is downloaded once (hundreds of MB) and the loaded instance is
/// kept alive between dictations, because loading it costs seconds.
@MainActor
final class WhisperBackend: SpeechBackend {

    enum BackendError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "Whisper model isn't loaded yet." }
    }

    var onPartial: (String) -> Void = { _ in }
    /// Whisper only speaks once the audio stops, so there's nothing live to show.
    var supportsLiveText: Bool { false }
    private(set) var currentText = ""

    /// Shared across dictations — loading is expensive, keep it warm.
    private static var kit: WhisperKit?
    private static var loadedModel: String?
    /// In-flight load. Concurrent callers join it rather than starting a
    /// second one — two parallel WhisperKit loads serialise and take twice as
    /// long, which is what let a stale dictation task wake up mid-recording.
    private static var loadTask: Task<WhisperKit, Error>?

    private var resampler: AudioResampler?
    private var samples: [Float] = []
    private var language: String = "en"

    /// A generous ceiling so a stuck key can't eat all of memory.
    /// 16 kHz mono float ≈ 3.8 MB per minute.
    private let maxSamples = 16_000 * 60 * 10

    /// WhisperKit defaults to ~/Documents/huggingface, which is no place for a
    /// Mac app to leave hundreds of MB. Keep models in Application Support,
    /// where an uninstall can find them.
    static var downloadBase: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// What to use when the user hasn't picked a model.
    ///
    /// WhisperKit's own recommendation is full large-v3 — ~1.5 GB and slow to
    /// decode. Dictation is latency-sensitive, so prefer the quantised turbo
    /// build: near-large accuracy, roughly 4x faster, less than half the
    /// download. Distil models decode faster still but are English-only, which
    /// defeats the point of having this backend at all.
    static func defaultModel() -> String {
        let support = WhisperKit.recommendedModels()
        let preferred = [
            "openai_whisper-large-v3-v20240930_turbo_632MB",
            "openai_whisper-large-v3-v20240930_turbo",
            "openai_whisper-large-v3_turbo_954MB",
        ]
        for name in preferred
        where support.supported.contains(name) && !support.disabled.contains(name) {
            return name
        }
        return support.default
    }

    // MARK: - Locales

    /// Every language Whisper knows, as locales, sorted by display name.
    static let supportedLocales: [Locale] = {
        Constants.languages.values
            .map { Locale(identifier: $0) }
            .sorted {
                let a = Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
                let b = Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
                return a < b
            }
    }()

    // MARK: - SpeechBackend

    func prepare(locale: Locale, progress: @escaping (String) -> Void) async throws {
        let wanted = Settings.shared.whisperModel.isEmpty
            ? Self.defaultModel()
            : Settings.shared.whisperModel

        if Self.kit != nil, Self.loadedModel == wanted { return }

        if let existing = Self.loadTask {
            _ = try await existing.value
            return
        }

        progress("Preparing Whisper — first run downloads the model…")
        let config = WhisperKitConfig(
            model: wanted,
            downloadBase: Self.downloadBase,
            tokenizerFolder: Self.downloadBase.appendingPathComponent("tokenizers"),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        // First run pulls the model from HuggingFace; that can take minutes.
        let task = Task { try await WhisperKit(config) }
        Self.loadTask = task
        defer { Self.loadTask = nil }

        let kit = try await task.value
        Self.kit = kit
        Self.loadedModel = wanted
    }

    /// Whisper only needs the model once the audio stops, so recording can
    /// start while it is still loading. Apple's analyzer can't.
    var needsModelBeforeCapture: Bool { false }

    func unloadModel() async {
        // Never yank it out from under an in-flight load.
        guard Self.loadTask == nil else { return }
        // Dropping the reference isn't enough — CoreML keeps the compiled
        // models resident until WhisperKit tears them down explicitly.
        await Self.kit?.unloadModels()
        Self.kit = nil
        Self.loadedModel = nil
    }

    func begin(locale: Locale) async throws {
        // Deliberately no model check: buffering audio needs nothing but a
        // resampler, and finish() waits for the load. Requiring the model here
        // is what made the first press after launch vanish.
        currentText = ""
        samples = []
        samples.reserveCapacity(16_000 * 10)
        language = locale.language.languageCode?.identifier ?? "en"
        resampler = AudioResampler(to: AudioResampler.whisperFormat)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard samples.count < maxSamples,
              let converted = resampler?.resample(buffer) else { return }
        samples.append(contentsOf: AudioResampler.samples(of: converted))
    }

    func finish() async -> String {
        defer {
            samples = []
            resampler = nil
        }

        // Recording may have started before the model finished loading. Take
        // the value from the load task itself rather than re-reading the
        // shared property: whoever owns that load assigns it on its own
        // continuation, which may not have run yet when we wake up.
        var loaded = Self.kit
        if loaded == nil, let loading = Self.loadTask {
            loaded = try? await loading.value
        }
        guard let kit = loaded else {
            NSLog("Murmur: transcription skipped — model never became available")
            return ""
        }

        // Whisper was trained on a great deal of subtitled video, so asked to
        // transcribe silence it confabulates closing credits — "Субтитры
        // подогнал «Симон»", "Thanks for watching!", and friends. Length alone
        // doesn't catch it: a long recording of room tone hallucinates too.
        // Gate on level instead, and simply don't ask the model what it heard.
        guard samples.count > 4_800, Self.hasSpeech(samples) else { return "" }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        // Off the main actor: inference would otherwise freeze the overlay.
        let audio = samples
        let text: String
        do {
            let results = try await Task.detached(priority: .userInitiated) {
                try await kit.transcribe(audioArray: audio, decodeOptions: options)
            }.value
            text = results.map(\.text).joined(separator: " ")
        } catch {
            NSLog("Murmur: whisper transcription failed — \(error.localizedDescription)")
            return ""
        }

        currentText = Self.tidy(text)
        return currentText
    }

    /// Loudest 100 ms window in the recording.
    ///
    /// Deliberately not the average: someone who holds the key, pauses, says
    /// four words and lets go produces a recording that is mostly silence, and
    /// an averaged level would throw the words away.
    nonisolated static func loudestWindow(_ samples: [Float], windowSamples: Int = 1_600) -> Float {
        guard !samples.isEmpty else { return 0 }
        var loudest: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(index + windowSamples, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - index)).squareRoot()
            loudest = max(loudest, rms)
            index = end
        }
        return loudest
    }

    /// Against a floor well below quiet speech, which sits around 0.02–0.1.
    nonisolated static func hasSpeech(_ samples: [Float], floor: Float = 0.004) -> Bool {
        loudestWindow(samples) > floor
    }

    /// Whisper pads output with leading spaces and the odd bracketed
    /// annotation like "[BLANK_AUDIO]" or "(music)".
    nonisolated static func tidy(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: "\\[[A-Z_ ]+\\]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
