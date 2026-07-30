import AppKit
import Speech
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
    /// App-side only: STT locale identifier (e.g. en_GB). "" = follow the
    /// device default locale (`Locale.current`), resolved in AppleSpeechEngine.
    var sttLocale = ""
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
    /// App-side only: an absolute path to the folder where session notes are
    /// stored (issue #16). "" = the built-in default
    /// (`Application Support/Advisor/sessions`). Only the app reads or writes
    /// session notes, so the sidecar never sees this — like `sttLocale`. Resolved
    /// through `SessionArchive.directory`.
    var sessionDir = ""
    /// App-side only: the TERMS.md version the user accepted at first run
    /// (`TermsAcceptance`). "" = not yet accepted. The sidecar never sees it.
    var acceptedTermsVersion = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case triggerSensitivity, triggers, allowMcpActions
        case provider, model, sttLocale, authMode, appearance, contexts, tags, sessionDir
        case acceptedTermsVersion
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
        sttLocale = try c.decodeIfPresent(String.self, forKey: .sttLocale) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode) ?? "subscription"
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        contexts = try c.decodeIfPresent([SavedContext].self, forKey: .contexts) ?? []
        tags = try c.decodeIfPresent([SavedTag].self, forKey: .tags) ?? []
        sessionDir = try c.decodeIfPresent(String.self, forKey: .sessionDir) ?? ""
        acceptedTermsVersion = try c.decodeIfPresent(String.self, forKey: .acceptedTermsVersion) ?? ""
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
        do {
            try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            // A non-atomic write could leave a corrupt file that `load()` then
            // silently resets to defaults; `.atomic` avoids that, and we surface
            // the failure rather than swallow it so a lost save is diagnosable.
            appLog.write("config save failed: \(error)")
        }
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
    /// Editable buffer used only while entering/replacing a key. `apiKey` holds
    /// only the persisted key and is never cleared just to enter edit mode.
    @State private var draft = ""
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

    /// The key the user is currently working with: the edit buffer while editing,
    /// otherwise the persisted key. Drives Test and the disabled state in both modes.
    private var candidateKey: String { editing ? draft : apiKey }

    private func reload() {
        apiKey = Keychain.read(keychainKey) ?? ""
        draft = ""
        editing = apiKey.isEmpty
        testState = .idle
    }

    /// Persist-on-submit: a non-empty entry becomes the stored key (the `apiKey`
    /// onChange writes the Keychain); an empty entry cancels without deleting.
    private func commit() {
        let entered = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else {
            // Empty submit = cancel: keep the existing key, exit edit mode only if
            // there was already a key (issue #53 — never delete on an empty field).
            editing = apiKey.isEmpty
            return
        }
        apiKey = entered   // the .onChange persists this non-empty value
        editing = false
        Task { await test() }
    }

    private func test() async {
        // Validate what a real session will use: the key read back from the
        // Keychain (issue #54). While editing, the draft isn't persisted yet,
        // so fall back to it.
        let key = editing ? draft : (Keychain.read(keychainKey) ?? "")
        guard !key.isEmpty else {
            testState = .failed("The key isn't saved in the Keychain.")
            alertMessage = "The \(providerLabel) API key couldn't be read back from your Keychain — try entering it again."
            return
        }
        testState = .testing
        let outcome = await AuthValidator.validate(provider: provider, key: key)
        // The field/keychain may have changed while the request was in flight;
        // ignore a stale result.
        let current = editing ? draft : (Keychain.read(keychainKey) ?? "")
        guard key == current else { return }
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
                .disabled(candidateKey.isEmpty)
        case .testing:
            ProgressView().controlSize(.small)
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Button("Retry") { Task { await test() } }
                .disabled(candidateKey.isEmpty)
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
                            SecureField("Paste your \(providerLabel) API key", text: $draft)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 280)
                                .onSubmit { commit() }
                            testControl
                        }
                    }
                } else {
                    LabeledContent("\(providerLabel) API key") {
                        HStack {
                            Text(redacted).foregroundStyle(.secondary)
                            testControl
                            Button("Change") { draft = ""; editing = true; testState = .idle }
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
            if Keychain.save(keychainKey, new) {
                testState = .idle
            } else {
                testState = .failed("Couldn't save the key to the Keychain.")
                alertMessage = "The \(providerLabel) API key couldn't be saved to your Keychain."
            }
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
                    SessionArchive.removeTagFromFolderDefaults(tag.name)
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

/// The preferences window: one tab per subject area (issue #22), replacing the
/// former single scrolling form. `config` and the persistence wiring live here
/// so a change made in any tab rides the same save + notification; each tab is a
/// thin `Form` over the relevant bindings.
struct PreferencesView: View {
    @State private var config = AdvisorConfig.load()
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("captureSystem") private var captureSystem = true

    var body: some View {
        TabView {
            AgentSettingsView(
                provider: $config.provider, model: $config.model,
                authMode: $config.authMode, allowMcpActions: $config.allowMcpActions,
                agentLanes: $agentLanes
            )
            .tabItem { Label("Agent", systemImage: "brain") }

            TriggersSettingsView(
                sensitivity: $config.triggerSensitivity, triggers: $config.triggers
            )
            .tabItem { Label("Triggers", systemImage: "bolt") }

            TranscriptionSettingsView(captureSystem: $captureSystem, sttLocale: $config.sttLocale)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            ContextsSettingsView(contexts: $config.contexts)
                .tabItem { Label("Contexts", systemImage: "text.book.closed") }

            TagsSettingsView(tags: $config.tags)
                .tabItem { Label("Tags", systemImage: "tag") }

            GeneralSettingsView(appearance: $config.appearance, sessionDir: $config.sessionDir)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 420)
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

/// Agent backend tab: provider/model picker, authentication, parallel-agent
/// count and the connector-actions toggle.
private struct AgentSettingsView: View {
    @Binding var provider: String
    @Binding var model: String
    @Binding var authMode: String
    @Binding var allowMcpActions: Bool
    @Binding var agentLanes: Int

    var body: some View {
        Form {
            Section("Agent backend") {
                AgentBackendView(provider: $provider, model: $model)
                AuthModeView(provider: provider, authMode: $authMode)
                Stepper("Parallel agents: \(agentLanes)", value: $agentLanes, in: 1...8)
                Toggle("Allow connector actions", isOn: $allowMcpActions)
                Text("Off: connectors (Slack, Jira, …) are read/search only. On: agents may also send, create, and update — use with care. Claude only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Agent settings apply at the start of the next session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Automatic-triggers tab: sensitivity plus the per-card-type toggles.
private struct TriggersSettingsView: View {
    @Binding var sensitivity: String
    @Binding var triggers: AdvisorConfig.Triggers

    var body: some View {
        Form {
            Section("Automatic triggers") {
                Picker("Sensitivity", selection: $sensitivity) {
                    Text("Conservative").tag("conservative")
                    Text("Balanced").tag("balanced")
                    Text("Eager").tag("eager")
                }
                .pickerStyle(.segmented)
                Toggle("Answer questions", isOn: $triggers.question)
                Toggle("Surface background context", isOn: $triggers.context)
                Toggle("Fact-check claims", isOn: $triggers.factcheck)
            }
        }
        .formStyle(.grouped)
    }
}

/// Transcription tab: system-audio capture and the speech locale.
private struct TranscriptionSettingsView: View {
    @Binding var captureSystem: Bool
    @Binding var sttLocale: String

    /// On-device locales the speech model supports, loaded asynchronously.
    @State private var locales: [Locale] = []

    var body: some View {
        Form {
            Section("Transcription") {
                Toggle("Capture system audio", isOn: $captureSystem)
                Picker("Locale", selection: $sttLocale) {
                    // "" sentinel = follow the device default (Locale.current).
                    Text("System default — \(Self.label(for: Locale.current))").tag("")
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Self.label(for: locale)).tag(locale.identifier)
                    }
                }
                .frame(maxWidth: 320)
                Text("Speech recognition language. Applies on next Listen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            locales = await SpeechTranscriber.supportedLocales
                .sorted { Self.label(for: $0) < Self.label(for: $1) }
        }
    }

    /// Human-readable language name, falling back to the raw identifier.
    private static func label(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// Saved-contexts tab — the reusable session-context library (issue #10).
private struct ContextsSettingsView: View {
    @Binding var contexts: [SavedContext]

    var body: some View {
        Form {
            Section("Saved contexts") {
                SavedContextsView(contexts: $contexts)
            }
        }
        .formStyle(.grouped)
    }
}

/// Tags tab — the session-tag library (issue #15).
private struct TagsSettingsView: View {
    @Binding var tags: [SavedTag]

    var body: some View {
        Form {
            Section("Tags") {
                SavedTagsView(tags: $tags)
            }
        }
        .formStyle(.grouped)
    }
}

/// General tab: window appearance and the session-storage folder (issue #16).
private struct GeneralSettingsView: View {
    @Binding var appearance: String
    @Binding var sessionDir: String

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Session storage") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(sessionFolderDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Change…") { chooseSessionFolder() }
                    }
                }
                Text("Where transcripts are saved. Changing the folder offers to move your existing transcripts across.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The resolved storage folder shown in Preferences — the chosen path or the
    /// built-in default when none is set.
    private var sessionFolderDisplay: String {
        SessionArchive.directory(for: sessionDir).path
    }

    /// Pick a new transcript folder (issue #16). When the current folder holds
    /// transcripts, offer to move them across (the live note, still owned by its
    /// writer, is left behind). Cancelling the move-prompt leaves the folder
    /// unchanged. Writing `sessionDir` fires the parent form's `onChange` →
    /// `save()` + `advisorConfigChanged`, which the Sessions browser reloads on.
    private func chooseSessionFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Session Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SessionArchive.directory(for: sessionDir)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        let oldDir = SessionArchive.directory(for: sessionDir)
        guard chosen.standardizedFileURL != oldDir.standardizedFileURL else { return }

        let live = TranscriptWindowContext.shared.liveFileURL
        let movable = SessionArchive.list(in: oldDir).filter {
            $0.url.standardizedFileURL != live?.standardizedFileURL
        }
        if !movable.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Move existing transcripts?"
            alert.informativeText =
                "Move \(movable.count) transcript\(movable.count == 1 ? "" : "s") to the new folder, "
                + "or leave them where they are?"
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Leave Them")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // A partial/failed move would split the archive across folders;
                // surface it rather than silently switching past it. On a total
                // failure (nothing moved) keep the old folder so no session is
                // hidden; on a partial move, report what stayed and still switch
                // (the bulk is now in the new folder, and the user is told).
                let result = SessionArchive.move(from: oldDir, to: chosen, excluding: live)
                if result.skipped > 0 {
                    reportIncompleteMove(result, to: chosen)
                    if result.moved == 0 { return }
                }
            case .alertSecondButtonReturn:
                break // keep the old transcripts where they are; just switch folder
            default:
                return // Cancel: leave the storage folder unchanged
            }
        }
        sessionDir = chosen.path
    }

    /// Tell the user a move didn't fully complete (a same-named note already in
    /// the destination, or a file error). `moved == 0` means nothing moved and
    /// the folder is being left unchanged; otherwise the skipped notes remain in
    /// the old folder while the rest moved across.
    private func reportIncompleteMove(_ result: (moved: Int, skipped: Int), to dest: URL) {
        let alert = NSAlert()
        if result.moved == 0 {
            alert.messageText = "Couldn't move transcripts"
            alert.informativeText =
                "None of the \(result.skipped) transcript\(result.skipped == 1 ? "" : "s") could be "
                + "moved — a note with the same name may already exist in the new folder, or the "
                + "move failed. The storage folder was left unchanged."
        } else {
            alert.messageText = "Some transcripts weren't moved"
            alert.informativeText =
                "\(result.moved) moved, but \(result.skipped) couldn't — a note with the same name "
                + "may already exist in the new folder, or the move failed. Those \(result.skipped) "
                + "stay in the old folder."
        }
        alert.runModal()
    }
}
