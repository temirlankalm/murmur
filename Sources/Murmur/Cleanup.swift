import Foundation
import FoundationModels

/// Turns a raw transcript into text you'd actually want pasted into a doc:
/// filler words gone, punctuation in, "new paragraph" honoured as a command.
protocol CleanupProvider {
    func clean(_ transcript: String, vocabulary: [String], context: DictationContext?) async throws -> String
    /// Apply a spoken instruction to text the user has selected.
    func rewrite(_ text: String, instruction: String) async throws -> String
}

enum Cleanup {
    static let instructions = """
    You are a dictation post-processor. You receive a raw speech-to-text \
    transcript and return the same message written cleanly.

    Rules:
    - Fix punctuation, capitalisation and obvious transcription errors.
    - Remove filler words (um, uh, like, you know) and false starts, keeping \
      the speaker's own wording everywhere else.
    - Obey spoken formatting commands: "new line", "new paragraph", \
      "comma", "period", "question mark", "bullet point".
    - Never answer, explain, summarise, translate or add content. If the \
      transcript is a question, return the question.
    - Return only the cleaned text. No preamble, no quotes, no markdown fence.
    """

    /// Assembled once so both providers send the model the same thing.
    static func prompt(for transcript: String, vocabulary: [String], context: DictationContext?) -> String {
        var parts: [String] = []
        if let context, let hint = context.kind.hint {
            parts.append("Where this is going: \(hint)")
        }
        if !vocabulary.isEmpty {
            parts.append("Spell these terms exactly if you hear them: \(vocabulary.joined(separator: ", ")).")
        }
        parts.append("Transcript:\n\(transcript)")
        return parts.joined(separator: "\n\n")
    }

    static let editInstructions = """
    You rewrite text according to an instruction. You receive the instruction     and the text it applies to, and you return the rewritten text.

    Rules:
    - Apply the instruction and change nothing else.
    - Keep the original language unless told to translate.
    - Never comment on the change, explain it, or ask questions.
    - Return only the rewritten text. No preamble, no quotes, no markdown fence.
    """

    static func editPrompt(text: String, instruction: String) -> String {
        "Instruction:\n\(instruction)\n\nText:\n\(text)"
    }

    static func provider(for mode: CleanupMode) -> CleanupProvider {
        switch mode {
        case .off:    return PassthroughCleanup()
        case .local:  return LocalCleanup()
        case .remote: return RemoteCleanup()
        }
    }

    /// Strip anything a model might wrap the answer in despite being told not to.
    static func sanitize(_ output: String, fallback: String, allowGrowth: Bool = false) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "^```[a-zA-Z]*\\n?", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\n?```$", with: "", options: .regularExpression)
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A model that "helpfully" answered instead of cleaning tends to
        // balloon. Better to paste the raw transcript than someone else's
        // essay. A deliberate rewrite ("expand this") may grow, so the cap
        // is lifted there.
        guard !text.isEmpty else { return fallback }
        guard allowGrowth || text.count < max(120, fallback.count * 3) else { return fallback }
        return text
    }
}

struct PassthroughCleanup: CleanupProvider {
    struct NoModel: LocalizedError {
        var errorDescription: String? { "Voice editing needs a cleanup model. Set one in Settings." }
    }

    func clean(_ transcript: String, vocabulary: [String], context: DictationContext?) async throws -> String {
        transcript
    }

    /// Nothing to rewrite with — say so rather than silently pasting the
    /// instruction over the user's selection.
    func rewrite(_ text: String, instruction: String) async throws -> String {
        throw NoModel()
    }
}

/// Apple's on-device model. Free, offline, no key.
struct LocalCleanup: CleanupProvider {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func clean(_ transcript: String, vocabulary: [String], context: DictationContext?) async throws -> String {
        guard Self.isAvailable else { return transcript }

        let prompt = Cleanup.prompt(for: transcript, vocabulary: vocabulary, context: context)
        let session = LanguageModelSession(instructions: Cleanup.instructions)
        let response = try await session.respond(to: prompt)
        return Cleanup.sanitize(response.content, fallback: transcript)
    }

    func rewrite(_ text: String, instruction: String) async throws -> String {
        guard Self.isAvailable else { throw PassthroughCleanup.NoModel() }
        let session = LanguageModelSession(instructions: Cleanup.editInstructions)
        let response = try await session.respond(to: Cleanup.editPrompt(text: text, instruction: instruction))
        return Cleanup.sanitize(response.content, fallback: text, allowGrowth: true)
    }
}

/// Any OpenAI-compatible chat endpoint: a local Ollama or LM Studio, or a
/// hosted one. The endpoint, the model and an optional key are all yours.
struct RemoteCleanup: CleanupProvider {
    static let keychainAccount = "remote-api-key"

    func clean(_ transcript: String, vocabulary: [String], context: DictationContext?) async throws -> String {
        let content = try await complete(
            system: Cleanup.instructions,
            user: Cleanup.prompt(for: transcript, vocabulary: vocabulary, context: context)
        )
        return Cleanup.sanitize(content, fallback: transcript)
    }

    private func complete(system: String, user: String) async throws -> String {
        let settings = Settings.shared
        guard let url = URL(string: settings.remoteBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw URLError(.badURL)
        }

        let body: [String: Any] = [
            "model": settings.remoteModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional on purpose: a local Ollama or LM Studio server wants no key,
        // and demanding one would rule out the whole self-hosted case.
        if let key = Keychain.get(Self.keychainAccount), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Murmur", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cleanup API rejected the request. \(detail.prefix(200))"
            ])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String else {
            throw NSError(domain: "Murmur", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The endpoint returned no message content."
            ])
        }
        return content
    }

    func rewrite(_ text: String, instruction: String) async throws -> String {
        let content = try await complete(
            system: Cleanup.editInstructions,
            user: Cleanup.editPrompt(text: text, instruction: instruction)
        )
        return Cleanup.sanitize(content, fallback: text, allowGrowth: true)
    }

    /// Ask the endpoint what it can actually run. Wrong model names are the
    /// most common misconfiguration, and the error they produce is unhelpful.
    func availableModels() async throws -> [String] {
        let base = Settings.shared.remoteBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let key = Keychain.get(Self.keychainAccount), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["data"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["id"] as? String }.sorted()
    }

    /// Round-trips a short phrase so a misconfigured endpoint shows up here
    /// rather than as a silently unchanged transcript later.
    func test(sample: String? = nil) async -> String {
        let sample = sample ?? "um so i was thinking we should uh ship this on friday"
        do {
            let result = try await clean(sample, vocabulary: [], context: nil)
            return result == sample
                ? "Reached it, but the text came back unchanged — check the model name."
                : "Working. “\(result)”"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}

/// Ready-made endpoints, including two that run entirely on your own machine.
///
/// Model names go stale — hosted providers retire them without warning, and a
/// dead name fails as an unhelpful 404. `--remote-models` asks an endpoint what
/// it currently serves. Prefer small, non-reasoning models here: cleanup sits
/// between releasing the key and the text appearing, so latency is the whole
/// game. On Groq the same sentence took 8.0s on gpt-oss-120b and 1.0s on
/// gpt-oss-20b, for identical output.
struct CleanupPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let needsKey: Bool
    let note: String

    static let all: [CleanupPreset] = [
        .init(id: "ollama", name: "Ollama (local)",
              baseURL: "http://localhost:11434/v1", model: "qwen3:1.7b",
              needsKey: false, note: "Runs on your Mac. Install Ollama, then: ollama pull qwen3:1.7b"),
        .init(id: "lmstudio", name: "LM Studio (local)",
              baseURL: "http://localhost:1234/v1", model: "qwen/qwen3-1.7b",
              needsKey: false, note: "Runs on your Mac. Load a model in LM Studio and start its server."),
        .init(id: "groq", name: "Groq",
              baseURL: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-20b",
              needsKey: true, note: "Hosted and fast, with a free tier."),
        .init(id: "openai", name: "OpenAI",
              baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
              needsKey: true, note: "Hosted, paid."),
        .init(id: "openrouter", name: "OpenRouter",
              baseURL: "https://openrouter.ai/api/v1", model: "google/gemini-2.0-flash-001",
              needsKey: true, note: "Hosted, many models behind one key."),
    ]
}
