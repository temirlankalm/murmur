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

// MARK: - Where the text is going

@Test func recognisesTerminalsAndEditors() {
    #expect(DictationContext.kind(forBundleID: "com.apple.Terminal") == .terminal)
    #expect(DictationContext.kind(forBundleID: "com.googlecode.iterm2") == .terminal)
    #expect(DictationContext.kind(forBundleID: "com.microsoft.VSCode") == .editor)
    #expect(DictationContext.kind(forBundleID: "com.apple.dt.Xcode") == .editor)
}

@Test func recognisesChatAndMail() {
    #expect(DictationContext.kind(forBundleID: "ru.keepcoder.Telegram") == .chat)
    #expect(DictationContext.kind(forBundleID: "com.anthropic.claudefordesktop") == .chat)
    #expect(DictationContext.kind(forBundleID: "com.apple.mail") == .mail)
}

@Test func unknownAppsGetNoStyleHint() {
    #expect(DictationContext.kind(forBundleID: "com.example.whatever") == .other)
    #expect(DictationContext.kind(forBundleID: nil) == .other)
    // No hint means the prompt stays as it was — nothing extra to mislead the model.
    #expect(DictationContext.Kind.other.hint == nil)
}

@Test func contextOnlyEntersThePromptWhenItSaysSomething() {
    let bare = Cleanup.prompt(for: "hello", vocabulary: [], context: nil)
    #expect(!bare.contains("Where this is going"))

    let terminal = DictationContext(appName: "Terminal", kind: .terminal)
    let shaped = Cleanup.prompt(for: "hello", vocabulary: [], context: terminal)
    #expect(shaped.contains("Where this is going"))
    #expect(shaped.contains("Transcript:"))

    // A browser has no useful style hint, so it must not pad the prompt.
    let browser = DictationContext(appName: "Safari", kind: .browser)
    #expect(!Cleanup.prompt(for: "hello", vocabulary: [], context: browser).contains("Where this is going"))
}

// MARK: - Voice editing

@Test func editPromptCarriesBothHalves() {
    let prompt = Cleanup.editPrompt(text: "ship it friday", instruction: "make this formal")
    #expect(prompt.contains("make this formal"))
    #expect(prompt.contains("ship it friday"))
    // The instruction must come first, or a long selection buries it.
    #expect(prompt.range(of: "Instruction:")!.lowerBound < prompt.range(of: "Text:")!.lowerBound)
}

@Test func aRewriteMayLegitimatelyGrow() {
    let short = "ship it"
    // No trailing space: sanitize trims, and the point here is the length cap.
    let expanded = Array(repeating: "We intend to ship this release.", count: 8).joined(separator: " ")
    // Cleanup rejects ballooning output, because that means the model answered
    // instead of rewriting. An explicit "expand this" must not be rejected.
    #expect(Cleanup.sanitize(expanded, fallback: short) == short)
    #expect(Cleanup.sanitize(expanded, fallback: short, allowGrowth: true) == expanded)
}

@Test func voiceEditingRefusesWithoutAModel() async {
    await #expect(throws: PassthroughCleanup.NoModel.self) {
        // Pasting the spoken instruction over the selection would destroy it,
        // so with no model configured this must fail loudly.
        try await PassthroughCleanup().rewrite("some text", instruction: "make it formal")
    }
}

// MARK: - Cleanup endpoints

@Test func localPresetsNeedNoKey() {
    let local = CleanupPreset.all.filter { !$0.needsKey }
    #expect(local.count >= 2)
    // The point of the local ones: no account, nothing leaves the machine.
    #expect(local.allSatisfy { $0.baseURL.contains("localhost") })
}

@Test func everyPresetIsAUsableEndpoint() {
    for preset in CleanupPreset.all {
        #expect(URL(string: preset.baseURL + "/chat/completions") != nil, "bad URL in \(preset.id)")
        #expect(!preset.model.isEmpty, "no model for \(preset.id)")
    }
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
