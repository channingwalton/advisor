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

    /// Per-component agent backend: a provider id plus a remembered model per
    /// provider, so switching provider restores the previous choice. Mirrors
    /// sidecar/src/config.ts `ProviderChoice`.
    struct ProviderChoice: Codable, Equatable {
        var provider = "claude"
        var models: [String: String] = [:]

        init(provider: String = "claude", models: [String: String] = [:]) {
            self.provider = provider
            self.models = models
        }

        private enum CodingKeys: String, CodingKey { case provider, models }
        /// v2 named fields (pre models-map) — read on decode, never written.
        private enum LegacyKeys: String, CodingKey { case claudeModel, codexModel }

        /// Tolerant decode: keeps defaults for missing keys, and migrates the v2
        /// {claudeModel, codexModel} shape into the models map.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
            if let m = try c.decodeIfPresent([String: String].self, forKey: .models) {
                models = m
            } else {
                let legacy = try decoder.container(keyedBy: LegacyKeys.self)
                var m: [String: String] = [:]
                if let cm = try legacy.decodeIfPresent(String.self, forKey: .claudeModel), !cm.isEmpty {
                    m["claude"] = cm
                }
                if let xm = try legacy.decodeIfPresent(String.self, forKey: .codexModel), !xm.isEmpty {
                    m["codex"] = xm
                }
                models = m
            }
        }
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
    var extraInstructions = ""
    var triggerSensitivity = "balanced"
    var triggers = Triggers()
    var maxTriggersPerPass = 2
    var allowMcpActions = false
    var classifier = ProviderChoice(provider: "claude", models: ["claude": "haiku"])
    var research = ProviderChoice()
    var queryAgent = ProviderChoice()
    /// App-side only: STT locale identifier (e.g. en_GB).
    var sttLocale = "en_GB"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case personaPrompt, extraInstructions, triggerSensitivity, triggers, maxTriggersPerPass, allowMcpActions
        case classifier, research, queryAgent, sttLocale
    }

    /// Legacy flat fields (pre per-component provider) — read on decode, never written.
    private enum LegacyKeys: String, CodingKey {
        case classifierModel, researchModel
    }

    /// Tolerant decode: missing keys keep defaults, and legacy flat
    /// classifierModel/researchModel (v1) are migrated onto the nested choices —
    /// mirrors sidecar/src/config.ts `mergeConfig`. Without this, decoding an old
    /// config.json would throw and silently reset every saved setting. (The v2
    /// {claudeModel, codexModel} shape is migrated inside ProviderChoice.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personaPrompt = try c.decodeIfPresent(String.self, forKey: .personaPrompt) ?? Self.defaultPersona
        extraInstructions = try c.decodeIfPresent(String.self, forKey: .extraInstructions) ?? ""
        triggerSensitivity = try c.decodeIfPresent(String.self, forKey: .triggerSensitivity) ?? "balanced"
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        maxTriggersPerPass = try c.decodeIfPresent(Int.self, forKey: .maxTriggersPerPass) ?? 2
        allowMcpActions = try c.decodeIfPresent(Bool.self, forKey: .allowMcpActions) ?? false
        sttLocale = try c.decodeIfPresent(String.self, forKey: .sttLocale) ?? "en_GB"
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let legacyClassifier = try legacy.decodeIfPresent(String.self, forKey: .classifierModel)
        let legacyResearch = try legacy.decodeIfPresent(String.self, forKey: .researchModel)
        func claudeModels(_ id: String?, default def: String?) -> [String: String] {
            if let id, !id.isEmpty { return ["claude": id] }
            if let def { return ["claude": def] }
            return [:]
        }
        classifier = try c.decodeIfPresent(ProviderChoice.self, forKey: .classifier)
            ?? ProviderChoice(models: claudeModels(legacyClassifier, default: "haiku"))
        research = try c.decodeIfPresent(ProviderChoice.self, forKey: .research)
            ?? ProviderChoice(models: claudeModels(legacyResearch, default: nil))
        queryAgent = try c.decodeIfPresent(ProviderChoice.self, forKey: .queryAgent)
            ?? ProviderChoice(models: claudeModels(legacyResearch, default: nil))
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

/// Provider + provider-specific model picker for one pipeline component, driven
/// entirely by `AgentProvider.all`.
struct ProviderChoiceView: View {
    let title: String
    @Binding var choice: AdvisorConfig.ProviderChoice

    private var models: [(String, String)] {
        AgentProvider.all.first { $0.id == choice.provider }?.models ?? []
    }

    /// The remembered model for the current provider, defaulting to "".
    private var modelBinding: Binding<String> {
        Binding(
            get: { choice.models[choice.provider] ?? "" },
            set: { choice.models[choice.provider] = $0 })
    }

    var body: some View {
        Picker("\(title) provider", selection: $choice.provider) {
            ForEach(AgentProvider.all) { Text($0.label).tag($0.id) }
        }
        Picker("\(title) model", selection: modelBinding) {
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
            Section("Research agents") {
                ProviderChoiceView(title: "Research", choice: $config.research)
                ProviderChoiceView(title: "Manual query", choice: $config.queryAgent)
                Text("Codex uses your Codex CLI login and runs read-only (web + file reads, no writes). Its sandbox is coarser than Claude's — see DESIGN.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Parallel agents: \(agentLanes)", value: $agentLanes, in: 1...8)
                Toggle("Allow connector actions", isOn: $config.allowMcpActions)
                Text("Off: connectors (Slack, Jira, …) are read/search only. On: agents may also send, create, and update — use with care. Claude only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra instructions")
                    TextEditor(text: $config.extraInstructions)
                        .font(.body)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Text("Appended to the research agents' system prompt — tone, length, preferred sources, domain context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                ProviderChoiceView(title: "Classifier", choice: $config.classifier)
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
