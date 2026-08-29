import Foundation

/// Running totals, so there's an answer to "is this actually saving me time?".
/// Counters only — no text is kept here; that's History's job, and it's optional.
@MainActor
final class Stats {
    static let shared = Stats()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let words = "statsWords"
        static let dictations = "statsDictations"
        static let seconds = "statsSeconds"
    }

    var words: Int { defaults.integer(forKey: Key.words) }
    var dictations: Int { defaults.integer(forKey: Key.dictations) }
    var seconds: Double { defaults.double(forKey: Key.seconds) }

    func record(text: String, duration: TimeInterval) {
        let count = text.split(whereSeparator: \.isWhitespace).count
        guard count > 0 else { return }
        defaults.set(words + count, forKey: Key.words)
        defaults.set(dictations + 1, forKey: Key.dictations)
        defaults.set(seconds + duration, forKey: Key.seconds)
    }

    func reset() {
        [Key.words, Key.dictations, Key.seconds].forEach { defaults.removeObject(forKey: $0) }
    }

    /// Words per minute while actually speaking.
    var wordsPerMinute: Int {
        guard seconds > 1 else { return 0 }
        return Int(Double(words) / (seconds / 60))
    }

    /// Against 40 wpm, a fair typing speed. Deliberately conservative — the
    /// number is meant to be believable, not flattering.
    var minutesSaved: Int {
        guard words > 0 else { return 0 }
        let typingMinutes = Double(words) / 40
        return max(0, Int(typingMinutes - seconds / 60))
    }

    var summary: String {
        guard dictations > 0 else { return "No dictations yet." }
        let plural = dictations == 1 ? "dictation" : "dictations"
        var line = "\(words.formatted()) words over \(dictations.formatted()) \(plural), \(wordsPerMinute) wpm"
        if minutesSaved > 0 { line += " · about \(minutesSaved) min saved vs typing" }
        return line
    }
}
