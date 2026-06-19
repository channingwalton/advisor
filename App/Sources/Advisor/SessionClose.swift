import AppKit
import SwiftUI

/// What closing the recording window should do.
enum SessionCloseAction: Equatable {
    /// Nothing running — close immediately (the pre-existing behaviour).
    case closeNow
    /// Cancel the in-flight agents, then close.
    case terminateAndClose
    /// Stop recording, let the in-flight agents finish, then close.
    case waitThenClose
    /// Keep the window open, agents untouched.
    case stayOpen
}

/// The user's response to the "agents still running" prompt.
enum SessionCloseChoice {
    case wait, terminate, cancel
}

enum SessionClose {
    /// Map (agents-in-flight, user choice) to the close action. When no agents
    /// are in flight the prompt never appears, so the choice is irrelevant and
    /// the window closes straight away.
    static func action(agentsInFlight: Bool, choice: SessionCloseChoice) -> SessionCloseAction {
        guard agentsInFlight else { return .closeNow }
        switch choice {
        case .wait: return .waitThenClose
        case .terminate: return .terminateAndClose
        case .cancel: return .stayOpen
        }
    }
}

/// Zero-size helper that guards the recording window's close: when agent tasks
/// are still in flight it intercepts the close (red button / Cmd-W) and prompts
/// to wait or stop them, leaving the shared sidecar — and so the Sessions
/// browser — untouched. It proxies SwiftUI's own window delegate (forwarding
/// every message except `windowShouldClose`) so no SwiftUI behaviour is lost.
struct WindowCloseGuard: NSViewRepresentable {
    /// Whether any agent task for this session is still running.
    let agentsInFlight: () -> Bool
    /// True while a "Wait"-to-close is already in progress, so a further close
    /// attempt is ignored rather than re-prompting. Read fresh on each close.
    let isFinishing: () -> Bool
    /// Cancel the in-flight agents now (the "Stop and Close" path).
    let terminate: () -> Void
    /// Begin the "Wait" path: stop recording, drain the in-flight agents behind
    /// the overlay, then close the window itself (via SwiftUI's dismiss).
    let waitForIdle: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(
            agentsInFlight: agentsInFlight, isFinishing: isFinishing, terminate: terminate,
            waitForIdle: waitForIdle)
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Refresh the captured closures each render so they read current state.
        context.coordinator.update(
            agentsInFlight: agentsInFlight, isFinishing: isFinishing, terminate: terminate,
            waitForIdle: waitForIdle)
        if !context.coordinator.attached {
            DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private var agentsInFlight: () -> Bool = { false }
        private var isFinishing: () -> Bool = { false }
        private var terminate: () -> Void = {}
        private var waitForIdle: () -> Void = {}
        private weak var window: NSWindow?
        /// SwiftUI's delegate, kept so every non-close message still reaches it.
        private weak var priorDelegate: NSWindowDelegate?

        var attached: Bool { window != nil }

        func update(
            agentsInFlight: @escaping () -> Bool, isFinishing: @escaping () -> Bool,
            terminate: @escaping () -> Void, waitForIdle: @escaping () -> Void
        ) {
            self.agentsInFlight = agentsInFlight
            self.isFinishing = isFinishing
            self.terminate = terminate
            self.waitForIdle = waitForIdle
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            priorDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isFinishing() { return false } // already finishing — ignore further closes
            guard agentsInFlight() else { return true }
            let choice = prompt()
            switch SessionClose.action(agentsInFlight: true, choice: choice) {
            case .closeNow:
                return true
            case .terminateAndClose:
                terminate()
                return true
            case .waitThenClose:
                // The view raises the overlay, drains the agents, then closes via
                // SwiftUI's dismiss (so onDisappear runs); block this close.
                waitForIdle()
                return false
            case .stayOpen:
                return false
            }
        }

        private func prompt() -> SessionCloseChoice {
            let alert = NSAlert()
            alert.messageText = "Agent tasks still running"
            alert.informativeText =
                "This session still has agent tasks in progress. Wait for them to finish, or stop them now?"
            alert.addButton(withTitle: "Wait")
            alert.addButton(withTitle: "Stop and Close")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .wait
            case .alertSecondButtonReturn: return .terminate
            default: return .cancel
            }
        }

        // Forward every other delegate message to SwiftUI's own delegate, so
        // intercepting the close doesn't suppress SwiftUI's window handling.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (priorDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            (priorDelegate?.responds(to: aSelector) ?? false) ? priorDelegate : nil
        }
    }
}
