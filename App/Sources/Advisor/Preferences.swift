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

    /// Editable persona/style block at the head of the research agents' system
    /// prompt. Mirrors sidecar default in prompts.ts; the protected operational
    /// core is not exposed here.
    static let defaultPersona = """
        You are Advisor, a realtime meeting assistant running on the user's Mac.
        Respond concisely and usefully for someone mid-conversation.
        British spelling. Keep answers under ~150 words unless asked for depth.
        """

    var personaPrompt = AdvisorConfig.defaultPersona
    var triggerSensitivity = "balanced"
    var triggers = Triggers()
    var maxTriggersPerPass = 2
    var allowMcpActions = false
    /// Agent backend shared by every lane (classifier, research, query). "" model
    /// = the provider's own default. Mirrors sidecar/src/config.ts.
    var provider = "claude"
    var model = ""
    /// App-side only: STT locale identifier (e.g. en_GB).
    var sttLocale = "en_GB"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case personaPrompt, triggerSensitivity, triggers, maxTriggersPerPass, allowMcpActions
        case provider, model, sttLocale
    }

    /// Tolerant decode: missing keys keep their default, unknown keys are
    /// ignored. No migration of older shapes — a stale config.json is just
    /// partially overridden. Without this custom init, a synthesised `Decodable`
    /// would throw on any missing key and the next save would wipe every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personaPrompt = try c.decodeIfPresent(String.self, forKey: .personaPrompt) ?? Self.defaultPersona
        triggerSensitivity = try c.decodeIfPresent(String.self, forKey: .triggerSensitivity) ?? "balanced"
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        maxTriggersPerPass = try c.decodeIfPresent(Int.self, forKey: .maxTriggersPerPass) ?? 2
        allowMcpActions = try c.decodeIfPresent(Bool.self, forKey: .allowMcpActions) ?? false
        sttLocale = try c.decodeIfPresent(String.self, forKey: .sttLocale) ?? "en_GB"
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
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

struct PreferencesView: View {
    @State private var config = AdvisorConfig.load()
    @AppStorage("sttEngine") private var sttEngine = STTEngine.apple.rawValue
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("captureSystem") private var captureSystem = true

    var body: some View {
        Form {
            Section("Agent backend") {
                AgentBackendView(provider: $config.provider, model: $config.model)
                Text("Shared by every lane — classifier, research, and manual query.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Codex uses your Codex CLI login and runs read-only (web + file reads, no writes). Its sandbox is coarser than Claude's — see DESIGN.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Parallel agents: \(agentLanes)", value: $agentLanes, in: 1...8)
                Toggle("Allow connector actions", isOn: $config.allowMcpActions)
                Text("Off: connectors (Slack, Jira, …) are read/search only. On: agents may also send, create, and update — use with care. Claude only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System prompt") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Persona & style")
                        Spacer()
                        Button("Restore default") {
                            config.personaPrompt = AdvisorConfig.defaultPersona
                        }
                        .controlSize(.small)
                        .disabled(config.personaPrompt == AdvisorConfig.defaultPersona)
                    }
                    TextEditor(text: $config.personaPrompt)
                        .font(.body)
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Text("Who the research agents are and how they write. The operational rules (fast two-pass answers, citations, no narration) are fixed and not shown here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                Stepper(
                    "Max triggers per pass: \(config.maxTriggersPerPass)",
                    value: $config.maxTriggersPerPass, in: 1...5)
            }

            Section("Transcription") {
                Picker("Engine", selection: $sttEngine) {
                    Text("Apple speech (recommended)").tag(STTEngine.apple.rawValue)
                    Text("Whisper").tag(STTEngine.whisper.rawValue)
                }
                Toggle("Capture system audio", isOn: $captureSystem)
                TextField("Locale", text: $config.sttLocale)
                    .frame(maxWidth: 160)
                Text("Apple speech locale, e.g. en_GB. Engine and locale apply on next Listen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DictionaryView(vocabulary: .shared)
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
