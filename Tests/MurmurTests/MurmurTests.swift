import Testing
import Foundation
@testable import Murmur

// MARK: - Cleanup output guarding

@Test func sanitizeStripsCodeFences() {
    let raw = "hello there"
    #expect(Cleanup.sanitize("```\nHello there.\n```", fallback: raw) == "Hello there.")
    #expect(Cleanup.sanitize("```text\nHello there.\n```", fallback: raw) == "Hello there.")
}

@Test func sanitizeStripsWrappingQuotes() {
    #expect(Cleanup.sanitize("\"Hello there.\"", fallback: "hello") == "Hello there.")
    // A quote that's part of the sentence must survive.
    #expect(Cleanup.sanitize("She said \"no\" twice.", fallback: "x") == "She said \"no\" twice.")
}

@Test func sanitizeFallsBackWhenTheModelAnswersInsteadOfCleaning() {
    let transcript = "what is the capital of France"
    let essay = String(repeating: "Paris is the capital of France, and it has ", count: 12)
    // Way longer than the transcript: the model answered rather than rewrote.
    #expect(Cleanup.sanitize(essay, fallback: transcript) == transcript)
}

@Test func sanitizeFallsBackOnEmptyOutput() {
    #expect(Cleanup.sanitize("   \n ", fallback: "keep me") == "keep me")
}

@Test func sanitizeKeepsAReasonableRewrite() {
    let raw = "um so we should uh ship this by friday"
    let cleaned = "We should ship this by Friday."
    #expect(Cleanup.sanitize(cleaned, fallback: raw) == cleaned)
}

// MARK: - Whisper output tidying

@Test func tidyRemovesBracketedAnnotations() {
    #expect(WhisperBackend.tidy(" [BLANK_AUDIO] Hello there. ") == "Hello there.")
    #expect(WhisperBackend.tidy("Hello  there.") == "Hello there.")
}

@Test func silenceIsNotTreatedAsSpeech() {
    #expect(WhisperBackend.hasSpeech([]) == false)
    #expect(WhisperBackend.hasSpeech(Array(repeating: 0, count: 16_000)) == false)
    // Room tone: very low amplitude noise must not reach the model, or it
    // hallucinates subtitle credits.
    let roomTone = (0..<16_000).map { i in Float(i % 7) * 0.0002 - 0.0006 }
    #expect(WhisperBackend.hasSpeech(roomTone) == false)
}

@Test func shortUtteranceInALongSilenceSurvives() {
    // Ten seconds of near-silence with half a second of speech in the middle.
    // Averaging the level would discard this; the windowed check must not.
    var samples = [Float](repeating: 0.0002, count: 160_000)
    for i in 80_000..<88_000 { samples[i] = 0.06 * sin(Float(i) * 0.05) }
    #expect(WhisperBackend.hasSpeech(samples) == true)
}

@Test func actualSpeechLevelPasses() {
    // A 0.05-amplitude tone stands in for quiet-but-real speech.
    let tone = (0..<16_000).map { i in 0.05 * sin(Float(i) * 0.05) }
    #expect(WhisperBackend.hasSpeech(tone) == true)
}

// MARK: - Locale resolution
//
// Regression cover for the ru-KZ case: a system language with no model must
// not silently resolve to some arbitrary regional variant.

@Test @MainActor func whisperResolvesRussianSystemLanguage() async {
    let supported = WhisperBackend.supportedLocales.map { $0.identifier(.bcp47) }
    #expect(supported.contains("ru"))
}

@Test @MainActor func whisperCoversFarMoreLanguagesThanApple() async {
    #expect(WhisperBackend.supportedLocales.count > 50)
}

@Test @MainActor func explicitLocaleChoiceWins() async {
    let previous = Settings.shared.localeIdentifier
    defer { Settings.shared.localeIdentifier = previous }

    Settings.shared.localeIdentifier = "ja"
    let resolved = await Backends.resolveLocale(for: .whisper)
    #expect(resolved.language.languageCode?.identifier == "ja")
}

@Test @MainActor func unsupportedChoiceFallsBackRatherThanFailing() async {
    let previous = Settings.shared.localeIdentifier
    defer { Settings.shared.localeIdentifier = previous }

    // Klingon is not on the menu.
    Settings.shared.localeIdentifier = "tlh-Piqd"
    let resolved = await Backends.resolveLocale(for: .whisper)
    #expect(!resolved.identifier(.bcp47).isEmpty)
}
