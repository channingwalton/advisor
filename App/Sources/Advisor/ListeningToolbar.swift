import SwiftUI

/// The Listening view's control strip (60 pt). Left: record cluster (waveform +
/// timer + pause/stop) and audio-source button. Right: Focus chip, Auto-cards
/// toggle, Float, Sessions. Idle collapses the cluster to a single Listen pill.
struct ListeningToolbar: View {
    @ObservedObject var store: TranscriptStore
    let sessionStart: Date?
    /// When paused, the moment capture paused — freezes the timer display.
    let pausedAt: Date?
    @Binding var selectedDevice: InputDevice?
    let devices: [InputDevice]
    let captureSystem: Bool
    @Binding var sessionName: String
    @Binding var sessionContext: String
    @Binding var autoCards: Bool
    @Binding var pinned: Bool
    let onPlay: () -> Void
    let onPauseResume: () -> Void
    let onMuteToggle: () -> Void
    let onStop: () -> Void
    let onHistory: () -> Void
    let onSessions: () -> Void
    /// Whether the current session has anything to export (gates the button).
    let canExport: Bool
    let onExport: () -> Void

    @State private var showFocus = false
    @State private var showName = false

    var body: some View {
        HStack(spacing: 12) {
            if store.listening {
                recordCluster
            } else {
                listenButton
            }
            audioSourceButton
            Spacer(minLength: 8)
            nameChip
            focusChip
            autoCardsToggle
            floatButton
            exportButton
            historyButton
            sessionsButton
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.toolbarHeight)
        .background(Theme.surfaceTitlebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        // Suppress the system keyboard-focus ring on the toolbar's custom controls.
        .focusEffectDisabled()
    }

    // MARK: record cluster

    private var listenButton: some View {
        Button(action: onPlay) {
            HStack(spacing: 7) {
                Circle().fill(Theme.recordRed).frame(width: 9, height: 9)
                Text("Listen").font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textBody)
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Theme.surfaceControl, in: Capsule())
            .overlay(Capsule().stroke(Theme.recordRed.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Listen (Space)")
    }

    private var recordCluster: some View {
        HStack(spacing: 9) {
            Waveform(active: !store.paused, colour: Theme.recordRed)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(elapsed)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.recordRedText)
            }
            clusterButton(system: store.paused ? "play.fill" : "pause.fill",
                help: store.paused ? "Resume (Space)" : "Pause (Space)",
                action: onPauseResume)
            clusterButton(system: store.micMuted ? "mic.slash.fill" : "mic.fill",
                help: store.micMuted ? "Unmute mic" : "Mute mic (system audio keeps recording)",
                action: onMuteToggle)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 30, height: 30)
                    .background(Theme.recordRed, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Stop (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 9)
        .frame(height: 40)
        .background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11).stroke(Theme.recordRed.opacity(0.28), lineWidth: 0.5))
    }

    private func clusterButton(system: String, help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textBody)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var elapsed: String {
        guard let sessionStart else { return "00:00" }
        // `sessionStart` is shifted forward by paused durations on resume, so
        // now − sessionStart excludes prior pauses; while paused, count to the
        // pause moment so the display holds steady.
        let ref = pausedAt ?? Date()
        let s = max(0, Int(ref.timeIntervalSince(sessionStart)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: audio source

    private var audioSourceButton: some View {
        Menu {
            ForEach(devices) { d in
                Button {
                    selectedDevice = d
                } label: {
                    if d == selectedDevice {
                        Label(d.label, systemImage: "checkmark")
                    } else {
                        Text(d.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "mic.fill").font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedDevice?.label ?? "Default input")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    if captureSystem {
                        Text("+ system audio").font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.listening)
        .help("Audio source")
    }

    // MARK: focus chip

    /// The Name button's text: the session name (trimmed to keep the toolbar
    /// tidy) when one is set, otherwise the "Name" placeholder.
    private var nameLabel: String {
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Name" }
        return name.count > 24 ? String(name.prefix(24)) + "…" : name
    }

    /// A dedicated control for the optional session name — kept distinct from
    /// Context so it's where someone would look to name a session. Shows the name
    /// once set; click to edit (live too).
    private var nameChip: some View {
        Button { showName.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text(nameLabel).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sessionName.isEmpty ? Theme.textBody : Theme.textStrong)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showName, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text("An optional short label for this session. Editable during it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("e.g. Q3 board review", text: $sessionName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 8).frame(width: 280, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
                    .onSubmit { showName = false }
            }
            .padding(14)
        }
        .help("Session name")
    }

    private var focusChip: some View {
        Button { showFocus.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text("Context").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                // A small accent dot signals context has been set.
                if !sessionContext.isEmpty {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFocus, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text("Who's here, what it's about, what to focus on. Editable during the session.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $sessionContext)
                    .font(.system(size: 12.5))
                    .frame(width: 320, height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
            }
            .padding(14)
        }
        .help("Session context / prompt")
    }

    // MARK: auto cards / float / sessions

    private var autoCardsToggle: some View {
        HStack(spacing: 6) {
            Text("Auto cards").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Toggle("", isOn: $autoCards)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .controlSize(.small)
        }
    }

    private var floatButton: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 13))
                .foregroundStyle(pinned ? Theme.accent : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(
                    pinned ? Theme.accentTint : Theme.surfaceControl,
                    in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                        .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Float window on top")
    }

    private var exportButton: some View {
        Button(action: onExport) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                        .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!canExport)
        .help("Export session to Markdown…")
    }

    private var historyButton: some View {
        Button(action: onHistory) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                        .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Browse previous transcripts")
    }

    private var sessionsButton: some View {
        Button(action: onSessions) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                        .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open sessions folder")
    }
}

/// Five vertical bars whose heights oscillate while `active`; static otherwise.
/// In production the heights could be driven by live input RMS — for now it's a
/// fixed loop gated on the listening state (handoff "Interactions").
struct Waveform: View {
    let active: Bool
    let colour: Color
    @State private var animating = false
    private let count = 5

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(colour)
                    .frame(width: 2.5, height: 16)
                    .scaleEffect(y: animating ? 1 : 0.35, anchor: .center)
                    .animation(barAnimation(i), value: animating)
            }
        }
        .frame(height: 16)
        .onAppear { animating = active }
        .onChange(of: active) { _, a in animating = a }
    }

    private func barAnimation(_ i: Int) -> Animation? {
        active
            ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.15)
            : .easeOut(duration: 0.2)
    }
}
