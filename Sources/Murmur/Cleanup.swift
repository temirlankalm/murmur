import Foundation
import FoundationModels

/// Turns a raw transcript into text you'd actually want pasted into a doc:
/// filler words gone, punctuation in, "new paragraph" honoured as a command.
protocol CleanupProvider {
    func clean(_ transcript: String, vocabulary: [String]) async throws -> String
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

    static func provider(for mode: CleanupMode) -> CleanupProvider {
        switch mode {
        case .off:    return PassthroughCleanup()
        case .local:  return LocalCleanup()
        case .remote: return RemoteCleanup()
        }
    }

    /// Strip anything a model might wrap the answer in despite being told not to.
    static func sanitize(_ output: String, fallback: String) -> String {
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

        // A model that "helpfully" answered instead of cleaning tends to balloon.
        // Better to paste the raw transcript than someone else's essay.
        guard !text.isEmpty, text.count < max(120, fallback.count * 3) else { return fallback }
        return text
    }
}

struct PassthroughCleanup: CleanupProvider {
    func clean(_ transcript: String, vocabulary: [String]) async throws -> String { transcript }
}

/// Apple's on-device model. Free, offline, no key.
struct LocalCleanup: CleanupProvider {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func clean(_ transcript: String, vocabulary: [String]) async throws -> String {
        guard Self.isAvailable else { return transcript }

        var prompt = "Transcript:\n\(transcript)"
        if !vocabulary.isEmpty {
            prompt = "Spell these terms exactly if you hear them: \(vocabulary.joined(separator: ", ")).\n\n" + prompt
        }

        let session = LanguageModelSession(instructions: Cleanup.instructions)
        let response = try await session.respond(to: prompt)
        return Cleanup.sanitize(response.content, fallback: transcript)
    }
}

/// Any OpenAI-compatible chat endpoint — Groq, OpenAI, a local llama.cpp server.
struct RemoteCleanup: CleanupProvider {
    static let keychainAccount = "remote-api-key"

    struct MissingKey: LocalizedError {
        var errorDescription: String? { "No API key set for remote cleanup." }
    }

    func clean(_ transcript: String, vocabulary: [String]) async throws -> String {
        guard let key = Keychain.get(Self.keychainAccount), !key.isEmpty else { throw MissingKey() }

        let settings = Settings.shared
        guard let url = URL(string: settings.remoteBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw URLError(.badURL)
        }

        var user = "Transcript:\n\(transcript)"
        if !vocabulary.isEmpty {
            user = "Spell these terms exactly if you hear them: \(vocabulary.joined(separator: ", ")).\n\n" + user
        }

        let body: [String: Any] = [
            "model": settings.remoteModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": Cleanup.instructions],
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
        let content = message?["content"] as? String ?? transcript
        return Cleanup.sanitize(content, fallback: transcript)
    }
}
