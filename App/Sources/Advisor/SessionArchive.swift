import Foundation

/// A saved session note on disk: the file and its start time, parsed from the
/// `yyyy-MM-dd-HHmmss.md` filename `SessionWriter` assigns.
struct SessionFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
}

/// Reads back the session notes `SessionWriter` saves, for browsing past
/// transcripts. Owns the on-disk location and filename convention (the live
/// writer delegates to it), so the format lives in one place.
enum SessionArchive {
    /// Where session notes are stored — `~/Library/Application Support/Advisor/sessions`.
    static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor/sessions", isDirectory: true)
    }

    /// `yyyy-MM-dd-HHmmss` with calendar/locale pinned, so a session filename is
    /// always Gregorian regardless of the user's system calendar. Used to both
    /// format new names and parse existing ones.
    static let fileNameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fmt.isLenient = false
        return fmt
    }()

    /// The note filename for a session that started at `date`.
    static func fileName(for date: Date) -> String {
        "\(fileNameFormatter.string(from: date)).md"
    }

    /// Parses a session note name (`yyyy-MM-dd-HHmmss.md`) to its start time.
    /// Nil for any name not in that exact, non-lenient Gregorian form.
    static func date(from filename: String) -> Date? {
        guard filename.hasSuffix(".md") else { return nil }
        return fileNameFormatter.date(from: String(filename.dropLast(3)))
    }

    /// Session notes in `directory`, newest first; non-session files are skipped.
    static func list(in directory: URL = SessionArchive.directory) -> [SessionFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .compactMap { url -> SessionFile? in
                date(from: url.lastPathComponent).map { SessionFile(url: url, date: $0) }
            }
            .sorted { $0.date > $1.date }
    }

    /// The note's raw markdown, or "" if it can't be read.
    static func contents(of file: SessionFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    /// The note body with any leading YAML frontmatter (`---` … `---`) removed,
    /// for display. Without this, markdown reads the `started:`/`ended:` lines
    /// closed by `---` as a setext heading and renders them huge. The session
    /// date is shown separately, so dropping the block loses nothing.
    static func strippingFrontmatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n") else { return markdown }
        let afterOpen = markdown.index(markdown.startIndex, offsetBy: 4)
        guard let close = markdown.range(of: "\n---\n", range: afterOpen..<markdown.endIndex)
        else { return markdown }
        return String(markdown[close.upperBound...].drop(while: { $0 == "\n" }))
    }

    /// `existing` with a follow-up Q&A appended under a single `# Follow-ups`
    /// heading (added the first time only). Pure, for testability.
    static func appendingFollowUp(
        to existing: String, question: String, answer: String, asked: Date
    ) -> String {
        var out = existing
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if out.range(of: "\n# Follow-ups") == nil && !out.hasPrefix("# Follow-ups") {
            out += "\n# Follow-ups\n"
        }
        out += "\n" + SessionMarkdown.followUpBlock(
            question: question, answer: answer, asked: asked) + "\n"
        return out
    }

    /// Append a follow-up Q&A to `file` on disk. Returns false if the write fails.
    @discardableResult
    static func appendFollowUp(
        question: String, answer: String, to file: SessionFile, asked: Date = Date()
    ) -> Bool {
        let updated = appendingFollowUp(
            to: contents(of: file), question: question, answer: answer, asked: asked)
        do {
            try updated.write(to: file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
