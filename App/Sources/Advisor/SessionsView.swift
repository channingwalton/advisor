import AppKit
import SwiftUI

/// A saved session paired with its parsed detail, the unit the browser lists.
private struct LoadedSession: Identifiable, Equatable {
    let file: SessionFile
    let detail: SessionDetail
    var id: URL { file.url }

    /// Lowercased haystack for search (title, gist, transcript, card titles).
    let haystack: String
}

/// The Sessions browser: a master/detail window over saved session notes. Left:
/// search + filters + a date-grouped list. Right: the selected session rendered
/// like the live window (header, cards surfaced, questions asked, transcript)
/// with the ask bar kept. Replaces the old picker + per-session windows.
///
/// Scope is "layout + real data": everything here comes from the saved notes.
/// The handoff's AI-derived bits (category badge, topic chips, summary, people,
/// action items) and star/Resume are deliberately not rendered yet.
struct SessionsView: View {
    @State private var sessions: [LoadedSession] = []
    @State private var selection: URL?
    @State private var query = ""
    @State private var thisWeekOnly = false
    @State private var oldestFirst = false
    /// The user's tag library (issue #15) — supplies pill colours and the detail
    /// pane's autocomplete. Refreshed from config on appear and config changes.
    @State private var tagLibrary: [SavedTag] = []
    @Environment(\.openWindow) private var openWindow

    /// For the row context menu's live-note awareness (mirrors the detail pane).
    @ObservedObject private var ctx = TranscriptWindowContext.shared
    // Rename/delete are driven from the right-clicked row, so their alerts are
    // presented against that row rather than the selected one.
    @State private var renaming: LoadedSession?
    @State private var renameText = ""
    @State private var deleting: LoadedSession?

    /// The folders in the archive (issue #25), derived from disk sub-directories.
    /// Refreshed alongside `sessions` on appear and on session changes.
    @State private var folders: [String] = []
    /// Folders the user has collapsed. Absence = expanded, so new folders default
    /// open. Kept in view state only (resets per window open), like the selection.
    @State private var collapsedFolders: Set<String> = []
    // Folder create/rename/delete are driven from the sidebar inline.
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    /// When a folder is created from a row's "New Folder…", file this session into
    /// it once created; nil when creating an empty folder from the Folders bar.
    @State private var fileIntoNewFolder: LoadedSession?
    @State private var renamingFolder: String?
    @State private var folderRenameText = ""
    @State private var deletingFolder: String?
    /// The folder a row is currently being dragged over, highlighted as the drop
    /// target so it's clear where the session will land.
    @State private var dropTargetFolder: String?

    var body: some View {
        // Native NavigationSplitView: on macOS 26 (Tahoe) the sidebar column
        // renders as a floating Liquid-Glass panel over the full-bleed detail —
        // the "floating sidebar" look (Calendar/Notes). No opaque background on
        // the sidebar, or it would paint over the glass; the detail keeps its
        // solid surface. The recording controls live in the sidebar's top block,
        // aligned with the window controls in the title-bar row.
        NavigationSplitView(sidebar: {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 350, max: 420)
        }, detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surfaceWindow)
        })
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 560)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .advisorSessionsChanged)) { _ in
            reload()
        }
        // Tag library edits in Preferences (rename, recolour, delete) must
        // recolour/hide pills here without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            tagLibrary = AdvisorConfig.load().tags
        }
        // When a filter hides the selected session, select the first visible one
        // so the detail and sidebar stay consistent.
        .onChange(of: query) { _, _ in reconcileSelection() }
        .onChange(of: thisWeekOnly) { _, _ in reconcileSelection() }
        .alert("Rename session", isPresented: presenting($renaming), presenting: renaming) { session in
            TextField("Session name", text: $renameText)
            Button("Save") { renameSession(session.file, to: renameText, ctx: ctx) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Give this session a name. Leave blank to fall back to its context.")
        }
        .alert("Delete session", isPresented: presenting($deleting), presenting: deleting) { session in
            Button("Delete", role: .destructive) { deleteSession(session.file) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Delete “\(session.detail.title)”? This permanently removes its transcript "
                + "and cards, and can't be undone.")
        }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                createFolder(named: newFolderName, fileIn: fileIntoNewFolder)
                fileIntoNewFolder = nil
            }
            Button("Cancel", role: .cancel) { fileIntoNewFolder = nil }
        } message: {
            Text("Name the new folder.")
        }
        .alert("Rename folder", isPresented: presenting($renamingFolder), presenting: renamingFolder) { folder in
            TextField("Folder name", text: $folderRenameText)
            Button("Save") { renameFolder(folder, to: folderRenameText) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Give this folder a new name.")
        }
        .alert("Delete folder", isPresented: presenting($deletingFolder), presenting: deletingFolder) { folder in
            Button("Delete", role: .destructive) { deleteFolder(folder) }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("Delete the folder “\(folder)”? Its sessions move back out and are kept.")
        }
    }

    /// Bridge an optional-item state to the `Bool` an `.alert` wants: presented
    /// when the item is set, cleared back to `nil` on dismiss.
    private func presenting<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private func reconcileSelection() {
        if !filtered.contains(where: { $0.id == selection }) {
            selection = filtered.first?.id
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                searchField
                filterRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
            // A real `.sidebar` List, not a custom ScrollView — this is what
            // makes macOS 26 render the column as a floating Liquid-Glass panel.
            // Rows keep their bespoke look via cleared row insets/separators/
            // background; the glass shows through (`scrollContentBackground`).
            List {
                if filtered.isEmpty && visibleFolders.isEmpty {
                    Text(query.isEmpty ? "No previous sessions yet." : "No matches.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 16)
                        .plainSidebarRow()
                }
                if showFoldersBar { foldersBar.plainSidebarRow() }
                ForEach(visibleFolders, id: \.self) { folder in
                    Section {
                        if !collapsedFolders.contains(folder) {
                            ForEach(sessions(in: folder)) { session in
                                sessionRow(session).plainSidebarRow()
                            }
                        }
                    } header: {
                        folderHeader(folder).plainSidebarRow()
                    }
                }
                ForEach(grouped, id: \.label) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            sessionRow(session).plainSidebarRow()
                        }
                    } header: {
                        dateHeader(group.label).plainSidebarRow()
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
        }
        // Record lives in the sidebar's toolbar so it sits in the title-bar row,
        // aligned with the window controls (the Calendar layout the user asked
        // for) rather than a row below them.
        .toolbar {
            ToolbarItem(placement: .primaryAction) { newRecordingButton }
        }
    }

    /// The "FOLDERS" bar with a + to create one. Shown whenever there are folders
    /// to list, or the list is unfiltered (so the first folder can be created).
    private var showFoldersBar: Bool {
        !visibleFolders.isEmpty || query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var foldersBar: some View {
        HStack {
            Text("FOLDERS").font(.system(size: 10.5, weight: .bold)).kerning(0.4)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Button {
                newFolderName = ""
                fileIntoNewFolder = nil
                creatingFolder = true
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain).focusEffectDisabled().help("New folder")
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 2)
    }

    /// A collapsible folder section header: disclosure chevron, name, count.
    /// Tapping toggles expansion; right-click renames/deletes the folder.
    private func folderHeader(_ folder: String) -> some View {
        let collapsed = collapsedFolders.contains(folder)
        let count = sessions(in: folder).count
        let targeted = dropTargetFolder == folder
        return Button {
            if collapsed { collapsedFolders.remove(folder) } else { collapsedFolders.insert(folder) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textMuted)
                    .frame(width: 10)
                Image(systemName: targeted ? "folder.fill" : "folder")
                    .font(.system(size: 11)).foregroundStyle(targeted ? Theme.accent : Theme.textSecondary)
                Text(folder).font(.system(size: 11.5, weight: .bold)).kerning(0.2)
                    .foregroundStyle(targeted ? Theme.accent : Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(count)").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tint the row and outline it while a session is dragged over, so the
            // drop target is unmistakable.
            .background(targeted ? Theme.accent.opacity(0.12) : Theme.surfaceTitlebar)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.accent, lineWidth: 1.5)
                    .padding(.horizontal, 6)
                    .opacity(targeted ? 1 : 0))
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .contextMenu { folderMenu(folder) }
        // Drop a dragged session row here to file it into this folder (issue #25),
        // highlighting the header while it's the active target.
        .dropDestination(for: URL.self) { urls, _ in
            fileSessions(urls, to: folder)
            return true
        } isTargeted: { isIn in
            withAnimation(.easeInOut(duration: 0.12)) {
                // Clear only when *this* folder loses the drag, so a move to the
                // next folder doesn't blank the new target set just before it.
                dropTargetFolder = isIn ? folder : (dropTargetFolder == folder ? nil : dropTargetFolder)
            }
        }
    }

    /// File the sessions identified by the dropped `urls` into `folder`, expanding
    /// it so the result is visible. Unknown URLs (anything not a current session
    /// row, e.g. a file dragged in from Finder) are ignored, so a stray drag can't
    /// misfile. The matching sessions are resolved up front: each `fileSession`
    /// triggers a reload that reassigns `sessions`, so resolving inside the loop
    /// could miss later rows.
    private func fileSessions(_ urls: [URL], to folder: String) {
        collapsedFolders.remove(folder)
        let toFile = urls.compactMap { url in sessions.first { $0.file.url == url } }
        for session in toFile {
            fileSession(session, to: folder)
        }
    }

    private func dateHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .bold)).kerning(0.4)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14).padding(.bottom, 4)
            .background(Theme.surfaceTitlebar)
    }

    @ViewBuilder private func folderMenu(_ folder: String) -> some View {
        Button("Rename Folder…") {
            folderRenameText = folder
            renamingFolder = folder
        }
        Button("New Folder…") {
            newFolderName = ""
            fileIntoNewFolder = nil
            creatingFolder = true
        }
        Divider()
        Button("Delete Folder", role: .destructive) { deletingFolder = folder }
    }

    /// Primary action: open (or bring forward) the single recording window. The
    /// ⌘N shortcut is bound globally by `RecordingCommands` (menu bar), so it
    /// isn't re-bound here to avoid a duplicate-binding conflict — the tooltip
    /// carries the hint instead.
    private var newRecordingButton: some View {
        Button { openWindow(id: "recording") } label: {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Theme.recordRed)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Start a new recording (⌘N)")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search sessions… (#tag to filter by tag)", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            chip("All", on: !thisWeekOnly) { thisWeekOnly = false }
            chip("This week", on: thisWeekOnly) { thisWeekOnly = true }
            Spacer()
            Button { oldestFirst.toggle() } label: {
                HStack(spacing: 3) {
                    Text(oldestFirst ? "Oldest" : "Recent").font(.system(size: 11.5))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Sort order")
        }
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Theme.textBody)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(
                    on ? Theme.accent : Theme.surfaceCard,
                    in: Capsule())
                .overlay(Capsule().stroke(on ? .clear : Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func sessionRow(_ session: LoadedSession) -> some View {
        // The owned note can't be filed (its writer owns the path), so it isn't
        // draggable either — mirrors the disabled "Move to Folder" menu.
        if session.file.url == ctx.liveFileURL {
            sessionRowBody(session)
        } else {
            sessionRowBody(session).draggable(session.file.url)
        }
    }

    private func sessionRowBody(_ session: LoadedSession) -> some View {
        let selected = selection == session.id
        let d = session.detail
        return Button { selection = session.id } label: {
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Self.rowTime(d.started ?? session.file.date))
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    if !d.gist.isEmpty {
                        Text(d.gist).font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let m = d.durationMinutes {
                            Text("\(m) min").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Theme.accent).frame(width: 4, height: 4)
                            Text("\(d.cards.count) cards").font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    tagPills(for: d)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Theme.surfaceCard : .clear)
                    .shadow(color: selected ? Theme.cardShadow : .clear, radius: 4, y: 1))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                        .frame(width: 3).padding(.vertical, 4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.accent.opacity(0.22) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .contextMenu { rowMenu(session) }
    }

    /// Right-click actions for a list row — the same set as the detail pane's
    /// ellipsis menu (issue #20), sharing its action helpers.
    @ViewBuilder private func rowMenu(_ session: LoadedSession) -> some View {
        Button("Rename…") {
            renameText = session.detail.name
            renaming = session
        }
        moveToFolderMenu(session)
        Button("Export…") { exportSession(session.file) }
        ShareLink("Share…", item: session.file.url, preview: SharePreview(session.detail.title))
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.file.url])
        }
        Divider()
        // The live note is exempt: its writer would just recreate the deleted file.
        Button("Delete…", role: .destructive) { deleting = session }
            .disabled(session.file.url == ctx.liveFileURL)
    }

    /// "Move to Folder" submenu (issue #25): existing folders, "No Folder" to
    /// un-file, and "New Folder…" to create-and-file. Disabled for the live/owned
    /// note — filing it would move the file out from under its writer (mirrors the
    /// Delete exemption and the #16 storage move, which also skip the live note).
    @ViewBuilder private func moveToFolderMenu(_ session: LoadedSession) -> some View {
        Menu("Move to Folder") {
            if session.file.folder != nil {
                Button("No Folder") { fileSession(session, to: nil) }
                Divider()
            }
            ForEach(folders, id: \.self) { folder in
                Button(folder) { fileSession(session, to: folder) }
                    .disabled(folder == session.file.folder)
            }
            if !folders.isEmpty { Divider() }
            Button("New Folder…") {
                newFolderName = ""
                fileIntoNewFolder = session
                creatingFolder = true
            }
        }
        .disabled(session.file.url == ctx.liveFileURL)
    }

    /// Coloured pills for a row's tags. Only tags still in the library render —
    /// a tag deleted in Preferences disappears here without rewriting the note.
    @ViewBuilder private func tagPills(for d: SessionDetail) -> some View {
        let known = d.tags.compactMap { name in
            TagLibrary.named(name, in: tagLibrary).map { (name, $0.colorHex) }
        }
        if !known.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(known, id: \.0) { name, hex in
                    TagPill(name: name, colorHex: hex)
                }
            }
            .padding(.top, 1)
        }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        // Resolve against the *filtered* list: a session hidden by search/filter
        // must not stay open in the detail (the Ask bar would append to a
        // transcript no longer in the sidebar).
        if let selected = filtered.first(where: { $0.id == selection }) {
            SessionDetailPane(file: selected.file, detail: selected.detail, library: tagLibrary)
                .id(selected.id)
        } else {
            Text("Select a session to read it.")
                .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: data

    private func reload() {
        tagLibrary = AdvisorConfig.load().tags
        folders = SessionArchive.folders()
        sessions = SessionArchive.list().map { file in
            let contents = SessionArchive.contents(of: file)
            let detail = SessionDetail.parse(
                contents: contents, fallbackTitle: Self.rowTitle(file.date))
            let haystack = ([detail.title, detail.name, detail.context, detail.gist]
                + detail.tags
                + detail.cards.map(\.title)
                + detail.blocks.compactMap { if case .paragraph(let t) = $0 { t } else { nil } })
                .joined(separator: " ").lowercased()
            return LoadedSession(file: file, detail: detail, haystack: haystack)
        }
        if selection == nil || !sessions.contains(where: { $0.id == selection }) {
            selection = filtered.first?.id
        }
    }

    // MARK: folder actions (issue #25)

    /// File `session` into `folder` (nil un-files it), moving the note on disk. The
    /// owned note is skipped (its move menu is disabled too). Re-points selection
    /// when the moved note was selected, since its URL — the selection key —
    /// changes, then reloads from disk.
    private func fileSession(_ session: LoadedSession, to folder: String?) {
        guard session.file.url != ctx.liveFileURL else { return }
        if let moved = SessionArchive.setFolder(folder, for: session.file) {
            if selection == session.file.url { selection = moved.url }
        }
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Create `name`; if `session` is set (from a row's "New Folder…"), file it in.
    private func createFolder(named name: String, fileIn session: LoadedSession?) {
        guard SessionArchive.createFolder(name) else { return }
        if let session, let folder = SessionArchive.sanitiseFolderName(name) {
            fileSession(session, to: folder) // posts the reload notification
        } else {
            NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
        }
    }

    /// Rename a folder (its notes travel with the directory). Selection may reset
    /// to the first visible session if it pointed inside the folder, since those
    /// notes' URLs change — reload reconciles it.
    private func renameFolder(_ old: String, to new: String) {
        SessionArchive.renameFolder(from: old, to: new)
        collapsedFolders.remove(old)
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Delete a folder; its sessions are un-filed back to the root, not deleted.
    private func deleteFolder(_ folder: String) {
        SessionArchive.deleteFolder(folder)
        collapsedFolders.remove(folder)
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Filtered + sorted sessions (search + this-week chip + sort order).
    private var filtered: [LoadedSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        return sessions
            .filter { SessionSearch.matches(query: q, tags: $0.detail.tags, haystack: $0.haystack) }
            // Calendar week, matching the sidebar's TODAY / YESTERDAY / EARLIER
            // THIS WEEK grouping — not a rolling 7 days, which would disagree
            // with those labels near the start of the week.
            .filter {
                !thisWeekOnly
                    || cal.isDate($0.detail.started ?? $0.file.date, equalTo: Date(),
                        toGranularity: .weekOfYear)
            }
            .sorted {
                let a = $0.detail.started ?? $0.file.date
                let b = $1.detail.started ?? $1.file.date
                return oldestFirst ? a < b : a > b
            }
    }

    /// Filtered sessions that sit in `folder`, in sort order (folders show a flat
    /// list, not date-grouped — date grouping is for the un-foldered area).
    private func sessions(in folder: String) -> [LoadedSession] {
        filtered.filter { $0.file.folder == folder }
    }

    /// Which folders to show: all of them when unfiltered (so empty folders still
    /// appear and can be managed), only folders with a match when searching.
    private var visibleFolders: [String] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? folders
            : folders.filter { !sessions(in: $0).isEmpty }
    }

    /// Un-foldered filtered sessions grouped into relative-date sections, in list
    /// order. Foldered sessions are shown under their folder instead.
    private var grouped: [(label: String, sessions: [LoadedSession])] {
        var order: [String] = []
        var byLabel: [String: [LoadedSession]] = [:]
        for session in filtered where session.file.folder == nil {
            let label = Self.bucket(session.detail.started ?? session.file.date)
            if byLabel[label] == nil { order.append(label) }
            byLabel[label, default: []].append(session)
        }
        return order.map { ($0, byLabel[$0] ?? []) }
    }

    // MARK: date formatting

    private static func bucket(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let now = Date()
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "EARLIER THIS WEEK" }
        if cal.isDate(date, equalTo: now, toGranularity: .month) { return "THIS MONTH" }
        return "EARLIER"
    }

    /// Right-aligned row time: today → time, this week → weekday, else date.
    private static func rowTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Fallback title (no context in the note): date + time.
    private static func rowTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Sidebar list-row styling

private extension View {
    /// Strip a List row's default chrome (insets, separator, background) so the
    /// sidebar's bespoke rows and headers render as before while the column
    /// itself stays a real `.sidebar` List (floating glass).
    func plainSidebarRow() -> some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Session actions (shared by the browser list's context menu and the
// detail pane's ellipsis menu, so their live-note handling can't diverge).

/// Live-note-aware rename: routes through the recording writer when `file` is the
/// note being recorded right now (so its next debounced rewrite carries the new
/// name), else edits the saved note on disk. Posts `advisorSessionsChanged` so the
/// browser reloads from disk.
@MainActor private func renameSession(_ file: SessionFile, to name: String, ctx: TranscriptWindowContext) {
    let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if file.url == ctx.liveFileURL, let writer = ctx.writer {
        writer.renameOwnedNote(new)
    } else {
        SessionArchive.setName(new, in: file)
    }
    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
}

/// Delete a saved note from disk and reload the browser. The live note is never
/// passed here — both menus disable its Delete entry — because its writer would
/// just recreate the file.
@MainActor private func deleteSession(_ file: SessionFile) {
    SessionArchive.delete(file)
    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
}

/// Copy a session note to a user-chosen destination. Atomic write (read source,
/// then replace) never pre-deletes the destination, so a failure can't leave a
/// chosen file gone, and exporting onto the source itself is harmless. Failures
/// surface as a modal alert.
@MainActor private func exportSession(_ file: SessionFile) {
    let panel = NSSavePanel()
    panel.title = "Export Session"
    panel.nameFieldStringValue = file.url.lastPathComponent
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let dest = panel.url else { return }
    do {
        try Data(contentsOf: file.url).write(to: dest, options: .atomic)
    } catch {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// The right-hand detail: a selected session rendered like the live window —
/// header + meta, the cards it surfaced, the questions asked of it, and the full
/// transcript — with the ask bar kept (answers append to the note on disk).
private struct SessionDetailPane: View {
    let file: SessionFile
    let detail: SessionDetail
    /// The tag library, for the Tags chip's autocomplete and pill colours.
    let library: [SavedTag]

    @ObservedObject private var ctx = TranscriptWindowContext.shared

    // Ask state.
    @State private var question = ""
    @State private var answerBody = ""
    @State private var answerState = "" // "" idle, else pending|streaming|done|failed
    @State private var askNote = ""

    // Rename state.
    @State private var renaming = false
    @State private var renameText = ""

    // Delete confirmation.
    @State private var confirmingDelete = false

    private var isAsking: Bool { answerState == "pending" || answerState == "streaming" }
    /// Asking the still-being-written live note is disabled (the writer's
    /// debounced rewrite would clobber an appended follow-up).
    private var isLive: Bool { file.url == ctx.liveFileURL }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !detail.questions.isEmpty { youAsked }
                    transcript
                }
                .frame(maxWidth: Theme.Metric.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
            }
            if !answerBody.isEmpty {
                Divider()
                liveAnswer
            }
            Divider()
            askBar
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(detail.title)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Theme.textStrong)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                TagsChip(tags: detail.tags, library: library, onChange: applyTags)
                Menu {
                    Button("Rename…") {
                        renameText = detail.name
                        renaming = true
                    }
                    Button("Export…") { exportSession(file) }
                    ShareLink("Share…", item: file.url, preview: SharePreview(detail.title))
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                    Divider()
                    // The live note is exempt: its writer would just recreate any
                    // file deleted out from under it.
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                        .disabled(isLive)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 30)
                        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(metaLine).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            tagRow
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Session name", text: $renameText)
            Button("Save", action: saveName)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this session a name. Leave blank to fall back to its context.")
        }
        .alert("Delete session", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteSession(file) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete “\(detail.title)”? This permanently removes its transcript "
                + "and cards, and can't be undone.")
        }
    }

    /// At-a-glance pills for the session's tags (library-known only), under the
    /// meta line. Editing is via the header's Tags chip.
    @ViewBuilder private var tagRow: some View {
        let known = detail.tags.compactMap { name in
            TagLibrary.named(name, in: library).map { (name, $0.colorHex) }
        }
        if !known.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(known, id: \.0) { name, hex in
                    TagPill(name: name, colorHex: hex)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Persist a tag change. The live/just-finished note is tagged through its
    /// writer (so a late card rewrite carries the tags); any other note is edited
    /// on disk directly. Either way, reload the browser from disk. Mirrors
    /// `saveName`.
    private func applyTags(_ tags: [String]) {
        if isLive, let writer = ctx.writer {
            writer.setOwnedNoteTags(tags)
            // Keep the recording window's own tag state in step, or its next
            // toolbar edit would overwrite this one from a stale array.
            NotificationCenter.default.post(
                name: .advisorLiveTagsChanged, object: nil, userInfo: ["tags": tags])
        } else {
            SessionArchive.setTags(tags, in: file)
        }
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Persist the renamed title via the shared, live-note-aware helper.
    private func saveName() { renameSession(file, to: renameText, ctx: ctx) }

    private var metaLine: String {
        var parts: [String] = []
        if let started = detail.started {
            let day = started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            if let ended = detail.ended {
                let from = started.formatted(date: .omitted, time: .shortened)
                let to = ended.formatted(date: .omitted, time: .shortened)
                parts.append("\(day) · \(from)–\(to)")
            } else {
                parts.append("\(day) · \(started.formatted(date: .omitted, time: .shortened))")
            }
        }
        if let m = detail.durationMinutes { parts.append("\(m) min") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: you asked

    private var youAsked: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("YOU ASKED", count: "\(detail.questions.count) questions")
            ForEach(Array(detail.questions.enumerated()), id: \.offset) { _, q in
                HStack(alignment: .top, spacing: 10) {
                    Text("Y").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Theme.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.question).font(.system(size: 13)).foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(q.askedAt.isEmpty ? "Answered inline" : "Answered inline · \(q.askedAt)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    // MARK: transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.paragraphSpacing) {
            sectionLabel("TRANSCRIPT", count: nil)
            ForEach(Array(detail.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    SelectableTranscriptText(
                        text: text, toolTip: "", actions: [], onAction: { _, _ in })
                case .card(let markdown):
                    cardBlock(markdown)
                case .heading(let title) where title != "Transcript":
                    Text(title).font(.system(size: 11, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                case .heading:
                    EmptyView()
                }
            }
        }
    }

    private func cardBlock(_ markdown: String) -> some View {
        MarkdownText(markdown: markdown, style: .saved)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.cardRadius)
                    .stroke(Theme.hairline, lineWidth: 0.5))
            .padding(.vertical, 4)
    }

    // MARK: shared bits

    private func sectionLabel(_ title: String, count: String?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .bold)).kerning(0.5)
                .foregroundStyle(Theme.textSecondary)
            if let count {
                Text(count).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: ask

    private var liveAnswer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if isAsking { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text(answerState == "failed" ? "Couldn't answer" : "Answer")
                        .font(.system(size: 11, weight: .bold)).kerning(0.5)
                        .foregroundStyle(answerState == "failed" ? Theme.factRed : Theme.accent)
                }
                MarkdownText(markdown: answerBody, style: .answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(maxHeight: 200)
        .background(Theme.surfaceCard)
    }

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField(
                    isLive
                        ? "Advisor is still writing this session — ask once it has fully saved…"
                        : "Ask a question about this transcript…",
                    text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.surfaceCardInset, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 0.5))
                    .onSubmit(submitQuestion)
                    .disabled(isLive || isAsking)
                Button("Ask", action: submitQuestion)
                    .buttonStyle(SendButtonStyle(accent: Theme.accent))
                    .disabled(isLive || isAsking
                        || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !askNote.isEmpty {
                Text(askNote).font(.system(size: 11)).foregroundStyle(Theme.factRed)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 10)
        .background(Theme.surfaceTitlebar)
    }

    private func submitQuestion() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking, !isLive else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }

        askNote = ""
        answerBody = "…"
        answerState = "pending"
        let document = SessionArchive.contents(of: file)

        let sent = sidecar.askDocument(question: q, document: document) { body, state in
            answerBody = body
            answerState = state
            if state == "done" {
                SessionArchive.appendFollowUp(question: q, answer: body, to: file)
                // Refresh the parent list cache (and so this pane's `detail`),
                // not just a pane-local copy, or the appended Q&A would vanish on
                // navigating away and back or via search.
                NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                answerBody = ""
                answerState = ""
            }
        }
        if sent == nil {
            askNote = "Sidecar not running — question not sent."
            answerBody = ""
            answerState = ""
            return
        }
        question = ""
    }
}
