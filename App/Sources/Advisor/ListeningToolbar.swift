import SwiftUI

/// The Listening view's control strip (60 pt). Left: record cluster (waveform +
/// timer + mic mute + stop) and audio-source button. Right: Ask and Note, the
/// target folder, Name, Context and Tags chips, Auto-cards toggle, then Hide
/// transcript, Summarise, Float and Export. Idle collapses the cluster to a single Listen pill; a
/// stopped-but-resumable session shows a frozen-timer Resume cluster (issue #6).
/// When the window is too narrow to fit them all, the less-used buttons fold into
/// a More menu, then the chips collapse to icon-only (ViewThatFits), rather than
/// letting their text wrap/squash.
struct ListeningToolbar: View {
    @ObservedObject var store: TranscriptStore
    let recordingState: RecordControl.State
    let sessionStart: Date?
    /// When stopped, the moment capture stopped — freezes the timer display until
    /// the session is resumed. Nil while recording or idle.
    let stoppedAt: Date?
    /// The folder this recording is filed into (issue #35), shown read-only so it's
    /// clear where the note lands. Nil = un-foldered (no indicator shown).
    let targetFolder: String?
    @Binding var selectedDevice: InputDevice?
    let devices: [InputDevice]
    let captureSystem: Bool
    @Binding var sessionName: String
    @Binding var sessionContext: String
    /// The session's tags (issue #15), edited via the Tags chip.
    @Binding var sessionTags: [String]
    /// The user's library of named contexts, shown in the Context popover's Load
    /// menu (issue #10).
    let savedContexts: [SavedContext]
    /// The user's tag library, for the Tags chip's autocomplete (issue #15).
    let tagLibrary: [SavedTag]
    /// Save the current context text under the given name.
    let onSaveContext: (String) -> Void
    @Binding var autoCards: Bool
    /// Experiment: hide the transcript so the feed shows only cards.
    @Binding var hideTranscript: Bool
    @Binding var pinned: Bool
    let onStart: () -> Void
    let onResume: () -> Void
    let onMuteToggle: () -> Void
    let onStop: () -> Void
    /// Whether the current session has anything to export (gates the button).
    let canExport: Bool
    let onExport: () -> Void
    /// Add/update the session's Summary card (issue #30); gated by `canSummarise`
    /// (no transcript yet, or a summary already in flight).
    let canSummarise: Bool
    let onSummarise: () -> Void
    /// The Ask popover's question (issue #104), kept while it's closed, and
    /// whether it's open — the window opens it for ⌘K too.
    @Binding var askText: String
    @Binding var showAsk: Bool
    let onAsk: () -> Void
    /// The Note popover's draft and whether it's open — the window opens it for
    /// ⇧⌘N and "Add note here…" too.
    @Binding var noteDraft: NoteDraft
    @Binding var showNote: Bool
    let onNote: () -> Void

    @State private var showFocus = false
    @State private var showName = false
    /// Toggles the "save current context" name field in the Context popover.
    @State private var showSaveField = false
    @State private var savingName = ""

    var body: some View {
        HStack(spacing: 12) {
            switch recordingState {
            case .recording: recordCluster
            case .stopped: resumeCluster
            case .idle: listenButton
            }
            audioSourceButton
            Spacer(minLength: 8)
            // When the toolbar is too narrow, fold the less-used buttons into More,
            // then drop the chip labels (icon-only), rather than letting the text
            // wrap/squash. ViewThatFits picks the first layout that fits the
            // leftover width — adapting to the (variable-length) audio-source name.
            ViewThatFits(in: .horizontal) {
                ForEach(Layout.narrowing, id: \.self, content: secondaryControls)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.toolbarHeight)
        .background(Theme.surfaceTitlebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        // Suppress the system keyboard-focus ring on the toolbar's custom controls.
        .focusEffectDisabled()
    }

    /// A way to lay out the right-hand control group. `folded` moves Hide
    /// transcript, Summarise, Float and Export into a More menu; `compact` hides
    /// the chip text labels (keeping the icons and indicators) so the strip
    /// degrades gracefully when narrow.
    struct Layout: Hashable {
        let compact: Bool
        let folded: Bool

        /// Widest first, as ViewThatFits tries them: the less-used buttons fold
        /// into More before the labels go, and a narrower layout only ever takes
        /// things away.
        static let narrowing = [
            Layout(compact: false, folded: false),
            Layout(compact: false, folded: true),
            Layout(compact: true, folded: true),
        ]
    }

    /// The right-hand control group, laid out as `layout` says.
    private func secondaryControls(_ layout: Layout) -> some View {
        let compact = layout.compact
        return HStack(spacing: 12) {
            askButton(compact: compact)
            noteButton(compact: compact)
            folderIndicator(compact: compact)
            nameChip(compact: compact)
            focusChip(compact: compact)
            TagsChip(tags: sessionTags, library: tagLibrary, compact: compact) { sessionTags = $0 }
            autoCardsToggle(compact: compact)
            if layout.folded {
                moreMenu
            } else {
                hideTranscriptButton
                summariseButton
                floatButton
                exportButton
            }
        }
    }

    // MARK: record cluster

    private var listenButton: some View {
        Button(action: onStart) {
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
            Waveform(active: true, colour: Theme.recordRed)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(elapsed)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.recordRedText)
            }
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

    /// Shown while a session is stopped but resumable: the frozen elapsed timer
    /// and a Resume button that picks the same session back up (issue #6).
    private var resumeCluster: some View {
        HStack(spacing: 9) {
            Waveform(active: false, colour: Theme.recordRed)
            Text(elapsed)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Button(action: onResume) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    Text("Resume").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(Theme.recordRed, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Resume (Space)")
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
        // `sessionStart` is shifted forward by stopped durations on resume, so
        // now − sessionStart excludes prior stops; while stopped, count to the
        // stop moment so the display holds steady.
        let ref = store.listening ? Date() : (stoppedAt ?? Date())
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
            .controlChrome()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.listening)
        .help("Audio source")
    }

    // MARK: ask / note

    /// Ask a question of the conversation, in a popover (issue #104).
    private func askButton(compact: Bool) -> some View {
        Button { showAsk.toggle() } label: {
            composerLabel(
                "Ask", system: "sparkle", tint: Theme.accent, compact: compact,
                hasDraft: !askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAsk, arrowEdge: .bottom) {
            ComposerForm(
                title: "Ask", prompt: "Anything about this conversation — or beyond it.",
                placeholder: "Ask anything…", submitTitle: "Ask", tint: .ask,
                text: $askText, onSubmit: onAsk)
        }
        .help("Ask (⌘K)")
    }

    /// Add an editorial note, in a popover (issue #104): at this point in the
    /// conversation, or under the line "Add note here…" was chosen on.
    private func noteButton(compact: Bool) -> some View {
        Button { showNote.toggle() } label: {
            composerLabel(
                "Note", system: "note.text", tint: Theme.factGreen, compact: compact,
                hasDraft: !noteDraft.isBlank)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showNote, arrowEdge: .bottom) {
            ComposerForm(
                title: "Note",
                prompt: noteDraft.placement == nil
                    ? "Your own context, added at this point in the conversation. The agents read it."
                    : "Your own context, added under this line. The agents read it.",
                placeholder: "Add a note…", submitTitle: "Add note", tint: .note,
                text: $noteDraft.text, quote: noteDraft.placement?.line,
                onClearQuote: { noteDraft.placement = nil }, onSubmit: onNote)
        }
        .help("Add a note (⇧⌘N)")
    }

    /// An Ask or Note chip: its icon, the label unless compact, and a dot on the
    /// icon while a draft waits in the closed popover. The dot takes no width: a
    /// wider chip could tip the toolbar into its compact layout as the first key
    /// is typed, closing the popover with its button.
    private func composerLabel(_ title: String, system: String, tint: Color, compact: Bool, hasDraft: Bool)
        -> some View
    {
        HStack(spacing: 6) {
            Image(systemName: system).font(.system(size: 12)).foregroundStyle(tint)
                .overlay(alignment: .topTrailing) {
                    if hasDraft {
                        Circle().fill(tint).frame(width: 5, height: 5).offset(x: 4, y: -3)
                    }
                }
            if !compact {
                Text(title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .controlChrome()
    }

    // MARK: folder indicator

    /// A read-only chip showing the folder this recording is filed into (issue
    /// #35), so it's clear where the note lands. Hidden when un-foldered. The
    /// folder is fixed at session start, so this isn't a picker — re-filing is via
    /// the Sessions browser's Move to Folder once the session is saved.
    @ViewBuilder private func folderIndicator(compact: Bool) -> some View {
        if let folder = targetFolder {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                if !compact {
                    Text(folder).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textStrong)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
            .help("This recording is filed into the “\(folder)” folder")
        }
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
    private func nameChip(compact: Bool) -> some View {
        Button { showName.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "textformat").font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                if compact {
                    // A small accent dot signals a name has been set (the label is
                    // hidden), mirroring the Context chip.
                    if !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    }
                } else {
                    Text(nameLabel).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(sessionName.isEmpty ? Theme.textBody : Theme.textStrong)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .controlChrome()
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

    private func focusChip(compact: Bool) -> some View {
        Button { showFocus.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                if !compact {
                    Text("Context").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(1)
                }
                // A small accent dot signals context has been set.
                if !sessionContext.isEmpty {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .controlChrome()
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
                contextLibraryControls
            }
            .padding(14)
        }
        .help("Session context / prompt")
    }

    /// Load (pick a saved context into the box) and Save (store the current text
    /// under a name) controls, sitting under the Context editor (issue #10).
    private var contextLibraryControls: some View {
        HStack(spacing: 8) {
            SavedContextMenu(contexts: savedContexts) { sessionContext = $0.text }

            Spacer(minLength: 4)

            if showSaveField {
                TextField("Name", text: $savingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(commitSaveContext)
                Button("Save", action: commitSaveContext)
                    .font(.system(size: 12))
                    .disabled(savingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button {
                    showSaveField = true
                } label: {
                    Label("Save…", systemImage: "tray.and.arrow.up")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(sessionContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func commitSaveContext() {
        let name = savingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onSaveContext(name)
        savingName = ""
        showSaveField = false
    }

    // MARK: auto cards / float / sessions

    private func autoCardsToggle(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if !compact {
                Text("Auto cards").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Toggle("", isOn: $autoCards)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .controlSize(.small)
        }
        // The label is dropped when compact, so name the control via help.
        .help("Auto cards")
    }

    /// Toggle the transcript off so the feed shows only cards (experiment).
    private var hideTranscriptButton: some View {
        Button { hideTranscript.toggle() } label: {
            Image(systemName: hideTranscript ? "eye.slash" : "eye")
                .font(.system(size: 13))
                .foregroundStyle(hideTranscript ? Theme.accent : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(
                    hideTranscript ? Theme.accentTint : Theme.surfaceControl,
                    in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                        .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(hideTranscript ? "Show transcript" : "Hide transcript (cards only)")
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

    /// Add or update the session's Summary card from the whole conversation.
    private var summariseButton: some View {
        Button(action: onSummarise) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .controlChrome()
        }
        .buttonStyle(.plain)
        .disabled(!canSummarise)
        .help("Summarise the conversation (adds or updates a Summary card)")
    }

    private var exportButton: some View {
        Button(action: onExport) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .controlChrome()
        }
        .buttonStyle(.plain)
        .disabled(!canExport)
        .help("Export session to Markdown…")
    }

    /// Hide transcript, Summarise, Float and Export as one menu, for a window too
    /// narrow for their buttons. It takes the accent while the transcript is
    /// hidden or the window floats, as their buttons do, so folding them doesn't
    /// hide that either is on.
    private var moreMenu: some View {
        let on = hideTranscript || pinned
        return Menu {
            Toggle("Hide Transcript", isOn: $hideTranscript)
            Button("Summarise", action: onSummarise).disabled(!canSummarise)
            Toggle("Float on Top", isOn: $pinned)
            Button("Export…", action: onExport).disabled(!canExport)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(
                    on ? Theme.accentTint : Theme.surfaceControl,
                    in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                        .stroke(Theme.hairline, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Hide transcript, summarise, float or export")
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

extension View {
    /// The standard toolbar control chrome: a `surfaceControl` fill with a
    /// hairline stroke, both at `buttonRadius`. Applied after sizing (frame /
    /// padding) so it wraps the control's final bounds. Extracted from the pill
    /// and icon buttons that repeated it verbatim (issue #66). Toggle buttons
    /// with a state-dependent accent fill keep their own `.background`.
    func controlChrome() -> some View {
        background(Theme.surfaceControl, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
    }
}
