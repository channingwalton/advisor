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
    /// How much the card lanes think (an Agent SDK effort level), or "" = the
    /// user's own Claude Code setting. Claude only; the classifier ignores it.
    /// Mirrors sidecar/src/config.ts, which drops an unknown level to "".
    var effort = ""
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
    /// Whether recognised utterance text is written to the log file
    /// (`~/Library/Logs/Advisor`), by the app and the sidecar. Off by default,
    /// so the log carries only diagnostics and the transcripts live only in the
    /// session folder (code review 2026-10-17). A debugging aid for echo dedup,
    /// disfluency cleanup and what the classifier was given. Applied to the
    /// recorder at once, mid-recording too; the sidecar reads it from
    /// config.json at launch and at each session_start, and gets a change in a
    /// `config` frame.
    var logTranscriptText = false
    /// The folders that the agents may read: absolute paths, or `~/…`.
    /// None by default, so an agent reads no local file until the user lists
    /// a folder (GHSA-6xc8-f55f-jxqr). Claude's file tools check it at each
    /// call, and the Claude CLI's Seatbelt profile takes it when the CLI
    /// starts (sidecar/src/claudeSandbox.ts); Codex's profile is written from
    /// it before each turn (sidecar/src/codexSandbox.ts). The sidecar refuses a folder at,
    /// under or above a credential store (`readableRoots` in
    /// sidecar/src/toolPolicy.ts). Mirrors sidecar/src/config.ts, which reads the
    /// file again at each file-tool call. Preferences → Files edits it in the
    /// file (`ReadableFolders`); `saveChanges` never writes it.
    var readableFolders: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case triggerSensitivity, triggers, allowMcpActions
        case provider, model, effort, sttLocale, authMode, appearance, contexts, tags, sessionDir
        case logTranscriptText, readableFolders
    }

    /// Tolerant decode: missing keys keep their default, unknown keys are
    /// ignored. No migration of older shapes — a stale config.json is just
    /// partially overridden. Without this custom init, a synthesised `Decodable`
    /// would throw on any missing key and the next save would wipe every setting.
    /// A key of the wrong type still fails the decode: a default in its place
    /// would reach the file at the next save (a bad entry would empty the whole
    /// context library). The Files tab reads its list without this decode
    /// (`ReadableFolders`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggerSensitivity = try c.decodeIfPresent(String.self, forKey: .triggerSensitivity) ?? "balanced"
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        allowMcpActions = try c.decodeIfPresent(Bool.self, forKey: .allowMcpActions) ?? false
        sttLocale = try c.decodeIfPresent(String.self, forKey: .sttLocale) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        // An unknown level falls back to Default, as the sidecar does, so the
        // picker never shows a blank selection for a level that isn't running.
        let rawEffort = try c.decodeIfPresent(String.self, forKey: .effort) ?? ""
        effort = AgentEffort.levels.contains { $0.0 == rawEffort } ? rawEffort : ""
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode) ?? "subscription"
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        contexts = try c.decodeIfPresent([SavedContext].self, forKey: .contexts) ?? []
        tags = try c.decodeIfPresent([SavedTag].self, forKey: .tags) ?? []
        sessionDir = try c.decodeIfPresent(String.self, forKey: .sessionDir) ?? ""
        logTranscriptText = try c.decodeIfPresent(Bool.self, forKey: .logTranscriptText) ?? false
        // Strings only, as the sidecar keeps them. A value that is not a list
        // gives no folders, rather than a failed decode that the next save
        // turns into a reset of every setting.
        readableFolders = (try? c.decodeIfPresent([LossyString].self, forKey: .readableFolders))?
            .compactMap(\.value) ?? []
    }

    /// A list entry that is kept only when it is a string.
    private struct LossyString: Decodable {
        let value: String?
        init(from decoder: Decoder) {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor/config.json")
    }

    static func load(from url: URL = fileURL) -> AdvisorConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(AdvisorConfig.self, from: data)
        else { return AdvisorConfig() }
        return config
    }

    /// Write this config to `url`; false when the write failed.
    @discardableResult
    func save(to url: URL = AdvisorConfig.fileURL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            // A non-atomic write could leave a corrupt file that `load()` then
            // silently resets to defaults; `.atomic` avoids that, and we surface
            // the failure rather than swallow it so a lost save is diagnosable.
            appLog.write("config save failed: \(error)")
            return false
        }
    }

    /// The config file as the app's decode sees it.
    enum FileState {
        case missing
        /// It exists, but cannot be read or does not decode: its settings are
        /// unknown.
        case unusable
        case decoded(AdvisorConfig)
    }

    /// A file that the sidecar reads in another way counts as one that
    /// cannot be used (`ConfigFile.readsAsTheSidecar`).
    static func fileState(at url: URL = fileURL) -> FileState {
        switch ConfigFile.read(at: url) {
        case .missing: return .missing
        case .unusable: return .unusable
        case .object(_, let data):
            guard let config = try? JSONDecoder().decode(AdvisorConfig.self, from: data) else { return .unusable }
            return .decoded(config)
        }
    }

    /// The window's save: the settings in which this copy differs from
    /// `base`, the copy as the window last read or wrote the file. Every
    /// other key stays as the file holds it, so a copy that is older than the
    /// file writes no setting that the user did not change (code review
    /// 2026-11-10). A key is the unit: a change to one context, tag or
    /// trigger writes the window's whole `contexts`, `tags` or `triggers`. The readable folders are never written: the Files tab
    /// edits them in the file (`ReadableFolders`). With no change, nothing is
    /// written. False when nothing was saved, so the window can say so.
    @discardableResult
    func saveChanges(from base: AdvisorConfig, to url: URL = AdvisorConfig.fileURL) -> Bool {
        guard let mine = encoded(), let theirs = base.encoded() else { return false }
        let keys = Self.changedKeys(mine, from: theirs)
        if keys.isEmpty { return true }
        return write(keys: keys, to: url)
    }

    /// `target` with this config's values for the settings in which this
    /// config differs from `base`, as `saveChanges` finds them: the changes
    /// that the Preferences window could not write, over a newer file. Nil
    /// when the encode or the decode fails.
    func applyingChanges(from base: AdvisorConfig, to target: AdvisorConfig) -> AdvisorConfig? {
        guard let mine = encoded(), let theirs = base.encoded(), var json = target.encoded() else { return nil }
        for key in Self.changedKeys(mine, from: theirs) { json[key] = mine[key] }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(AdvisorConfig.self, from: data)
    }

    /// The keys whose values differ, the readable folders excepted: the window
    /// has no control for them, and the Files tab edits them in the file.
    private static func changedKeys(_ mine: [String: Any], from theirs: [String: Any]) -> Set<String> {
        Set(mine.keys.filter { key in
            key != CodingKeys.readableFolders.stringValue && !sameJSON(mine[key], theirs[key])
        })
    }

    /// The recording window's **Save…**: `text` as the context `name` in the
    /// library that the file holds now (`ContextLibrary.saving`), not in the
    /// window's copy, which can be older (code review 2026-11-10). Only
    /// `contexts` is written. The new library, or nil when nothing was saved.
    static func saveContext(named name: String, text: String, at url: URL = fileURL) -> [SavedContext]? {
        var c = AdvisorConfig()
        switch fileState(at: url) {
        case .missing: break
        case .unusable:
            appLog.write("context not saved: config.json cannot be read or does not decode")
            return nil
        case .decoded(let disk): c.contexts = disk.contexts
        }
        c.contexts = ContextLibrary.saving(c.contexts, name: name, text: text)
        return c.write(keys: [CodingKeys.contexts.stringValue], to: url) ? c.contexts : nil
    }

    /// Write the values of `keys` from this config into the file at `url`. A
    /// file that cannot be read or does not decode is left as it is: the
    /// window then holds the defaults or an older copy, not the file's
    /// settings, and the user corrects the file first.
    private func write(keys: Set<String>, to url: URL) -> Bool {
        var json: [String: Any] = [:]
        switch ConfigFile.read(at: url) {
        case .missing: break
        case .object(let disk, let data) where (try? JSONDecoder().decode(AdvisorConfig.self, from: data)) != nil:
            json = disk
        default:
            appLog.write("config not saved: config.json cannot be read or does not decode")
            return false
        }
        // No write without every value: a key without one would be deleted.
        guard let values = encoded(), keys.allSatisfy({ values[$0] != nil }) else { return false }
        for key in keys { json[key] = values[key] }
        return ConfigFile.write(json, to: url)
    }

    /// This config as a JSON object, as `save(to:)` writes it; nil when the
    /// encode fails.
    private func encoded() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            appLog.write("config encode failed")
            return nil
        }
        return json
    }

    /// Two JSON values as the same text, which keeps `1` and `true` apart.
    private static func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let text = { (v: Any) in try? JSONSerialization.data(withJSONObject: [v], options: [.sortedKeys]) }
        return text(a) != nil && text(a) == text(b)
    }

    /// The file's settings, for a view that reloads on `advisorConfigChanged`:
    /// the defaults when there is no file, nil when it cannot be read or does
    /// not decode. The view then keeps what it shows: the defaults would
    /// reset the appearance, the triggers and the libraries, and the Files
    /// tab posts the notice for such a file (code review 2026-11-10).
    static func loadIfUsable(from url: URL = fileURL) -> AdvisorConfig? {
        switch fileState(at: url) {
        case .missing: AdvisorConfig()
        case .unusable: nil
        case .decoded(let config): config
        }
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

/// Effort levels offered in Preferences: (tag, label), tag "" = the user's own
/// Claude Code setting. The CLI lowers a level the model can't use (xhigh →
/// high on Sonnet; Haiku ignores effort), so every level is safe to offer.
enum AgentEffort {
    static let levels: [(String, String)] = [
        ("", "Default (your Claude Code setting)"),
        ("low", "Low — fastest"), ("medium", "Medium"), ("high", "High"),
        ("xhigh", "Extra high"), ("max", "Max — slowest"),
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
        Picker("Provider", selection: Self.picked(provider: $provider, clearing: $model)) {
            ForEach(AgentProvider.all) { Text($0.label).tag($0.id) }
        }
        Picker("Model", selection: $model) {
            ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    /// The provider picker's selection: a provider that the user picks clears
    /// the model, which belongs to the old provider. A provider set from the
    /// file, by a reload of the Preferences window, keeps the file's model,
    /// so a reload writes nothing (code review 2026-11-10). An `onChange` of
    /// the provider ran for both.
    static func picked(provider: Binding<String>, clearing model: Binding<String>) -> Binding<String> {
        Binding(
            get: { provider.wrappedValue },
            set: { new in
                guard new != provider.wrappedValue else { return }
                provider.wrappedValue = new
                model.wrappedValue = ""
            })
    }
}

/// Authentication picker for the active provider: subscription login (default)
/// or a direct API key. The key is held in the Keychain, not config.json; this
/// view loads/saves it and reloads when the provider changes (each provider has
/// its own Keychain item).
struct AuthModeView: View {
    let provider: String
    @Binding var authMode: String
    /// The mode is in config.json, which cannot be used; the key is in the
    /// Keychain and stays editable.
    var modeLocked = false
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
            .disabled(modeLocked)
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

/// A "Load" menu listing the saved contexts; picking one hands it to `onPick`.
/// Shared by the recording window's Context popover and a folder's context
/// popover, so both choose from the same library the same way.
struct SavedContextMenu: View {
    let contexts: [SavedContext]
    let onPick: (SavedContext) -> Void

    var body: some View {
        Menu {
            ForEach(contexts) { c in
                Button(c.name) { onPick(c) }
            }
        } label: {
            Label("Load", systemImage: "tray.and.arrow.down")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .focusEffectDisabled()
        .disabled(contexts.isEmpty)
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
                    .font(.caption).foregroundStyle(Theme.failureRed)
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

/// The Preferences window's link to config.json, apart from the view so that
/// tests can drive it. A change writes only the settings that differ from
/// `saved`, the copy as the window last read or wrote the file
/// (`AdvisorConfig.saveChanges`). So a window copy that is older than the file
/// writes nothing that the user did not change (code review 2026-11-10).
/// Opening the window or a reload writes only a change that the window could
/// not write before (code review 2026-11-11).
struct PreferencesFile {
    let url: URL
    /// The settings as the window last read or wrote them.
    private(set) var saved = AdvisorConfig()
    /// The file cannot be read or does not decode, so the window's copy is
    /// not the file's: the defaults, or an older copy. The window takes no
    /// edits until a reload finds a file that it can use. The Files tab edits
    /// its list in the raw file, so it stays usable.
    private(set) var unusable = false
    /// The window shows a change that the file does not hold, because its
    /// write failed. The next change, or a reload, writes it again.
    private(set) var notSaved = false

    init(url: URL = AdvisorConfig.fileURL) {
        self.url = url
        _ = reload(keeping: saved)
    }

    /// The file's settings now, for the window to show: the defaults when
    /// there is no file. `shown` is what the window shows: each setting in
    /// which it differs from `saved` is a change that could not be written,
    /// and it keeps the window's value over the file's, so that the next
    /// `commit` writes it again. Before, a reload showed the file's value, and
    /// the change was lost (code review 2026-11-11). Nil when the file cannot
    /// be used: the window keeps what it shows.
    mutating func reload(keeping shown: AdvisorConfig) -> AdvisorConfig? {
        guard let disk = AdvisorConfig.loadIfUsable(from: url) else {
            unusable = true
            return nil
        }
        unusable = false
        if shown == saved {
            saved = disk
            return disk
        }
        // The encode cannot fail for this type. If it did, the window keeps
        // what it shows and the `saved` that goes with it, so that its next
        // change writes only the window's changes, not its older copy of the
        // other settings.
        guard let kept = shown.applyingChanges(from: saved, to: disk) else {
            notSaved = true
            return nil
        }
        saved = disk
        return kept
    }

    /// Save `shown`, the window's copy after a change or a reload. True when
    /// the file now holds the change, so the window posts
    /// `advisorConfigChanged`. False when there is no change or nothing was
    /// saved.
    mutating func commit(_ shown: AdvisorConfig) -> Bool {
        if shown == saved {
            // Nothing to write: the change that failed was undone, or the
            // file holds it.
            notSaved = false
            return false
        }
        if !unusable, shown.saveChanges(from: saved, to: url) {
            saved = shown
            notSaved = false
            return true
        }
        // The window keeps the change, and a reload keeps it over the file.
        notSaved = true
        if case .unusable = AdvisorConfig.fileState(at: url) { unusable = true }
        return false
    }
}

/// The preferences window: one tab per subject area (issue #22), replacing the
/// former single scrolling form. `config` and the persistence wiring live here
/// so a change made in any tab rides the same save + notification; each tab is a
/// thin `Form` over the relevant bindings.
struct PreferencesView: View {
    @State private var file: PreferencesFile
    @State private var config: AdvisorConfig
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("captureSystem") private var captureSystem = true

    init() {
        let file = PreferencesFile()
        _file = State(initialValue: file)
        _config = State(initialValue: file.saved)
    }

    var body: some View {
        TabView {
            AgentSettingsView(
                provider: $config.provider, model: $config.model, effort: $config.effort,
                authMode: $config.authMode, allowMcpActions: $config.allowMcpActions,
                agentLanes: $agentLanes, locked: file.unusable
            )
            .tabItem { Label("Agent", systemImage: "brain") }

            FilesSettingsView()
                .tabItem { Label("Files", systemImage: "folder") }

            TriggersSettingsView(
                sensitivity: $config.triggerSensitivity, triggers: $config.triggers
            )
            .disabled(file.unusable)
            .tabItem { Label("Triggers", systemImage: "bolt") }

            TranscriptionSettingsView(
                captureSystem: $captureSystem, sttLocale: $config.sttLocale, locked: file.unusable)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            ContextsSettingsView(contexts: $config.contexts)
                .disabled(file.unusable)
                .tabItem { Label("Contexts", systemImage: "text.book.closed") }

            TagsSettingsView(tags: $config.tags)
                .disabled(file.unusable)
                .tabItem { Label("Tags", systemImage: "tag") }

            GeneralSettingsView(
                appearance: $config.appearance, sessionDir: $config.sessionDir,
                logTranscriptText: $config.logTranscriptText)
                .disabled(file.unusable)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom) {
            if file.unusable {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(file.notSaved
                        ? "config.json cannot be read, or holds a value that Advisor cannot use, so your last change is not saved. The settings below can differ from the file and cannot be changed. Correct or delete the file, then reload to save your change."
                        : "config.json cannot be read, or holds a value that Advisor cannot use. The settings from it below can differ from the file and cannot be changed. Correct or delete the file, then reload.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Reload") {
                        reloadFromFile()
                        // The Files tab and the other windows kept what they
                        // showed while the file could not be used.
                        NotificationCenter.default.post(name: .advisorConfigChanged, object: nil)
                    }
                    .focusEffectDisabled()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            } else if file.notSaved {
                Text("Advisor could not write config.json, so your last change is not saved. Advisor tries again at your next change.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 480, height: 420)
        .onAppear(perform: reloadFromFile)
        .onChange(of: config) { _, new in
            if file.commit(new) {
                NotificationCenter.default.post(name: .advisorConfigChanged, object: nil)
            }
        }
        // Another writer: a context saved from the recording window, a
        // Files-tab edit, or this window's own save.
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            reloadFromFile()
        }
    }

    /// Show the file's settings, with each change that the window could not
    /// write kept over them, and write those changes again. With every change
    /// in the file, this writes nothing.
    private func reloadFromFile() {
        guard let shown = file.reload(keeping: config) else { return }
        if shown != config {
            config = shown // `onChange` commits it
        } else if file.commit(shown) {
            NotificationCenter.default.post(name: .advisorConfigChanged, object: nil)
        }
    }
}

/// Agent backend tab: provider/model picker, authentication, parallel-agent
/// count and the connector-actions toggle.
private struct AgentSettingsView: View {
    @Binding var provider: String
    @Binding var model: String
    @Binding var effort: String
    @Binding var authMode: String
    @Binding var allowMcpActions: Bool
    @Binding var agentLanes: Int
    /// config.json cannot be used, so its settings take no edits. The lane
    /// count (UserDefaults) and the API key (Keychain) stay editable.
    let locked: Bool

    var body: some View {
        Form {
            Section("Agent backend") {
                AgentBackendView(provider: $provider, model: $model)
                    .disabled(locked)
                Picker("Effort", selection: $effort) {
                    ForEach(AgentEffort.levels, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(locked)
                Text("How much Claude thinks before answering a card. Lower is faster; a level the model can't use is lowered to one it can. Claude only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AuthModeView(provider: provider, authMode: $authMode, modeLocked: locked)
                Stepper("Parallel agents: \(agentLanes)", value: $agentLanes, in: 1...8)
                Toggle("Allow connector actions", isOn: $allowMcpActions)
                    .disabled(locked)
                Text("Off: connectors (Slack, Jira, …) are read/search only; Codex, which can't tell the two apart, gets no connectors. On: agents may also send, create, and update — use with care.")
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

/// Files tab: the folders that the Claude agents may read (GHSA-6xc8-f55f-jxqr).
/// Its edits go to the file through `ReadableFolders`, which reads the file's
/// list at each edit; the window's own copy of the config never writes it.
struct FilesSettingsView: View {
    /// The config file; a test can give a file of its own.
    var configURL = AdvisorConfig.fileURL
    @State private var folders: [String] = []
    /// Set when the file cannot be read or does not decode: the list is unknown.
    @State private var unusable = false
    /// Set when the last edit could not be written.
    @State private var notSaved = false

    var body: some View {
        Form {
            Section("Readable folders") {
                if unusable {
                    Text("config.json cannot be read, is not valid JSON, or is JSON that Advisor and its agents could read in different ways. Correct the file to change this list.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if folders.isEmpty {
                    Text("No folders yet, so agents read no local files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if notSaved {
                    Text("Advisor could not write config.json, so the list below is the one that the file still holds.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // By position: a hand-edited list can hold the same entry twice.
                ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                    HStack(spacing: 8) {
                        Text(ReadableFolders.display(folder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder)
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            show(ReadableFolders.remove(folder, at: configURL))
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .focusEffectDisabled()
                            .help("Remove")
                    }
                }
                Button { addFolders() } label: { Label("Add folder…", systemImage: "plus") }
                    .focusEffectDisabled()
                    .disabled(unusable)
                Text("Agents can read the files in these folders, but cannot change them. A credential folder such as ~/.ssh is not used, and nor is a folder inside one or a folder that holds one, such as ~ or ~/Library. A folder beside them, such as ~/Library/Mobile Documents (iCloud Drive), is used. A folder outside your home folder is not used. Claude's own file tools refuse a removed folder at once. Other changes apply from the next card, or when a busy agent is idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        // A save from this app. Nothing watches the file, so a hand edit shows
        // when the tab appears again; an edit reads the file first in any case.
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in reload() }
    }

    /// The file's list now. It replaces any notice of a failed write: the list
    /// shown is then the one that the file holds.
    private func reload() {
        let loaded = ReadableFolders.load(from: configURL)
        unusable = loaded == nil
        notSaved = false
        folders = loaded ?? []
    }

    private func show(_ outcome: ReadableFolders.Outcome) {
        switch outcome {
        case .unusable:
            unusable = true
            notSaved = false
            folders = []
        case .notSaved(let onDisk):
            unusable = false
            notSaved = true
            folders = onDisk
        case .saved(let new):
            unusable = false
            notSaved = false
            folders = new
            NotificationCenter.default.post(name: .advisorConfigChanged, object: nil)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add Readable Folders"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        show(ReadableFolders.add(panel.urls.map(\.path), at: configURL))
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
    /// config.json cannot be used: the locale takes no edits. System-audio
    /// capture is in UserDefaults and stays editable.
    let locked: Bool

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
                .disabled(locked)
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

/// General tab: window appearance, the session-storage folder (issue #16) and
/// the transcript-logging switch.
private struct GeneralSettingsView: View {
    @Binding var appearance: String
    @Binding var sessionDir: String
    @Binding var logTranscriptText: Bool

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

            Section("Logging") {
                Toggle("Include transcript text in the log", isOn: $logTranscriptText)
                Text("For debugging transcription. When on, the text of recognised and echo-suppressed lines is also written to the log file (~/Library/Logs/Advisor). Applies at once. Card text and the classifier's triggers are logged either way.")
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
    /// unchanged. The same folder by another path, through a symlink, has
    /// nothing to move, so the path switches with no prompt (issue #114).
    /// Writing `sessionDir` fires the parent form's `onChange` →
    /// `PreferencesFile.commit`, which posts `advisorConfigChanged` after a
    /// save; the Sessions browser reloads on it.
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
        let movable = SessionArchive.notesToMove(from: oldDir, to: chosen, excluding: live)
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
