import Foundation

struct Dictation: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let raw: String
    let cleaned: String
    let duration: TimeInterval
}

/// Last few dictations, so a botched paste isn't a lost thought.
/// Stored as plain JSON in Application Support — delete the file to wipe it.
@MainActor
final class History {
    static let shared = History()
    private(set) var entries: [Dictation] = []
    private let limit = 50

    private var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Dictation].self, from: data) {
            entries = decoded
        }
    }

    func add(_ entry: Dictation) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
