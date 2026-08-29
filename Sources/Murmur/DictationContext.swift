import AppKit

/// Where the text is about to land.
///
/// The same sentence wants different shaping in a terminal, a code review and
/// a message to a friend. Rather than guess from the words, tell the cleanup
/// model what it's writing into.
struct DictationContext {
    let appName: String
    let kind: Kind

    enum Kind: String {
        case terminal, editor, chat, mail, browser, notes, other

        /// Kept short and concrete. Long style briefs make the model rewrite
        /// far more than it was asked to.
        var hint: String? {
            switch self {
            case .terminal:
                return "A terminal. Plain text only — no markdown, no smart quotes, no trailing full stop on a command."
            case .editor:
                return "A code editor. Keep identifiers, paths and code verbatim; don't capitalise them."
            case .chat:
                return "A chat message. Keep it casual; no greeting or sign-off unless spoken."
            case .mail:
                return "An email. Sentence case and proper punctuation; don't invent a greeting or a sign-off."
            case .notes, .browser, .other:
                return nil
            }
        }
    }

    static func current() -> DictationContext {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "unknown"
        return DictationContext(appName: name, kind: kind(forBundleID: app?.bundleIdentifier))
    }

    /// Bundle identifiers, not names — names are localised and change.
    static func kind(forBundleID bundleID: String?) -> Kind {
        guard let id = bundleID?.lowercased() else { return .other }

        let table: [(match: String, kind: Kind)] = [
            ("com.apple.terminal", .terminal), ("iterm", .terminal),
            ("ghostty", .terminal), ("net.kovidgoyal.kitty", .terminal),
            ("dev.warp", .terminal), ("alacritty", .terminal),
            ("com.microsoft.vscode", .editor), ("com.apple.dt.xcode", .editor),
            ("jetbrains", .editor), ("com.sublimetext", .editor),
            ("dev.zed", .editor), ("com.todesktop", .editor),
            ("com.apple.mail", .mail), ("com.superhuman", .mail),
            ("com.readdle.smartemail", .mail),
            ("com.tinyspeck.slackmacgap", .chat), ("com.hnc.discord", .chat),
            ("ru.keepcoder.telegram", .chat), ("net.whatsapp", .chat),
            ("com.apple.messages", .chat), ("us.zoom", .chat),
            ("com.anthropic.claude", .chat), ("com.openai.chat", .chat),
            ("com.apple.safari", .browser), ("com.google.chrome", .browser),
            ("company.thebrowser", .browser), ("org.mozilla", .browser),
            ("com.apple.notes", .notes), ("md.obsidian", .notes),
            ("notion.id", .notes), ("com.apple.textedit", .notes),
        ]
        return table.first { id.contains($0.match) }?.kind ?? .other
    }
}
