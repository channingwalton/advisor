import CoreServices
import Foundation

/// Watches the session folder, at every depth, for a change that another app
/// makes (issue #133), such as an edit to a note opened with Open in Default
/// App. An FSEvents stream, with these settings:
///
/// - It ignores the changes that this process makes
///   (`kFSEventStreamCreateFlagIgnoreSelf`). An in-app action posts
///   `advisorSessionsChanged`, and the live writer's rewrites do not reload
///   the browser, as before.
/// - It ignores the live note (`ignoring`). The writer rewrites it from
///   memory, so another app's change to it does not last. An FSEvents event
///   can carry the flags of earlier changes to its path, so a sync client's
///   attribute change can look like the writer's rewrite.
/// - It gives the changes after a 0.5 s latency, so a run of saves comes as
///   one batch.
/// - It reports only a change that the browser can show (`reports`).
///
/// The callbacks run on the main queue, and `onChange` runs on the turn
/// after the stream's callback.
@MainActor
final class SessionFolderWatch {
    private let ignoring: () -> URL?
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?
    /// The resolved folder that `stream` watches.
    private var folder: URL?

    /// `ignoring` gives the live note at each batch. `onChange` gets the
    /// reported paths of each batch.
    init(ignoring: @escaping () -> URL? = { nil }, onChange: @escaping ([String]) -> Void) {
        self.ignoring = ignoring
        self.onChange = onChange
    }

    isolated deinit { stop() }

    /// Watch `folder`, and stop a watch on another folder. A call for the
    /// folder that it watches already changes nothing.
    func watch(_ folder: URL) {
        let resolved = SessionArchive.resolvedFolder(folder)
        guard stream == nil || resolved != self.folder else { return }
        stop()
        // The stream releases the target when it is released; with no stream,
        // the target is released here.
        let target = Unmanaged.passRetained(Target(self))
        var context = FSEventStreamContext(
            version: 0, info: target.toOpaque(),
            retain: nil, release: { info in
                if let info { Unmanaged<Target>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            nil, Self.callback, &context, [resolved.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        else {
            target.release()
            appLog.write("[advisor] session folder watch not started: \(resolved.path)")
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            appLog.write("[advisor] session folder watch not started: \(resolved.path)")
            return
        }
        stream = created
        self.folder = resolved
    }

    /// Stop the watch. A batch that FSEvents gave just before can still be
    /// reported once.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        folder = nil
    }

    /// The flags of a change that FSEvents gives for a directory, not an item:
    /// events were dropped, or the watched folder itself moved.
    private nonisolated static let mustRescan = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    /// The flags of a change to an item's content or name. A change of
    /// attributes only (an extended attribute that macOS or a sync client
    /// sets, a time stamp, the owner) changes nothing that the browser shows.
    private nonisolated static let contentChange = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)

    /// True when the change to `path` with `flags`, under the watched folder
    /// `root`, is reported: a change that FSEvents cannot itemise, or a change
    /// to the content or name of an item that `SessionArchive.affectsBrowser`
    /// accepts, other than the `live` note.
    nonisolated static func reports(
        path: String, flags: FSEventStreamEventFlags, root: String, ignoring live: URL? = nil
    ) -> Bool {
        if flags & mustRescan != 0 { return true }
        guard flags & contentChange != 0 else { return false }
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        return SessionArchive.affectsBrowser(path: path, isDirectory: isDirectory, root: root)
            && !SessionArchive.isSameNote(URL(fileURLWithPath: path), live)
    }

    private func receive(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        guard let root = folder?.path else { return }
        let live = ignoring()
        let reported = zip(paths, flags).filter {
            Self.reports(path: $0, flags: $1, root: root, ignoring: live)
        }.map(\.0)
        guard !reported.isEmpty else { return }
        // Report on the next turn of the main queue: a report can reload the
        // list and so move the watch, and FSEvents does not say that a stream
        // can stop inside its own callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange(reported) }
        }
    }

    /// The stream's link to its watch. The stream owns it, and it does not
    /// keep the watch alive.
    private final class Target {
        weak var watch: SessionFolderWatch?
        init(_ watch: SessionFolderWatch) { self.watch = watch }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let target = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
        // The stream delivers on the main queue (`FSEventStreamSetDispatchQueue`).
        MainActor.assumeIsolated { target.watch?.receive(paths, flags) }
    }
}
