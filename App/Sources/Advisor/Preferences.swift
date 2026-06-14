import SwiftUI

extension Notification.Name {
    /// Posted when Preferences saves config.json, so live views (e.g. the
    /// right-click action menu) can reload without an app relaunch.
    static let advisorConfigChanged = Notification.Name("advisorConfigChanged")
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case triggerSensitivity, triggers, allowMcpActions
        case provider, model, sttLocale, authMode
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
    }
}
