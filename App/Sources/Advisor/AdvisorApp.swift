import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    /// The ⌘Q teardown, registered by `AppServices.start`.
    weak var quitting: Quitting?
    // Drain the log first: its writes are async, and `_exit` would drop them
    // (a cut-off quit's own diagnostic among them).
    private let quit = QuitSequence(exit: {
        appLog.flushSidecar()
        appLog.flush()
        _exit(0)
    })

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyAppearance(AdvisorConfig.load().appearance)
        // Reapply when the appearance preference changes, without a relaunch.
        NotificationCenter.default.addObserver(
            forName: .advisorConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so this is on the main actor — the
            // closure's type just can't say so.
            MainActor.assumeIsolated {
                self?.applyAppearance(AdvisorConfig.load().appearance)
            }
        }
    }

    /// Force the app's appearance from the saved preference. "system" clears the
    /// override so the app follows macOS; the Theme's dynamic colours resolve
    /// against `NSApp.effectiveAppearance`, so this drives the whole UI.
    private func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// On Cmd-Q, AppKit calls `exit()`, which runs C++ static destructors.
    /// ggml-metal registers a global Metal-device vector whose destructor
    /// hits `ggml_abort` at process-exit (the same teardown hazard the smoke
    /// test sidesteps with deinit-before-exit ordering). Do our own orderly
    /// cleanup, then `_exit` to bypass those finalisers entirely. The cleanup is
    /// async — the recording's last speech has to reach the note — so AppKit is
    /// told to wait (`terminateLater`) and `QuitSequence` exits when it is done,
    /// or after its deadline. A second ⌘Q meanwhile changes nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quitting = quitting
        quit.start(shutdown: { await quitting?.shutdown() }, finish: { quitting?.finishQuit() })
        return .terminateLater
    }
}

@main
struct AdvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var services = AppServices()
    @AppStorage("agentLanes") private var agentLanes = 3

    var body: some Scene {
        // The Sessions browser is the main window: it opens at launch and is a
        // single shared master/detail window. Starting `services` here (not in
        // the recording window) keeps the sidecar alive so saved transcripts can
        // be queried with no recording window open.
        Window("Sessions", id: "sessions") {
            SessionsView()
                .task { services.start(lanes: agentLanes) }
        }
        .windowStyle(.hiddenTitleBar)
        // Compact: smaller toolbar buttons and a shorter traffic-light row, so
        // the chrome recedes behind the sessions themselves.
        .windowToolbarStyle(.unifiedCompact)
        .defaultLaunchBehavior(.presented)
        // The recording window — single-instance by virtue of being a `Window`
        // (not a `WindowGroup`): the Sessions "New" button opens it, and
        // re-opening just brings the existing one forward. Never auto-opens.
        Window("Recording", id: "recording") {
            TranscriptView(services: services)
                .frame(minWidth: 420, minHeight: 480)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Cmd-N opens the single recording window (or brings it forward),
        // replacing the menu bar's default "New" — there's no document to create.
        .commands { RecordingCommands() }
        Settings {
            PreferencesView()
        }
    }
}

/// Menu-bar commands: Cmd-N starts a recording. Lives as a `Commands` type so it
/// can read `openWindow` from the environment (the App struct can't directly).
struct RecordingCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { openWindow(id: "recording") }
                .keyboardShortcut("n", modifiers: .command)
        }
    }
}
