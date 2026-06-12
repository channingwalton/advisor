import SwiftUI

/// User-editable STT vocabulary, persisted to Application Support/Advisor/vocabulary.txt.
/// Shared so edits in Preferences reach the live recorder immediately.
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()
    @Published private(set) var terms: [String] = []
    private let fileURL: URL
    /// Called with the joined prompt text whenever the vocabulary changes.
    var onChange: ((String) -> Void)?

    /// Words the user taught macOS spellcheck — read-only, merged under manual terms.
    private let systemTerms: [String]
    /// Whisper's bias prompt is capped (~224 tokens); keep the term list well inside it.
    private let maxTerms = 120

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor", isDirectory: true)
        fileURL = dir.appendingPathComponent("vocabulary.txt")
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            terms = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        }
        let spelling = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Spelling/LocalDictionary")
        systemTerms = ((try? String(contentsOf: spelling, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Manual terms first, then system spelling words, deduped and capped.
    var joined: String {
        var seen = Set(terms.map { $0.lowercased() })
        var all = terms
        for t in systemTerms where !seen.contains(t.lowercased()) {
            seen.insert(t.lowercased())
            all.append(t)
        }
        return all.prefix(maxTerms).joined(separator: ", ")
    }

    func contains(_ term: String) -> Bool {
        terms.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    func add(_ term: String) {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !contains(cleaned) else { return }
        terms.append(cleaned)
        save()
    }

    func remove(_ term: String) {
        terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        save()
    }

    private func save() {
        try? terms.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        onChange?(joined)
    }
}

/// Dictionary management, embedded in Preferences → Transcription.
struct DictionaryView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Biases whisper transcription towards these terms (Apple speech has no vocabulary hook). Right-click a transcript sentence to add its words.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Add term…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vocabulary.terms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                vocabulary.remove(term)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func addTerm() {
        vocabulary.add(newTerm)
        newTerm = ""
    }
}
