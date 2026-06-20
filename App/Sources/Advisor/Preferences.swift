import SwiftUI

extension Notification.Name {
    /// Posted when Preferences saves config.json, so live views (e.g. the
    /// right-click action menu) can reload without an app relaunch.
    static let advisorConfigChanged = Notification.Name("advisorConfigChanged")
    /// Posted when a session note is created or finalised, so the Sessions
    /// browser refreshes its list without being reopened.
    static let advisorSessionsChanged = Notification.Name("advisorSessionsChanged")
    /// Posted when a tag is renamed in Preferences (`userInfo` "from"/"to"), so
    /// the recording window can remap its staged/live `sessionTags` — the on-disk
    /// rename skips the live note to avoid the two-writer clobber, and a not-yet-
    /// started session's tags live only in that view state.
    static let advisorTagRenamed = Notification.Name("advisorTagRenamed")
    /// Posted when the Sessions browser changes the *live* note's tags
    /// (`userInfo` "tags": [String]), so the recording window updates its
    /// `sessionTags` and a later toolbar edit doesn't overwrite the change.
    static let advisorLiveTagsChanged = Notification.Name("advisorLiveTagsChanged")
}

/// Mirrors sidecar/src/config.ts — written to Application Support/Advisor/config.json.
/// The sidecar re-reads it at each session start.
struct AdvisorConfig: Codable, Equatable {
    struct Triggers: Codable, Equatable {
        var question = true
        var context = true
        var factcheck = true
    }

    var triggerSensitivity = "balanced"
    var triggers = Triggers()
    var allowMcpActions = false
    /// Agent backend shared by every lane (classifier, research, query). "" model
    /// = the provider's own default. Mirrors sidecar/src/config.ts.
    var provider = "claude"
    var model = ""
    /// App-side only: STT locale identifier (e.g. en_GB).
    var sttLocale = "en_GB"
    /// App-side only: "subscription" (the provider's CLI login, the default) or
    /// "apiKey" (talk to Anthropic/OpenAI directly with a key from the Keychain).
    /// The sidecar acts purely on the injected env var, so this is not mirrored in
    /// sidecar/src/config.ts — like sttLocale.
    var authMode = "subscription"
    /// App-side only: window appearance — "system" (default, follow macOS),
    /// "light" or "dark". Drives `NSApp.appearance`; not seen by the sidecar.
    var appearance = "system"
    /// App-side only: the user's library of named, reusable session contexts
    /// (issue #10). Loaded into the recording window's Context popover and
    /// managed in Preferences; the sidecar only ever receives the resolved
    /// context text per session, so it ignores this key.
    var contexts: [SavedContext] = []
    /// App-side only: the user's library of session tags (issue #15) — name +
    /// colour, managed in Preferences. Sessions reference tags by name in their
    /// note frontmatter; this library supplies the colour. The sidecar never
    /// sees it.
    var tags: [SavedTag] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case triggerSensitivity, triggers, allowMcpActions
        case provider, model, sttLocale, authMode, appearance, contexts, tags
    }

    /// Tolerant decode: missing keys keep their default, unknown keys are
    /// ignored. No migration of older shapes — a stale config.json is just
    /// partially overridden. Without this custom init, a synthesised `Decodable`
    /// would throw on any missing key and the next save would wipe every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggerSensitivity = try c.decodeIfPresent(String.self, forKey: .triggerSensitivity) ?? "balanced"
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        allowMcpActions = try c.decodeIfPresent(Bool.self, forKey: .allowMcpActions) ?? false
        sttLocale = try c.decodeIfPresent(String.self, forKey: .sttLocale) ?? "en_GB"
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode) ?? "subscription"
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        contexts = try c.decodeIfPresent([SavedContext].self, forKey: .contexts) ?? []
        tags = try c.decodeIfPresent([SavedTag].self, forKey: .tags) ?? []
    }

    static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor/config.json")
    }

    static func load() -> AdvisorConfig {
        guard let data = try? Data(contentsOf: fileURL),
            let config = try? JSONDecoder().decode(AdvisorConfig.self, from: data)
        else { return AdvisorConfig() }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.fileURL)
    }

    /// Persist only the saved-context library, leaving every other key as it is
    /// on disk. Used by the recording window's Context popover, which mustn't
    /// clobber preference settings it doesn't hold in view state.
    static func persistContexts(_ contexts: [SavedContext]) {
        var c = load()
        c.contexts = contexts
        c.save()
    }
}

/// One selectable agent backend for the UI — mirrors a sidecar providers.ts
/// entry. Adding a provider = one entry in `AgentProvider.all` (plus the
/// matching `create` in the sidecar registry).
struct AgentProvider: Identifiable {
    let id: String
    let label: String
    /// (tag, label) model options; tag "" = the provider's default.
    let models: [(String, String)]

    static let all: [AgentProvider] = [
        AgentProvider(
            id: "claude", label: "Claude",
            models: [
                ("", "Default (Sonnet)"), ("haiku", "Haiku — fast/cheap"),
                ("sonnet", "Sonnet — sharper"), ("opus", "Opus — deepest"),
            ]),
        // Codex's model is account/subscription-driven and set in
        // ~/.codex/config.toml; an explicit slug the ChatGPT plan doesn't
        // support is rejected (HTTP 400), so offer only the configured default.
        AgentProvider(
            id: "codex", label: "Codex",
            models: [("", "Default (from ~/.codex/config.toml)")]),
    ]
}

/// Provider + model picker for the single shared agent backend, driven entirely
/// by `AgentProvider.all`. Switching provider resets the model to that
/// provider's default (the scalar model can't carry a stale cross-provider id).
struct AgentBackendView: View {
    @Binding var provider: String
    @Binding var model: String

    private var models: [(String, String)] {
        AgentProvider.all.first { $0.id == provider }?.models ?? []
    }

    var body: some View {
        Picker("Provider", selection: $provider) {
            ForEach(AgentProvider.all) { Text($0.label).tag($0.id) }
        }
        .onChange(of: provider) { _, _ in model = "" }
        Picker("Model", selection: $model) {
            ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
        }
    }
}

/// Authentication picker for the active provider: subscription login (default)
/// or a direct API key. The key is held in the Keychain, not config.json; this
/// view loads/saves it and reloads when the provider changes (each provider has
/// its own Keychain item).
struct AuthModeView: View {
    let provider: String
    @Binding var authMode: String
    @State private var apiKey = ""
    /// True while entering/replacing a key. A stored key is shown redacted; the
    /// editable field appears only when there's no key yet or the user taps Change.
    @State private var editing = false

    /// Result of the most recent key test, shown inline; failures also raise an alert.
    private enum TestState: Equatable { case idle, testing, valid, failed(String) }
    @State private var testState: TestState = .idle
    @State private var alertMessage: String?

    private var keychainKey: Keychain.Key { provider == "codex" ? .openai : .anthropic }
    private var providerLabel: String { provider == "codex" ? "OpenAI" : "Anthropic" }
    private var loginLabel: String { provider == "codex" ? "Codex CLI login" : "Claude Code login" }

    /// First 5 + "…" + last 3 — enough to recognise the key without revealing it.
    /// Short strings (where that would expose most of the key) are fully masked.
    private var redacted: String {
        apiKey.count > 8 ? "\(apiKey.prefix(5))…\(apiKey.suffix(3))"
            : String(repeating: "•", count: apiKey.count)
    }

    private func reload() {
        apiKey = Keychain.read(keychainKey) ?? ""
        editing = apiKey.isEmpty
        testState = .idle
    }

    private func test() async {
        let key = apiKey
        testState = .testing
        let outcome = await AuthValidator.validate(provider: provider, key: key)
        // The field may have changed while the request was in flight; ignore a
        // stale result so the inline state always reflects the current key.
        guard key == apiKey else { return }
        switch outcome {
        case .valid:
            testState = .valid
        case .invalid:
            testState = .failed("\(providerLabel) rejected this API key.")
            alertMessage = "\(providerLabel) rejected this API key. Check it and try again."
        case .error(let detail):
            testState = .failed("Couldn't verify the key.")
            alertMessage = "Couldn't verify the \(providerLabel) API key: \(detail)"
        }
    }

    @ViewBuilder private var testControl: some View {
        switch testState {
        case .idle:
            Button("Test") { Task { await test() } }
                .disabled(apiKey.isEmpty)
        case .testing:
            ProgressView().controlSize(.small)
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Button("Retry") { Task { await test() } }
                .disabled(apiKey.isEmpty)
        }
    }

    var body: some View {
        Group {
            Picker("Authentication", selection: $authMode) {
                Text("Subscription (\(loginLabel))").tag("subscription")
                Text("API key").tag("apiKey")
            }
            if authMode == "apiKey" {
                if editing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(providerLabel) API key")
                        HStack {
                            TextField("Paste your \(providerLabel) API key", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 280)
                                .onSubmit {
                                    editing = apiKey.isEmpty
                                    if !apiKey.isEmpty { Task { await test() } }
                                }
                            testControl
                        }
                    }
                } else {
                    LabeledContent("\(providerLabel) API key") {
                        HStack {
                            Text(redacted).foregroundStyle(.secondary)
                            testControl
                            Button("Change") { apiKey = ""; editing = true; testState = .idle }
                        }
                    }
                }
                if case .failed(let summary) = testState {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                Text("Stored in your macOS Keychain, never in config.json. Talks to \(providerLabel) directly. Applies on the next session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { reload() }
        .onChange(of: provider) { _, _ in reload() }
        .onChange(of: apiKey) { _, new in
            Keychain.save(keychainKey, new)
            testState = .idle
        }
        .alert(
            "API key problem",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }
}

/// Manages the library of named, reusable session contexts (issue #10): a list
/// with add / edit / delete, editing through a sheet. Bound to
/// `config.contexts`, so every change rides the parent's save + notification.
struct SavedContextsView: View {
    @Binding var contexts: [SavedContext]
    /// The context being edited in the sheet (a draft copy); nil when closed.
    @State private var draft: SavedContext?

    var body: some View {
        if contexts.isEmpty {
            Text("No saved contexts yet. Add one to load it before a session.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(contexts) { ctx in
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.name).font(.system(size: 12.5, weight: .medium))
                    if !ctx.text.isEmpty {
                        Text(ctx.text).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Button { draft = ctx } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                Button(role: .destructive) {
                    contexts = ContextLibrary.removing(contexts, id: ctx.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
        }
        Button { draft = SavedContext(name: "", text: "") } label: {
            Label("Add context", systemImage: "plus")
        }
        .sheet(item: $draft) { editing in
            ContextEditorSheet(draft: editing) { saved in
                contexts = ContextLibrary.upserting(contexts, saved)
            }
        }
    }
}

/// Modal editor for a single saved context — name + multi-line text. Commits
/// through `onSave` (an id-based upsert), so it serves both add and edit.
private struct ContextEditorSheet: View {
    @State var draft: SavedContext
    let onSave: (SavedContext) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved context").font(.headline)
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Text("Who's here, what it's about, what to focus on.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.text)
                .font(.system(size: 12.5))
                .frame(width: 360, height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}

/// Manages the library of session tags (issue #15): a list with add / edit /
/// delete, editing through a sheet (name + colour). Bound to `config.tags`, so
/// every change rides the parent's save + notification, which the Sessions
/// browser listens for to recolour its pills. Deleting a tag here just stops it
/// rendering on session cards (the name may still sit in a note's frontmatter).
struct SavedTagsView: View {
    @Binding var tags: [SavedTag]
    /// The tag being edited in the sheet (a draft copy); nil when closed.
    @State private var draft: SavedTag?

    var body: some View {
        if tags.isEmpty {
            Text("No tags yet. Add one, then apply it to a session from its toolbar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(tags) { tag in
            HStack(spacing: 8) {
                TagPill(name: tag.name, colorHex: tag.colorHex)
                Spacer(minLength: 8)
                Button { draft = tag } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                Button(role: .destructive) {
                    tags = TagLibrary.removing(tags, id: tag.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
        }
        Button { draft = SavedTag(name: "", colorHex: Theme.tagSwatches[0]) } label: {
            Label("Add tag", systemImage: "plus")
        }
        .sheet(item: $draft) { editing in
            TagEditorSheet(
                draft: editing,
                siblingNames: tags.filter { $0.id != editing.id }.map(\.name)
            ) { saved in
                commit(saved)
            }
        }
    }

    /// Apply an add/edit. On a rename of an existing tag, propagate the new name
    /// into every note already tagged — sessions reference tags by name, so the
    /// library and the notes must move together. Saved notes are rewritten on
    /// disk here; the live note (if any) is renamed through its writer, driven by
    /// the `advisorTagRenamed` notification the recording window observes.
    private func commit(_ saved: SavedTag) {
        let oldName = tags.first { $0.id == saved.id }?.name
        let newName = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        tags = TagLibrary.upserting(tags, saved)
        // Propagate only a rename the library actually applied — not a colour-only
        // edit, a brand-new tag, or a name collision the upsert rejected (the
        // editor disables that, but never rewrite notes on a no-op).
        guard let oldName, oldName != newName,
            tags.contains(where: { $0.id == saved.id && $0.name == newName })
        else { return }
        let live = TranscriptWindowContext.shared.liveFileURL
        SessionArchive.renameTag(from: oldName, to: newName, excluding: live)
        // Always post: a recording window remaps the live note's tags (skipped on
        // disk above) and any tags staged before Listen. Harmless with no window.
        NotificationCenter.default.post(
            name: .advisorTagRenamed, object: nil,
            userInfo: ["from": oldName, "to": newName])
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }
}

/// Modal editor for a single tag — name + a colour swatch picker. Commits through
/// `onSave` (an id-based upsert), so it serves both add and edit; a rename is
/// propagated to existing notes by the caller. Save is disabled for a blank name
/// or one that collides (case-insensitively) with another tag.
private struct TagEditorSheet: View {
    @State var draft: SavedTag
    /// Names of the other tags, to block a duplicate name.
    let siblingNames: [String]
    let onSave: (SavedTag) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The set of swatches plus the draft's current colour (so an edit of a tag
    /// whose stored colour isn't a preset still shows its selection).
    private var swatches: [String] {
        Theme.tagSwatches.contains(draft.colorHex)
            ? Theme.tagSwatches : Theme.tagSwatches + [draft.colorHex]
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var collides: Bool {
        siblingNames.contains { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag").font(.headline)
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            if collides {
                Text("A tag with this name already exists.")
                    .font(.caption).foregroundStyle(Theme.factRed)
            }
            Text("Colour").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(swatches, id: \.self) { hex in
                    Button { draft.colorHex = hex } label: {
                        Circle().fill(Color(tagHex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().stroke(
                                    draft.colorHex == hex ? Theme.textStrong : .clear,
                                    lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                TagPill(
                    name: draft.name.isEmpty ? "tag" : draft.name, colorHex: draft.colorHex)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || collides)
            }
        }
        .padding(18)
        .frame(width: 320)
        // Suppress the system keyboard-focus ring on the colour swatch buttons.
        .focusEffectDisabled()
    }
}

struct PreferencesView: View {
    @State private var config = AdvisorConfig.load()
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("captureSystem") private var captureSystem = true

    var body: some View {
        Form {
            Section("Agent backend") {
                AgentBackendView(provider: $config.provider, model: $config.model)
                AuthModeView(provider: config.provider, authMode: $config.authMode)
                Stepper("Parallel agents: \(agentLanes)", value: $agentLanes, in: 1...8)
                Toggle("Allow connector actions", isOn: $config.allowMcpActions)
                Text("Off: connectors (Slack, Jira, …) are read/search only. On: agents may also send, create, and update — use with care. Claude only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Automatic triggers") {
                Picker("Sensitivity", selection: $config.triggerSensitivity) {
                    Text("Conservative").tag("conservative")
                    Text("Balanced").tag("balanced")
                    Text("Eager").tag("eager")
                }
                .pickerStyle(.segmented)
                Toggle("Answer questions", isOn: $config.triggers.question)
                Toggle("Surface background context", isOn: $config.triggers.context)
                Toggle("Fact-check claims", isOn: $config.triggers.factcheck)
            }

            Section("Saved contexts") {
                SavedContextsView(contexts: $config.contexts)
            }

            Section("Tags") {
                SavedTagsView(tags: $config.tags)
            }

            Section("Appearance") {
                Picker("Theme", selection: $config.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Transcription") {
                Toggle("Capture system audio", isOn: $captureSystem)
                TextField("Locale", text: $config.sttLocale)
                    .frame(maxWidth: 160)
                Text("Apple speech locale, e.g. en_GB. Locale applies on next Listen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Agent settings apply at the start of the next session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onChange(of: config) { _, new in
            new.save()
            NotificationCenter.default.post(name: .advisorConfigChanged, object: nil)
        }
        // Contexts can also be saved from the recording window's Context popover.
        // Pull any such on-disk change in so a later Preferences edit doesn't
        // write back a stale (context-less) config. Guarded on inequality so it
        // never reacts to this view's own posts (no save loop).
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            let disk = AdvisorConfig.load().contexts
            if disk != config.contexts { config.contexts = disk }
        }
    }
}
