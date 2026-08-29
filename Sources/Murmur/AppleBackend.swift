import Foundation
@preconcurrency import AVFoundation
import Speech

/// Streaming on-device recognition via macOS 26's SpeechAnalyzer.
/// Fast and live, but Apple only ships models for a handful of languages.
@MainActor
final class AppleBackend: SpeechBackend {

    enum BackendError: LocalizedError {
        case localeUnsupported(String)
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let id):
                return "Apple's transcriber has no model for \(id). Switch to the Whisper backend."
            case .noAudioFormat:
                return "Couldn't negotiate an audio format with the speech analyzer."
            }
        }
    }

    var onPartial: (String) -> Void = { _ in }
    var supportsLiveText: Bool { true }
    var needsModelBeforeCapture: Bool { true }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var resampler: AudioResampler?

    private var finalText = ""
    private var volatileText = ""

    var currentText: String {
        (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Locales

    /// Fetched once and cached so menus can read it synchronously.
    private(set) static var supportedLocales: [Locale] = []

    static func loadSupportedLocales() async {
        supportedLocales = await SpeechTranscriber.supportedLocales
            .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
    }

    // MARK: - SpeechBackend

    func prepare(locale: Locale, progress: @escaping (String) -> Void) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw BackendError.localeUnsupported(locale.identifier(.bcp47))
        }
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }

        progress("Downloading \(locale.identifier(.bcp47)) model…")
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    func begin(locale: Locale) async throws {
        finalText = ""
        volatileText = ""

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw BackendError.noAudioFormat
        }
        resampler = AudioResampler(to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.finalText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    self.onPartial(self.currentText)
                }
            } catch {
                NSLog("Murmur: transcription stream ended — \(error.localizedDescription)")
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let inputContinuation, let converted = resampler?.resample(buffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    /// The analyzer is built per dictation, so there's nothing held between them.
    func unloadModel() async {}

    func finish() async -> String {
        inputContinuation?.finish()
        inputContinuation = nil

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()

        // Let the stream deliver its last segment before tearing down, but
        // don't hang the paste forever if it never closes.
        let watchdog = Task { [resultsTask] in
            try? await Task.sleep(for: .milliseconds(1500))
            resultsTask?.cancel()
        }
        _ = await resultsTask?.value
        watchdog.cancel()
        resultsTask = nil

        analyzer = nil
        transcriber = nil
        resampler = nil

        return currentText
    }
}
