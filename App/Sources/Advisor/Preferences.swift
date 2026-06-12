import SwiftUI

/// Mirrors sidecar/src/config.ts — written to Application Support/Advisor/config.json.
/// The sidecar re-reads it at each session start.
struct AdvisorConfig: Codable, Equatable {
    struct Triggers: Codable, Equatable {
        var question = true
        var context = true
        var factcheck = true
    }

    var extraInstructions = ""
    var triggerSensitivity = "balanced"
    var triggers = Triggers()
    var maxTriggersPerPass = 2
    var classifierModel = "haiku"
    var researchModel = ""
    var allowMcpActions = false
    /// App-side only: STT locale identifier (e.g. en_GB).
    var sttLocale = "en_GB"

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

struct PreferencesView: View {
    @State private var config = AdvisorConfig.load()
    @AppStorage("sttEngine") private var sttEngine = STTEngine.apple.rawValue
    @AppStorage("agentLanes") private var agentLanes = 3
    @AppStorage("captureSystem") private var captureSystem = true

    var body: some View {
        Form {
            Section("Research agents") {
                Picker("Research model", selection: $config.researchModel) {
                    Text("Default (Sonnet)").tag("")
                    Text("Haiku — fast/cheap").tag("haiku")
                    Text("Opus — deepest").tag("opus")
                }
                Stepper("Parallel agents: \(agentLanes)", value: $agentLanes, in: 1...8)
                Toggle("Allow connector actions", isOn: $config.allowMcpActions)
                Text("Off: connectors (Slack, Jira, …) are read/search only. On: agents may also send, create, and update — use with care.")
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
                Picker("Classifier model", selection: $config.classifierModel) {
                    Text("Haiku — fast/cheap").tag("haiku")
                    Text("Sonnet — sharper").tag("sonnet")
                }
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
        .onChange(of: config) { _, new in new.save() }
    }
}
