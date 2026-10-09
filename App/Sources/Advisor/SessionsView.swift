import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// The saved-contexts library (issue #10), offered by a folder's context
    /// popover. Refreshed from config on appear and config changes.
    @State private var savedContexts: [SavedContext] = []
    /// Which research kinds are on in Preferences — gates the detail's
    /// right-click Answer / Context / Fact check, as in the recording window.
    @State private var triggers = AdvisorConfig.Triggers()
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
    /// Each folder's saved context (issue #36), keyed by folder name. Drives the
    /// header's context button state and is the seed a recording started here
    /// inherits. Refreshed from disk alongside `folders` in `reload`.
    @State private var folderContexts: [String: String] = [:]
    /// Each folder's default tags (issue #76), keyed by folder name. New recordings
    /// started from the folder inherit them; existing or moved sessions do not.
    @State private var folderTags: [String: [String]] = [:]
    /// The folder row under the pointer, which reveals its actions; and whether
    /// the pointer is over the Folders label, which reveals its +.
    @State private var hoveredFolder: String?
    @State private var hoveringFoldersBar = false

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
        // recolour/hide pills and refresh folder defaults without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            let config = AdvisorConfig.load()
            let library = config.tags
            tagLibrary = library
            savedContexts = config.contexts
            triggers = config.triggers
            folderTags = folders.reduce(into: [:]) {
                $0[$1] = SessionArchive.folderTags($1).filter {
                    TagLibrary.named($0, in: library) != nil
                }
            }
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
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            // A real `.sidebar` List, not a custom ScrollView — this is what
            // makes macOS 26 render the column as a floating Liquid-Glass panel.
            // Rows keep their bespoke look via cleared row insets/separators/
            // background; the glass shows through (`scrollContentBackground`).
            List {
                if filtered.isEmpty && visibleFolders.isEmpty {
                    Text(query.isEmpty ? "No previous sessions yet." : "No matches.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.top, 16)
                        .plainSidebarRow()
                }
                if showFoldersBar { foldersBar.plainSidebarRow() }
                // Folders render as plain rows, not a `Section` header: a sidebar
                // Section header flattens nested controls, so the header's record
                // button (issue #35) wouldn't show — a regular row keeps it live
                // (the same reason `foldersBar`'s + button works).
                ForEach(visibleFolders, id: \.self) { folder in
                    Group {
                        folderHeader(folder).plainSidebarRow()
                        if !collapsedFolders.contains(folder) {
                            ForEach(sessions(in: folder)) { session in
                                sessionRow(session)
                                    .padding(.leading, 16)
                                    .plainSidebarRow()
                            }
                        }
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

    /// The "Folders" label with a + to create one (shown on hover). Shown whenever
    /// there are folders to list, or the list is unfiltered (so the first folder
    /// can be created).
    private var showFoldersBar: Bool {
        !visibleFolders.isEmpty || query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var foldersBar: some View {
        HStack {
            Text("Folders").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
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
            .opacity(hoveringFoldersBar ? 1 : 0)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { hoveringFoldersBar = $0 }
    }

    /// A collapsible folder section header: disclosure chevron, name and count.
    /// On hover the count gives way to the folder's default controls and a record
    /// button that starts a recording filed into this folder (issues #35/#36/#76).
    /// Tapping the row toggles expansion; right-click renames/deletes the folder.
    /// A plain row with `.onTapGesture`, not a `Button`, so the nested record
    /// `Button` keeps its own tap target rather than being swallowed by an outer one.
    private func folderHeader(_ folder: String) -> some View {
        let collapsed = collapsedFolders.contains(folder)
        let count = sessions(in: folder).count
        let targeted = dropTargetFolder == folder
        let hovered = hoveredFolder == folder
        return HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                .frame(width: 10)
            Image(systemName: targeted ? "folder.fill" : "folder")
                .font(.system(size: 12)).foregroundStyle(targeted ? Theme.accent : Theme.textSecondary)
            Text(folder).font(.system(size: 13))
                .foregroundStyle(targeted ? Theme.accent : Theme.textStrong).lineLimit(1)
            Spacer(minLength: 6)
            // Opacity, not removal: an open context/tags popover stays anchored
            // to its button after the pointer leaves the row.
            ZStack(alignment: .trailing) {
                Text("\(count)").font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovered ? 0 : 1)
                HStack(spacing: 9) {
                    FolderContextButton(
                        folder: folder,
                        context: folderContexts[folder] ?? "",
                        library: savedContexts
                    ) { text in
                        saveFolderContext(text, for: folder)
                    }
                    FolderTagsButton(
                        folder: folder,
                        tags: folderTags[folder] ?? [],
                        library: tagLibrary
                    ) { tags in
                        saveFolderTags(tags, for: folder)
                    }
                    folderRecordButton(folder)
                }
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Tint the row and outline it while a session is dragged over, so the
        // drop target is unmistakable.
        .background(
            targeted ? Theme.accent.opacity(0.12) : (hovered ? Theme.hoverFill : .clear),
            in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.accent, lineWidth: 1.5)
                .opacity(targeted ? 1 : 0))
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .onHover { inside in
            hoveredFolder = inside ? folder : (hoveredFolder == folder ? nil : hoveredFolder)
        }
        .onTapGesture {
            if collapsed { collapsedFolders.remove(folder) } else { collapsedFolders.insert(folder) }
        }
        .contextMenu { folderMenu(folder) }
        // Drop a dragged session row here to file it into this folder (issue #25),
        // highlighting the header while it's the active target. Uses the older
        // `.onDrop`/`NSItemProvider` API, not `.dropDestination`: the latter
        // silently no-ops when its view is a subview of a `List` (issue #28,
        // regressed by the #22 sidebar move to a `.sidebar` List). `.draggable`
        // on the rows is unaffected, so it stays.
        .onDrop(of: [.fileURL, .url], isTargeted: dropTargetBinding(folder)) { providers in
            loadDroppedURLs(providers) { urls in
                fileSessions(urls, to: folder)
            }
            return true
        }
    }

    /// Binding mirroring `dropTargetFolder` for one folder, so `.onDrop`'s
    /// `isTargeted:` can highlight the active drop target. Clears only when *this*
    /// folder loses the drag, so a move to the next folder doesn't blank the new
    /// target set just before it.
    private func dropTargetBinding(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetFolder == folder },
            set: { isIn in
                withAnimation(.easeInOut(duration: 0.12)) {
                    dropTargetFolder = isIn ? folder : (dropTargetFolder == folder ? nil : dropTargetFolder)
                }
            })
    }

    /// Resolve dropped item providers to `URL`s (loaded off the main thread by
    /// `NSItemProvider`), then deliver them on the main actor. The rows' `.onDrag`
    /// vends the session-note file URL as an `NSURL`, so `URL.self` round-trips it.
    private func loadDroppedURLs(_ providers: [NSItemProvider], then handle: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { handle(urls) }
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16).padding(.bottom, 4)
    }

    @ViewBuilder private func folderMenu(_ folder: String) -> some View {
        Button("Rename Folder…") {
            folderRenameText = folder
            renamingFolder = folder
        }
        .disabled(SessionArchive.folderContains(ctx.liveFileURL, folder: folder))
        Button("New Folder…") {
            newFolderName = ""
            fileIntoNewFolder = nil
            creatingFolder = true
        }
        Divider()
        Button("Delete Folder", role: .destructive) { deletingFolder = folder }
            .disabled(SessionArchive.folderContains(ctx.liveFileURL, folder: folder))
    }

    /// Primary action: open (or bring forward) the single recording window. The
    /// ⌘N shortcut is bound globally by `RecordingCommands` (menu bar), so it
    /// isn't re-bound here to avoid a duplicate-binding conflict — the tooltip
    /// carries the hint instead. Clears any pending folder target so this records
    /// into the un-foldered root (issue #35).
    private var newRecordingButton: some View {
        Button {
            TranscriptWindowContext.shared.pendingFolder = nil
            openWindow(id: "recording")
        } label: {
            Label("New Recording", systemImage: "record.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.recordRed)
        }
        .focusEffectDisabled()
        .help("Start a new recording (⌘N)")
    }

    /// A folder header's record button (issue #35): targets this folder for the
    /// next recording and opens the recording window, so the new session's note is
    /// written straight into `<root>/<folder>/` rather than the root.
    private func folderRecordButton(_ folder: String) -> some View {
        Button {
            TranscriptWindowContext.shared.pendingFolder = folder
            openWindow(id: "recording")
        } label: {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.recordRed)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Start a new recording in “\(folder)”")
    }

    /// A plain search field (a `#tag` term filters by tag — see the tooltip), with
    /// the date filter and sort order in a menu at its trailing end.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .help("Search titles, transcripts and cards. Type #tag to filter by tag.")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain).focusEffectDisabled().help("Clear search")
            }
            filterMenu
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 30)
        .background(Theme.fieldFill, in: Capsule())
    }

    /// All / This week and newest / oldest first. The glyph takes the accent while
    /// "This week" hides older sessions, so a filtered list is never mistaken for
    /// the full one.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $thisWeekOnly) {
                Text("All Sessions").tag(false)
                Text("This Week").tag(true)
            }
            .pickerStyle(.inline)
            Picker("Sort", selection: $oldestFirst) {
                Text("Newest First").tag(false)
                Text("Oldest First").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(thisWeekOnly ? Theme.accent : Theme.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled()
        .help(thisWeekOnly ? "Showing this week only" : "Filter and sort")
    }

    @ViewBuilder private func sessionRow(_ session: LoadedSession) -> some View {
        // The owned note can't be filed (its writer owns the path), so it isn't
        // draggable either — mirrors the disabled "Move to Folder" menu.
        // `.onDrag`/`NSItemProvider`, not `.draggable`: inside a `List` the new
        // API never starts the drag from these rows (issue #28), the old one
        // does; it pairs with the `.onDrop` on the folder headers.
        if session.file.url == ctx.liveFileURL {
            sessionRowBody(session)
        } else {
            sessionRowBody(session)
                .onDrag { NSItemProvider(object: session.file.url as NSURL) }
        }
    }

    private func sessionRowBody(_ session: LoadedSession) -> some View {
        let selected = selection == session.id
        let d = session.detail
        // A plain tappable row, not a `Button`: inside a `List` a Button's press
        // gesture swallows the drag so the row won't lift (issue #28). A bare
        // `.onTapGesture` coexists with `.onDrag`.
        let meta = ([d.durationMinutes.map { "\($0) min" }, SessionDetail.cardCount(d.cards.count)] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(d.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(Self.rowTime(d.started ?? session.file.date))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            if !d.gist.isEmpty {
                Text(d.gist).font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            HStack(spacing: 5) {
                tagDots(for: d)
                Text(meta).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? Theme.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { selection = session.id }
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

    /// A coloured dot per tag on a row, named in the tooltip. Only tags still in
    /// the library render — a tag deleted in Preferences disappears here without
    /// rewriting the note.
    @ViewBuilder private func tagDots(for d: SessionDetail) -> some View {
        let known = d.tags.compactMap { name in
            TagLibrary.named(name, in: tagLibrary).map { (name, $0.colorHex) }
        }
        if !known.isEmpty {
            HStack(spacing: 3) {
                ForEach(known, id: \.0) { _, hex in
                    Circle().fill(Color(tagHex: hex)).frame(width: 7, height: 7)
                }
            }
            .help(known.map(\.0).joined(separator: ", "))
        }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        // Resolve against the *filtered* list: a session hidden by search/filter
        // must not stay open in the detail (the Ask bar would append to a
        // transcript no longer in the sidebar).
        if let selected = filtered.first(where: { $0.id == selection }) {
            SessionDetailPane(
                file: selected.file, detail: selected.detail, library: tagLibrary, triggers: triggers)
                .id(selected.id)
        } else {
            Text("Select a session to read it.")
                .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: data

    private func reload() {
        let config = AdvisorConfig.load()
        tagLibrary = config.tags
        savedContexts = config.contexts
        triggers = config.triggers
        folders = SessionArchive.folders()
        folderContexts = folders.reduce(into: [:]) { $0[$1] = SessionArchive.folderContext($1) }
        folderTags = folders.reduce(into: [:]) {
            $0[$1] = SessionArchive.folderTags($1).filter {
                TagLibrary.named($0, in: tagLibrary) != nil
            }
        }
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
        guard SessionArchive.renameFolder(from: old, to: new, excluding: ctx.liveFileURL)
        else { return }
        collapsedFolders.remove(old)
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Save (or clear) a folder's context (issue #36). Updates the in-memory map so
    /// the header button's state reflects it at once; no reload needed since the
    /// context isn't shown in the session list. The next recording started in this
    /// folder inherits the text.
    private func saveFolderContext(_ text: String, for folder: String) {
        SessionArchive.setFolderContext(text, for: folder)
        folderContexts[folder] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save the tags inherited by recordings started from this folder (issue #76).
    /// Canonicalise through the archive formatter so the button immediately shows
    /// the same de-duplicated list that will be read back from disk.
    private func saveFolderTags(_ tags: [String], for folder: String) {
        guard SessionArchive.setFolderTags(tags, for: folder) else { return }
        folderTags[folder] = SessionArchive.parseTags(SessionArchive.tagsLine(tags))
    }

    /// Delete a folder; its sessions are un-filed back to the root, not deleted.
    private func deleteFolder(_ folder: String) {
        guard SessionArchive.deleteFolder(folder, excluding: ctx.liveFileURL) else { return }
        collapsedFolders.remove(folder)
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Filtered + sorted sessions (search + this-week chip + sort order).
    private var filtered: [LoadedSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        return sessions
            .filter { SessionSearch.matches(query: q, tags: $0.detail.tags, haystack: $0.haystack) }
            // Calendar week, matching the sidebar's Today / Yesterday / Earlier
            // this week grouping — not a rolling 7 days, which would disagree
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
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let now = Date()
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "Earlier this week" }
        if cal.isDate(date, equalTo: now, toGranularity: .month) { return "This month" }
        return "Earlier"
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

// MARK: - Folder context button (issue #36)

/// A folder header's context button, left of the record button: opens a popover to
/// edit the folder's context — the seed every recording started in this folder
/// inherits. The filled glyph shows a context is set.
/// Owns its popover/draft state so each folder row gets an independent editor.
private struct FolderContextButton: View {
    let folder: String
    /// The folder's current saved context, for the tinted state and seeding the draft.
    let context: String
    /// The saved-contexts library, offered by the popover's Load menu.
    let library: [SavedContext]
    let onSave: (String) -> Void
    @State private var show = false
    @State private var draft = ""

    private var hasContext: Bool { !context.isEmpty }

    var body: some View {
        Button {
            draft = context
            show = true
        } label: {
            Image(systemName: hasContext ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(hasContext ? "Edit context for “\(folder)”" : "Set context for “\(folder)”")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Folder context").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text("Seeds the context of every recording started in “\(folder)”. "
                    + "Editable per session.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $draft)
                    .font(.system(size: 12.5))
                    .frame(width: 320, height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
                HStack {
                    SavedContextMenu(contexts: library) { draft = $0.text }
                    Spacer()
                    Button("Save") {
                        onSave(draft)
                        show = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Folder tags button (issue #76)

/// A folder header's tag button: edits the defaults inherited by new recordings
/// started in the folder. Existing sessions and sessions moved into it are unchanged.
private struct FolderTagsButton: View {
    let folder: String
    let tags: [String]
    let library: [SavedTag]
    let onChange: ([String]) -> Void
    @State private var show = false

    private var hasTags: Bool { !tags.isEmpty }

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: hasTags ? "tag.fill" : "tag")
                    .font(.system(size: 11))
                if hasTags {
                    Text("\(tags.count)")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(hasTags ? "Edit tags for “\(folder)”" : "Set tags for “\(folder)”")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            SessionTagsEditor(tags: tags, library: library, onChange: onChange)
        }
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

/// The Answer panel's request in flight — an Ask or a Summarise on the saved
/// note — kept so it can be stopped.
private struct AnswerRequest {
    /// The sidecar request id.
    let id: String
    /// The question asked, to put back in the field if stopped; nil for a Summarise.
    let question: String?
}

/// A follow-up streaming into a saved card.
private struct SavedReply {
    /// The card's body with the follow-up turn so far.
    var body: String
    /// The sidecar request, so deleting the card can stop it.
    var requestId: String?
    /// Finished but couldn't be saved — kept on screen so it can be copied.
    var unsaved = false
}

/// A research card asked for on a saved transcript, while it streams.
private struct SavedResearch {
    var card: Card
    /// The transcript line it will be saved under, and the paragraph's block
    /// offset when it was asked — together they find the paragraph to show it
    /// under as other edits shift offsets.
    let anchor: NoteEdit.Anchor
    let paragraphOffset: Int
    /// The sidecar request, for Skip and Delete.
    let requestId: String
}

/// The right-hand detail: a selected session rendered like the live window —
/// header + meta, the cards it surfaced, the questions asked of it, and the full
/// transcript — with the ask bar kept (answers append to the note on disk).
private struct SessionDetailPane: View {
    let file: SessionFile
    let detail: SessionDetail
    /// The tag library, for the Tags chip's autocomplete and pill colours.
    let library: [SavedTag]
    /// Which right-click research actions Preferences allows.
    let triggers: AdvisorConfig.Triggers
    /// The note as feed items and its card/note ids, built once per `detail`
    /// rather than on every redraw — streaming answers redraw many times a second.
    private let savedItems: [FeedItem]
    private let blockIds: [String?]

    init(file: SessionFile, detail: SessionDetail, library: [SavedTag], triggers: AdvisorConfig.Triggers) {
        self.file = file
        self.detail = detail
        self.library = library
        self.triggers = triggers
        savedItems = Feed.saved(blocks: detail.blocks, times: detail.blockTimes)
        blockIds = Feed.savedIds(detail.blocks)
    }

    @ObservedObject private var ctx = TranscriptWindowContext.shared

    // Ask state.
    @State private var question = ""
    @State private var answerBody = ""
    @State private var answerState = "" // "" idle, else pending|streaming|done|failed
    @State private var askNote = ""
    /// True while the in-flight `liveAnswer` is a summary rather than a Q&A, so its
    /// header reads "Summary" (issue #30). The Ask path clears it.
    @State private var summarising = false
    /// The Ask or Summarise in flight, so the panel's stop button can end it.
    @State private var answerRequest: AnswerRequest?

    /// Experiment: hide transcript paragraphs/headings so only cards show.
    @State private var hideTranscript = false
    /// Cards the user expanded or collapsed, by card id (`Feed.savedIds`, which
    /// follow the content); the rest keep their default (fact-checks collapsed).
    /// View state only, like the recording window's — it never touches the note.
    @State private var expansion: [String: Bool] = [:]
    /// Research cards asked for on this note's transcript, shown under their
    /// paragraph until the finished card is saved into the note.
    @State private var research: [SavedResearch] = []
    /// Follow-ups streaming into saved cards, by card id.
    @State private var replies: [String: SavedReply] = [:]

    // Rename state.
    @State private var renaming = false
    @State private var renameText = ""

    // Delete confirmation.
    @State private var confirmingDelete = false

    @State private var editingTags = false

    private var isAsking: Bool { answerState == "pending" || answerState == "streaming" }
    /// Asking the still-being-written live note is disabled (the writer's
    /// debounced rewrite would clobber an appended follow-up).
    private var isLive: Bool { file.url == ctx.liveFileURL }

    var body: some View {
        // A centred reading column; the ask field floats over the bottom of it,
        // with the content scrolling underneath.
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if !detail.questions.isEmpty { youAsked }
                transcript
            }
            .frame(maxWidth: Theme.Metric.readingWidth, alignment: .leading)
            .padding(.horizontal, Theme.Metric.readingMargin)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .toolbar {
            // The detail's items otherwise sit at its leading edge, beside the
            // sidebar, where they're easy to miss; a flexible spacer pushes them
            // to the trailing edge, where the recording window keeps its controls.
            ToolbarSpacer(.flexible)
            ToolbarItemGroup {
                hideTranscriptButton
                summariseButton
                tagsButton
                moreMenu
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.system(size: 24, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(Theme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
            Text(metaLine).font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
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
    /// meta line. Editing is via the toolbar's Tags button.
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

    /// Toggle the transcript off so the detail shows only cards (experiment).
    private var hideTranscriptButton: some View {
        Button { hideTranscript.toggle() } label: {
            Label(
                hideTranscript ? "Show Transcript" : "Hide Transcript",
                systemImage: hideTranscript ? "eye.slash" : "eye")
        }
        .focusEffectDisabled()
        .help(hideTranscript ? "Show transcript" : "Hide transcript (cards only)")
    }

    /// Edit the session's tags in a popover anchored to the toolbar.
    private var tagsButton: some View {
        Button { editingTags.toggle() } label: {
            Label("Tags", systemImage: detail.tags.isEmpty ? "tag" : "tag.fill")
        }
        .focusEffectDisabled()
        .help("Session tags")
        .popover(isPresented: $editingTags, arrowEdge: .bottom) {
            SessionTagsEditor(tags: detail.tags, library: library, onChange: applyTags)
        }
    }

    private var moreMenu: some View {
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
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .help("Rename, export, share or delete")
    }

    /// Add or update this session's Summary card (issue #30). Disabled while the
    /// note is still being recorded (its writer would clobber the upsert) or while
    /// an ask/summary is already streaming — mirrors the ask bar's gating.
    private var summariseButton: some View {
        Button(action: submitSummarise) {
            Label("Summarise", systemImage: "list.bullet.rectangle")
        }
        .focusEffectDisabled()
        .disabled(isLive || isAsking)
        .help(isLive
            ? "Summarise once the session has fully saved"
            : "Summarise this conversation (adds or updates a Summary card)")
    }

    /// Summarise the whole saved transcript into its single `# Summary` section,
    /// replacing any existing one. Streams into the answer strip, then persists on
    /// disk and refreshes the browser so the summary card shows.
    private func submitSummarise() {
        guard !isAsking, !isLive else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }

        askNote = ""
        summarising = true
        answerBody = "…"
        answerState = "pending"
        let document = SessionArchive.contents(of: file)

        let sent = sidecar.summariseDocument(transcript: document) { body, state in
            answerBody = body
            answerState = state
            if !isAsking { answerRequest = nil }
            if state == "done" {
                // Issue #51: only clear and reload once the summary is on disk. On
                // failure keep it visible (leave answerBody / answerState) so it
                // isn't lost, and don't post — but still drop `summarising` so the
                // UI isn't stuck.
                if SessionArchive.save(to: file, { SessionArchive.upsertSummary(body, to: $0) }) {
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                    answerBody = ""
                    answerState = ""
                    summarising = false
                } else {
                    askNote = "Summary couldn't be saved to disk."
                    summarising = false
                }
            }
        }
        if let sent {
            answerRequest = AnswerRequest(id: sent, question: nil)
        } else {
            askNote = "Sidecar not running — summary not requested."
            answerBody = ""
            answerState = ""
            summarising = false
        }
    }

    /// Stop the Ask or Summarise in flight: the sidecar request is dropped (its
    /// handler too, so nothing late can save it), the panel closes, and an Ask's
    /// question goes back in the field (it is disabled while asking, so empty).
    /// Nothing reaches the note.
    private func cancelAnswer() {
        guard let request = answerRequest else { return }
        ctx.sidecar?.discardDocumentRequest(request.id)
        answerRequest = nil
        if let asked = request.question { question = asked }
        answerBody = ""
        answerState = ""
        summarising = false
        askNote = ""
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
            NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
        } else if SessionArchive.setTags(tags, in: file) {
            NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
        } else {
            // Issue #51: the write failed — surface it and don't post the change
            // notification, which would reload from disk and show the OLD tags as
            // if nothing had changed.
            askNote = "Couldn't save tags to disk."
        }
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
        return parts.joined(separator: " · ")
    }

    // MARK: you asked

    private var youAsked: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedSectionLabel(
                title: "You asked",
                count: detail.questions.count == 1 ? "1 question" : "\(detail.questions.count) questions")
            ForEach(Array(detail.questions.enumerated()), id: \.offset) { _, q in
                HStack(alignment: .top, spacing: 10) {
                    Text("Y").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.fieldFill, in: Circle())
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

    /// The saved note in the shared feed — the same rows and controls as the
    /// recording window, with this note's actions.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: FeedView.spacing) {
            FeedSectionLabel(title: hideTranscript ? "Cards" : "Transcript")
            FeedView(
                items: Feed.mapCards(Feed.applyingExpansion(
                    expansion,
                    to: Feed.grouped(
                        Feed.inserting(
                            research.map { pending in
                                let paragraph = NoteEdit.paragraphOffset(
                                    endingWith: pending.anchor.line, near: pending.paragraphOffset,
                                    in: detail.blocks)
                                return (afterParagraph: paragraph.map(String.init) ?? "", card: pending.card)
                            },
                            into: savedItems),
                        hideTranscript: hideTranscript))) { card in
                    if let reply = replies[card.id] {
                        card.body = reply.body
                        card.state = reply.unsaved ? "done" : "streaming"
                        card.replying = true
                    }
                    // A finished research card that couldn't be saved has no place
                    // in the note to take a follow-up.
                    if card.state == "done", research.contains(where: { $0.card.id == card.id }) {
                        card.replying = true
                    }
                },
                actions: feedActions)
        }
    }

    /// What a saved note allows. The live note is still owned by its writer, so
    /// edits here would be clobbered — it stays read-only until saved (collapse
    /// is view state, so it's always allowed).
    private var feedActions: FeedActions {
        FeedActions(
            transcriptActions: isLive ? [] : TranscriptAction.research(for: triggers),
            onAction: { kind, selection, paragraph in startResearch(kind, on: selection, in: paragraph) },
            onAddNote: isLive
                ? nil
                : { text, offset, paragraph in
                    guard let block = Int(paragraph.id) else { return }
                    finishEdit(SessionArchive.insertNote(
                        text, inParagraphAt: block, expecting: detail.blocks[block], atCharacter: offset,
                        in: file))
                },
            onCorrect: isLive
                ? nil
                : { request, paragraph in
                    // Saved paragraph ids are their block offsets.
                    guard let offset = Int(paragraph.id) else { return }
                    apply(request, toParagraph: paragraphOrdinal(before: offset))
                },
            onToggleCard: { card in expansion[card.id] = !card.isExpanded },
            onDeleteCard: isLive ? nil : { card in deleteBlock(id: card.id) },
            onCancelCard: { card in
                // Skip: drop the handler too, so a finish already on its way can't
                // save the card; it stays, marked skipped, until deleted.
                guard let index = research.firstIndex(where: { $0.card.id == card.id }) else { return }
                ctx.sidecar?.discardDocumentRequest(research[index].requestId)
                research[index].card.state = "cancelled"
            },
            onReply: isLive ? nil : { card, question in startReply(on: card, question) },
            onDeleteNote: isLive ? nil : { id in deleteBlock(id: id) })
    }

    /// Remove a card or note from the note on disk — or, for a research card not
    /// saved yet, stop it and drop it.
    private func deleteBlock(id: String) {
        if let pending = research.first(where: { $0.card.id == id }) {
            // Drop its handler too, so a finish already on its way can't save it.
            ctx.sidecar?.discardDocumentRequest(pending.requestId)
            research.removeAll { $0.card.id == id }
            return
        }
        // A follow-up still streaming into this card has nowhere to go now.
        if let reply = replies.removeValue(forKey: id), let request = reply.requestId {
            ctx.sidecar?.discardDocumentRequest(request)
        }
        guard let offset = blockIds.firstIndex(of: id) else { return }
        finishEdit(SessionArchive.removeBlock(at: offset, expecting: detail.blocks[offset], from: file))
    }

    /// Research `selection` from the paragraph it's in (right-click Answer /
    /// Context / Fact check). The card streams in under the paragraph and, once
    /// done, is saved into the note under the paragraph's last line — where the
    /// live feed anchors a manual card. A failed or skipped card stays until
    /// deleted, and isn't saved.
    private func startResearch(_ kind: String, on selection: String, in paragraph: FeedParagraph) {
        guard let offset = Int(paragraph.id), detail.blocks.indices.contains(offset) else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }
        let document = SessionArchive.contents(of: file)
        guard let anchor = NoteEdit.anchor(ofParagraphAt: offset, expecting: detail.blocks[offset], in: document)
        else { return finishEdit(false) }

        let card = Card(
            id: "research-\(UUID().uuidString)", created: Date(), kind: kind, title: selection,
            body: "…", state: "pending",
            footnote: kind == "answer" ? SavedCard.savedGroundedNote : nil,
            isExpanded: kind != "factcheck")
        let file = file
        let request = sidecar.researchDocument(action: kind, text: selection, document: document) { body, state in
            // Save first, from captured values: the user may have moved to another
            // session, taking this pane's state with it.
            if state == "done" {
                var done = card
                done.body = body
                done.state = state
                if SessionArchive.save(to: file, { SessionArchive.insertBlock(SessionMarkdown.cardBlock(done), after: anchor, in: $0) }) {
                    research.removeAll { $0.card.id == card.id }
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                    return
                }
                // Only an unreadable note or a failed write gets here.
                askNote = "Couldn't save the card to the note — copy it before navigating away."
            }
            guard let index = research.firstIndex(where: { $0.card.id == card.id }) else { return }
            research[index].card.body = body
            research[index].card.state = state
        }
        guard let request else { askNote = "Sidecar not running — not sent."; return }
        research.append(SavedResearch(card: card, anchor: anchor, paragraphOffset: offset, requestId: request))
    }

    /// Ask a follow-up on a saved card. The answer streams into the card in the
    /// live turn format and, once done, the card's body is rewritten in the note.
    /// A failed or skipped follow-up leaves the note as it was.
    private func startReply(on card: Card, _ question: String) {
        guard replies[card.id] == nil else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }
        let base = card.body
        let file = file
        let request = sidecar.replyDocument(
            kind: card.kind, title: card.title, base: base, replyText: question,
            document: SessionArchive.contents(of: file)
        ) { answer, state in
            let body = SessionMarkdown.replyBody(base: base, question: question, answer: answer)
            switch state {
            case "done":
                // Save first, from captured values: the user may have moved on.
                if SessionArchive.save(to: file, { SessionArchive.replaceCardBody(ofCard: card.id, body: base, with: body, in: $0) }) {
                    replies[card.id] = nil
                    // The new body gives the card a new id; keep it open, as it
                    // was to take the follow-up (a fact-check would otherwise shut).
                    let saved = SessionArchive.relocated(file) ?? file
                    if let newId = NoteEdit.cardId(withBody: body, in: SessionArchive.contents(of: saved)) {
                        expansion[newId] = true
                    }
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                } else {
                    replies[card.id]?.body = body
                    replies[card.id]?.unsaved = true
                    askNote = "Couldn't save the follow-up to the note — copy it before navigating away."
                }
            case "failed":
                replies[card.id] = nil
                askNote = "The follow-up didn't complete — \(answer)"
            case "cancelled":
                replies[card.id] = nil
            default:
                replies[card.id]?.body = body
            }
        }
        guard let request else { askNote = "Sidecar not running — follow-up not sent."; return }
        replies[card.id] = SavedReply(
            body: SessionMarkdown.replyBody(base: base, question: question, answer: "…"), requestId: request)
    }

    /// After an edit to the note on disk, refresh the list cache (and so this
    /// pane's `detail`) either way: an edit that didn't apply usually means the
    /// note changed underneath us, so the reload shows what's there now.
    private func finishEdit(_ applied: Bool) {
        if !applied {
            askNote = Self.editFailed
        } else if askNote == Self.editFailed {
            askNote = ""
        }
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    private static let editFailed = "Couldn't update the note — it may have changed on disk, so it has been reloaded."

    /// The 0-based index of the paragraph at block `offset` among paragraph blocks
    /// only — the index `TranscriptCorrection` keys on (it groups paragraphs the
    /// same way `TranscriptDoc` does, skipping cards and headings) (issue #32).
    private func paragraphOrdinal(before offset: Int) -> Int {
        detail.blocks[..<offset].reduce(0) {
            if case .paragraph = $1 { return $0 + 1 }
            return $0
        }
    }

    /// Apply a transcription correction to the saved note on disk, then refresh
    /// the parent list cache (and so this pane's `detail`) so the edit shows.
    private func apply(_ request: TranscriptCorrectionRequest, toParagraph paragraphIndex: Int) {
        let changed: Bool
        switch request.scope {
        case .thisOccurrence:
            changed = SessionArchive.correctOccurrence(
                request.occurrenceInParagraph, of: request.original, with: request.replacement,
                inParagraph: paragraphIndex, of: file)
        case .allInSession:
            changed = SessionArchive.correctAll(
                of: request.original, with: request.replacement, in: file)
        }
        if changed { NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil) }
    }

    // MARK: ask

    /// The streaming answer (or summary) card, the ask field, and any error,
    /// floating over the bottom of the reading column. The page fades out under
    /// it so scrolled text doesn't collide with the field.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // While running, even before any text, so Stop is always there.
            if isAsking || !answerBody.isEmpty { liveAnswer }
            askField
            if !askNote.isEmpty {
                Text(askNote).font(.system(size: 11.5)).foregroundStyle(Theme.factRed)
                    .padding(.leading, 18)
            }
        }
        .frame(maxWidth: Theme.Metric.readingWidth)
        .padding(.horizontal, Theme.Metric.readingMargin)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Theme.surfaceWindow.opacity(0), location: 0),
                    .init(color: Theme.surfaceWindow, location: 0.45),
                ],
                startPoint: .top, endPoint: .bottom))
    }

    private var liveAnswer: some View {
        AnswerPanel(
            title: answerState == "failed"
                ? (summarising ? "Couldn't summarise" : "Couldn't answer")
                : (summarising ? "Summary" : "Answer"),
            titleColor: answerState == "failed"
                ? Theme.factRed
                : (summarising ? Theme.summaryTeal : Theme.accent),
            markdown: answerBody,
            isRunning: isAsking,
            stop: answerRequest == nil ? nil : cancelAnswer,
            stopHelp: summarising ? "Stop summarising" : "Stop answering")
    }

    private var canAsk: Bool {
        !isLive && !isAsking && !question.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One rounded glass field with an inline send arrow that takes the accent
    /// once there's a question to send.
    private var askField: some View {
        HStack(spacing: 8) {
            TextField(
                isLive
                    ? "Advisor is still writing this session — ask once it has fully saved"
                    : "Ask about this session",
                text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .onSubmit(submitQuestion)
                .disabled(isLive || isAsking)
            Button(action: submitQuestion) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canAsk ? Theme.onAccent : Theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(canAsk ? Theme.accent : Theme.fieldFill, in: Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!canAsk)
            .help("Ask (↩)")
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .frame(height: 42)
        .glassEffect(.regular, in: Capsule())
    }

    private func submitQuestion() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking, !isLive else { return }
        guard let sidecar = ctx.sidecar else { askNote = "Sidecar not running."; return }

        askNote = ""
        summarising = false
        answerBody = "…"
        answerState = "pending"
        let document = SessionArchive.contents(of: file)

        let sent = sidecar.askDocument(question: q, document: document) { body, state in
            answerBody = body
            answerState = state
            if !isAsking { answerRequest = nil }
            if state == "done" {
                // Issue #51: only clear the answer and reload once the append is
                // on disk. On failure keep the answer visible (leave answerBody /
                // answerState as they are) so the Q&A isn't lost, and don't post —
                // a reload would drop the unsaved answer.
                if SessionArchive.save(to: file, { SessionArchive.appendFollowUp(question: q, answer: body, to: $0) }) {
                    // Refresh the parent list cache (and so this pane's `detail`),
                    // not just a pane-local copy, or the appended Q&A would vanish on
                    // navigating away and back or via search.
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                    answerBody = ""
                    answerState = ""
                } else {
                    askNote = "Answer couldn't be saved to disk — copy it before navigating away."
                }
            }
        }
        guard let sent else {
            askNote = "Sidecar not running — question not sent."
            answerBody = ""
            answerState = ""
            return
        }
        answerRequest = AnswerRequest(id: sent, question: q)
        question = ""
    }
}
