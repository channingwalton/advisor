import SwiftUI

/// User-editable STT vocabulary, persisted to Application Support/Advisor/vocabulary.txt.
@MainActor
final class VocabularyStore: ObservableObject {
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

/// Simple wrapping layout for word chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Utterance text as tappable words: click a word to add it to the dictionary.
struct TappableWords: View {
    let text: String
    @ObservedObject var vocabulary: VocabularyStore

    var body: some View {
        FlowLayout {
            ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, raw in
                let word = String(raw)
                let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                let known = !cleaned.isEmpty && vocabulary.contains(cleaned)
                Text(word)
                    .underline(known, color: .accentColor)
                    .foregroundStyle(known ? Color.accentColor : .primary)
                    .onTapGesture {
                        guard !cleaned.isEmpty else { return }
                        known ? vocabulary.remove(cleaned) : vocabulary.add(cleaned)
                    }
                    .help(known ? "Remove “\(cleaned)” from dictionary" : "Add “\(cleaned)” to dictionary")
            }
        }
    }
}

/// Popover content for managing the dictionary.
struct DictionaryView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STT Dictionary").font(.headline)
            Text("Biases transcription towards these terms. Click words in the transcript to add them.")
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
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func addTerm() {
        vocabulary.add(newTerm)
        newTerm = ""
    }
}
