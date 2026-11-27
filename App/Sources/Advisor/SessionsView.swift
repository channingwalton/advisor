import AppKit
import SwiftUI

/// A saved session paired with its parsed detail, the unit the browser lists.
struct LoadedSession: Identifiable, Equatable {
    let file: SessionFile
    let detail: SessionDetail
    var id: URL { file.url }

    /// Lowercased haystack for search (title, gist, transcript, card titles).
    let haystack: String
}

/// The Sessions browser: a master/detail window over saved session notes. Left:
/// search + filters + a date-grouped list. Right: the selected session rendered
/// like the live window (header, cards surfaced, questions asked, transcript)
/// with Ask and Note kept. Replaces the old picker + per-session windows.
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

    /// The folder paths in the archive (issues #25, #155), such as
    /// `Work/Client A`, derived from disk sub-directories in tree order.
    /// Refreshed alongside `sessions` on appear and on session changes.
    @State private var folders: [String] = []
    /// Folders the user has collapsed. Absence = expanded, so new folders default
    /// open. Kept in view state only (resets per window open), like the selection.
    /// A collapsed folder also hides its subfolders.
    @State private var collapsedFolders: Set<String> = []
    // Folder create/rename/delete are driven from the sidebar inline.
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    /// The folder that a new folder goes inside (issue #155), from a folder's
    /// "New Folder Inside…"; nil for a top-level folder.
    @State private var newFolderParent: String?
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
    /// Reloads the list when another app changes the session folder (issue
    /// #133). It runs while the view shows, and each reload points it at the
    /// current folder.
    @State private var folderWatch: SessionFolderWatch?
    /// The session folder that the last `reload` listed (issue #159).
    @State private var listedFolder = ListedFolder()

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
        .onAppear {
            // The closures capture nothing from the view: the watch, held in
            // the view's state, must not keep the view alive.
            if folderWatch == nil {
                folderWatch = SessionFolderWatch(ignoring: { TranscriptWindowContext.shared.liveFileURL }) { _ in
                    NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
                }
            }
            reload()
        }
        .onDisappear {
            folderWatch?.stop()
            folderWatch = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .advisorSessionsChanged)) { _ in
            reload()
        }
        // Tag library edits in Preferences (rename, recolour, delete) must
        // recolour/hide pills and refresh folder defaults without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: .advisorConfigChanged)) { _ in
            // A file that cannot be used leaves the browser as it is.
            guard let config = AdvisorConfig.loadIfUsable() else { return }
            // A session folder changed in Preferences lists the new folder,
            // and the reload moves the watch there (issue #159).
            if listedFolder.changes(to: config) {
                reload(config)
                return
            }
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
                createFolder(named: newFolderName, inside: newFolderParent, fileIn: fileIntoNewFolder)
                fileIntoNewFolder = nil
                newFolderParent = nil
            }
            Button("Cancel", role: .cancel) {
                fileIntoNewFolder = nil
                newFolderParent = nil
            }
        } message: {
            if let parent = newFolderParent {
                Text("Name the new folder inside “\(FolderTree.displayPath(parent))”. "
                    + "It starts with a copy of that folder's context and tags.")
            } else {
                Text("Name the new folder.")
            }
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
            Text(Self.deleteFolderMessage(folder))
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
                // (the same reason `foldersBar`'s + button works). Each level of
                // subfolder (issue #155) indents one step.
                ForEach(FolderTree.layout(visibleFolders), id: \.self) { entry in
                    switch entry {
                    case .header(let folder):
                        folderHeader(folder).plainSidebarRow()
                    case .sessions(let folder):
                        if !collapsedFolders.contains(folder) {
                            ForEach(sessions(in: folder)) { session in
                                sessionRow(session)
                                    .padding(.leading, 16 + Self.folderIndent(folder))
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
                newFolderParent = nil
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
        let count = FolderTree.sessionCount(of: folder, in: filtered.map(\.file.folder))
        let targeted = dropTargetFolder == folder
        let hovered = hoveredFolder == folder
        return HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                .frame(width: 10)
            Image(systemName: targeted ? "folder.fill" : "folder")
                .font(.system(size: 12)).foregroundStyle(targeted ? Theme.accent : Theme.textSecondary)
            Text(SessionArchive.folderName(folder)).font(.system(size: 13))
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
        .padding(.leading, Self.folderIndent(folder))
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

    /// How far a folder's header and sessions indent: one step for each folder
    /// that holds it (issue #155).
    private static func folderIndent(_ folder: String) -> CGFloat {
        CGFloat(SessionArchive.folderDepth(folder)) * 14
    }

    /// The delete confirmation names where the folder's contents go: its parent
    /// (issue #155), or out of all folders for a top-level folder.
    private static func deleteFolderMessage(_ folder: String) -> String {
        let name = SessionArchive.folderName(folder)
        if let parent = SessionArchive.parentFolder(folder) {
            return "Delete the folder “\(name)”? Its sessions and folders move into "
                + "“\(FolderTree.displayPath(parent))” and are kept."
        }
        return "Delete the folder “\(name)”? Its sessions move back out and are kept, "
            + "and its folders become top-level folders."
    }

    @ViewBuilder private func folderMenu(_ folder: String) -> some View {
        Button("Rename Folder…") {
            folderRenameText = SessionArchive.folderName(folder)
            renamingFolder = folder
        }
        .disabled(SessionArchive.folderContains(ctx.liveFileURL, folder: folder))
        Button("New Folder Inside…") {
            newFolderName = ""
            fileIntoNewFolder = nil
            newFolderParent = folder
            creatingFolder = true
        }
        Button("New Folder…") {
            newFolderName = ""
            fileIntoNewFolder = nil
            newFolderParent = nil
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
        .help("Start a new recording in “\(FolderTree.displayPath(folder))”")
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
        if SessionArchive.isSameNote(session.file.url, ctx.liveFileURL) {
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
        Button("Export…") { exportSessionCopy(session.file) }
        ShareLink("Share…", item: session.file.url, preview: SharePreview(session.detail.title))
        // The live note is exempt: see `openSessionInDefaultApp`.
        Button("Open in Default App") { openSessionInDefaultApp(session.file) }
            .disabled(SessionArchive.isSameNote(session.file.url, ctx.liveFileURL))
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.file.url])
        }
        Divider()
        // The live note is exempt: its writer would just recreate the deleted file.
        Button("Delete…", role: .destructive) { deleting = session }
            .disabled(SessionArchive.isSameNote(session.file.url, ctx.liveFileURL))
    }

    /// "Move to Folder" submenu (issue #25): existing folders, "No Folder" to
    /// un-file, and "New Folder…" to create-and-file. A folder with subfolders is
    /// a submenu of its own (issue #155). Disabled for the live/owned
    /// note — filing it would move the file out from under its writer (mirrors the
    /// Delete exemption and the #16 storage move, which also skip the live note).
    @ViewBuilder private func moveToFolderMenu(_ session: LoadedSession) -> some View {
        Menu("Move to Folder") {
            if session.file.folder != nil {
                Button("No Folder") { fileSession(session, to: nil) }
                Divider()
            }
            FolderMenuItems(parent: nil, folders: folders, current: session.file.folder) { folder in
                fileSession(session, to: folder)
            }
            if !folders.isEmpty { Divider() }
            Button("New Folder…") {
                newFolderName = ""
                fileIntoNewFolder = session
                newFolderParent = nil
                creatingFolder = true
            }
        }
        .disabled(SessionArchive.isSameNote(session.file.url, ctx.liveFileURL))
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
        // must not stay open in the detail (Ask would append to a transcript no
        // longer in the sidebar).
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

    /// Read the list from the folder that `config` names, and point the watch
    /// at it. The default is the lenient `load()` (issue #137), which also
    /// gives `SessionArchive.directory`: the in-app actions and the writer use
    /// that folder, so the list shows it.
    private func reload(_ config: AdvisorConfig = AdvisorConfig.load()) {
        tagLibrary = config.tags
        savedContexts = config.contexts
        triggers = config.triggers
        let directory = listedFolder.list(config)
        folderWatch?.watch(directory)
        let scan = SessionArchive.scan(directory)
        folders = scan.folders
        folderContexts = folders.reduce(into: [:]) { $0[$1] = SessionArchive.folderContext($1, root: directory) }
        folderTags = folders.reduce(into: [:]) {
            $0[$1] = SessionArchive.folderTags($1, root: directory).filter {
                TagLibrary.named($0, in: tagLibrary) != nil
            }
        }
        sessions = scan.notes.map { file in
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
        guard !SessionArchive.isSameNote(session.file.url, ctx.liveFileURL) else { return }
        if let moved = SessionArchive.setFolder(folder, for: session.file) {
            if selection == session.file.url { selection = moved.url }
        }
        NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
    }

    /// Create `name`, inside `parent` when set (issue #155: the new folder takes
    /// a copy of the parent's context and tags); if `session` is set (from a
    /// row's "New Folder…"), file it in.
    private func createFolder(named name: String, inside parent: String?, fileIn session: LoadedSession?) {
        guard SessionArchive.createFolder(name, inside: parent) else { return }
        if let parent { collapsedFolders = FolderTree.expanding(collapsedFolders, toShow: parent) }
        if let session, let leaf = SessionArchive.sanitiseFolderName(name) {
            let folder = parent.map { "\($0)/\(leaf)" } ?? leaf
            fileSession(session, to: folder) // posts the reload notification
        } else {
            NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
        }
    }

    /// Rename a folder (its notes travel with the directory). Selection may reset
    /// to the first visible session if it pointed inside the folder, since those
    /// notes' URLs change — reload reconciles it.
    private func renameFolder(_ old: String, to new: String) {
        guard SessionArchive.renameFolder(from: old, to: new, excluding: ctx.liveFileURL),
            let name = SessionArchive.sanitiseFolderName(new)
        else { return }
        let renamed = SessionArchive.parentFolder(old).map { "\($0)/\(name)" } ?? name
        collapsedFolders = FolderTree.renaming(collapsedFolders, from: old, to: renamed)
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

    /// Delete a folder; its sessions and subfolders move into its parent, not
    /// deleted. The delete is all or nothing (`SessionArchive.deleteFolder`),
    /// and a refused delete says why it can be refused, so the folder does not
    /// stay with no reason given.
    private func deleteFolder(_ folder: String) {
        guard SessionArchive.deleteFolder(folder, excluding: ctx.liveFileURL) else {
            NotificationCenter.default.post(name: .advisorSessionsChanged, object: nil)
            let parent = SessionArchive.parentFolder(folder).map { "“\(FolderTree.displayPath($0))”" }
                ?? "the top level"
            // After the confirmation alert has closed, not inside its action.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't delete “\(SessionArchive.folderName(folder))”"
                alert.informativeText = "The folder was not deleted. A session or folder in it may "
                    + "have the same name as one in \(parent), the folder may hold something that is "
                    + "not a session or a folder (it can be hidden), or a file in it may be locked. "
                    + "Finder shows what is in the folder."
                alert.runModal()
            }
            return
        }
        collapsedFolders = FolderTree.removing(collapsedFolders, folder: folder)
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

    /// Filtered sessions that sit directly in `folder`, in sort order (folders
    /// show a flat list, not date-grouped — date grouping is for the un-foldered
    /// area).
    private func sessions(in folder: String) -> [LoadedSession] {
        filtered.filter { $0.file.folder == folder }
    }

    /// Which folders to show (`FolderTree.visible`): all of them when unfiltered
    /// (so empty folders still appear and can be managed), only folders with a
    /// match in them or in a subfolder when searching, and no subfolder of a
    /// collapsed folder.
    private var visibleFolders: [String] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return FolderTree.visible(
            folders, collapsed: collapsedFolders,
            matching: searching ? Set(filtered.compactMap(\.file.folder)) : nil)
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

// MARK: - Move to Folder menu (issue #155)

/// The folders inside `parent` for the Move to Folder menu. A folder with
/// subfolders is a submenu: its first item files into the folder itself, and
/// its subfolders follow. `AnyView` breaks the recursion of the view type.
private struct FolderMenuItems: View {
    let parent: String?
    let folders: [String]
    let current: String?
    let file: (String) -> Void

    var body: some View {
        ForEach(FolderTree.children(of: parent, in: folders), id: \.self) { folder in
            let name = SessionArchive.folderName(folder)
            if FolderTree.children(of: folder, in: folders).isEmpty {
                Button(name) { file(folder) }.disabled(folder == current)
            } else {
                Menu(name) {
                    Button(name) { file(folder) }.disabled(folder == current)
                    Divider()
                    AnyView(FolderMenuItems(parent: folder, folders: folders, current: current, file: file))
                }
            }
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
