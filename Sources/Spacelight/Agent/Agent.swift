import AppKit
import os

private let log = Logger(subsystem: "com.spacelight", category: "agent")

/// Entry point for `spacelight --agent`. Sets up the accessory activation policy (no Dock icon,
/// no ⌘Tab entry), starts the control socket, and runs the app's main loop.
///
/// AppKit is inherently main-actor bound, so this whole entry point runs isolated to it; the
/// caller in main.swift enters via `MainActor.assumeIsolated`, which is sound because nothing
/// touches this code before `NSApplication` takes over the (single) main thread.
@MainActor
func runAgent() {
    let app = NSApplication.shared
    // .accessory keeps Spacelight out of the Dock and ⌘Tab, and is what keeps AeroSpace from
    // ever seeing this process's window as something to tile.
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlSocket: ControlSocket?
    private let aeroSpace = AeroSpaceClient()
    private lazy var store = StateStore(aeroSpace: aeroSpace)
    private let iconCache = IconCache()
    private lazy var eventSubscriber = EventSubscriber { [weak self] in
        self?.handleAeroSpaceEvent()
    }

    /// Built once at launch and only ever ordered in/out after that; see SwitcherPanel's doc
    /// comment for why never rebuilding it matters for perceived latency.
    private let panel = SwitcherPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        wirePanel()

        let socket = ControlSocket { [weak self] verb in
            self?.handle(verb)
        }
        do {
            try socket.start()
            controlSocket = socket
            log.info("agent listening on \(Paths.socketPath, privacy: .public)")
        } catch ControlSocket.BindError.alreadyRunning {
            log.info("another agent is already running, exiting")
            NSApplication.shared.terminate(nil)
        } catch {
            log.error("failed to start control socket: \(String(describing: error), privacy: .public)")
            NSApplication.shared.terminate(nil)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let path = try await aeroSpace.resolvedPath()
                eventSubscriber.start(executablePath: path)
            } catch {
                // Not fatal: the cache just falls back to refreshing on every panel show instead
                // of staying warm in the background. Logged so a missing `aerospace` binary isn't
                // silently invisible.
                log.error("could not start event subscriber: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Fired (debounced) by `EventSubscriber` whenever AeroSpace reports a focus or mode change.
    /// Refreshes the cache in the background regardless of visibility, so the *next* show is
    /// already fresh; only re-renders the panel's own content if it's currently on screen, since
    /// there's no reason to touch (or resize) a hidden window.
    private func handleAeroSpaceEvent() {
        Task { [weak self] in
            guard let self else { return }
            await store.refresh()
            if panel.isVisible {
                reloadPanelContent()
            }
        }
    }

    /// Connects the panel and view controller's callbacks to `StateStore` and `AeroSpaceClient`.
    private func wirePanel() {
        let vc = panel.switcherViewController
        vc.onCancel = { [weak self] in self?.panel.hide() }
        vc.onAcceptItem = { [weak self] item in self?.accept(item) }
        vc.onQueryChanged = { [weak self] query in
            guard let self else { return }
            store.setQuery(query)
            reloadPanelContent()
        }

        // ⌃J/⌃K are caught at the window level (see SwitcherPanel.performKeyEquivalent),
        // separately from the view controller's doCommandBy-driven arrow handling, but both drive
        // the same selection state on the view controller either way.
        panel.onMoveSelection = { [weak vc] delta in vc?.moveSelection(by: delta) }
    }

    /// Shows the panel immediately with whatever `StateStore` last had cached (empty on the very
    /// first show of a session), then kicks off a fresh AeroSpace snapshot in the background and
    /// re-renders when it lands. This is what keeps "press to visible" off the AeroSpace round
    /// trip: the panel never waits on the ~85-115ms snapshot before appearing.
    private func showPanel() {
        reloadPanelContent()
        panel.show(rowCount: store.results.count)
        Task { [weak self] in
            guard let self else { return }
            await store.refresh()
            reloadPanelContent()
        }
    }

    private func reloadPanelContent() {
        panel.switcherViewController.setItems(store.results, iconCache: iconCache)
        panel.reposition(rowCount: store.results.count)
    }

    /// Hides first, *then* dispatches the AeroSpace command — sending the command before hiding
    /// would let Spacelight's own deactivation land after the switch and steal focus back, which
    /// is the class of bug the current fzf-based tool suffers from. See SwitcherPanel.hide()'s
    /// doc comment for the same point made at the window-management layer.
    private func accept(_ item: SwitcherItem) {
        panel.hide()
        Task { [aeroSpace] in
            switch item.kind {
            case .workspace:
                if let name = item.workspaceName {
                    await aeroSpace.focusWorkspace(name)
                }
            case .window:
                if let windowID = item.windowID {
                    await aeroSpace.focusWindow(id: windowID)
                }
            }
        }
    }

    private func handle(_ verb: ControlVerb) {
        log.info("received verb: \(verb.rawValue, privacy: .public)")
        switch verb {
        case .toggle:
            if panel.isVisible {
                panel.hide()
            } else {
                showPanel()
            }
        case .show:
            showPanel()
        case .hide:
            panel.hide()
        case .ping:
            // Debug hook: exercises AeroSpaceClient against the real running AeroSpace instance
            // and logs the result, independent of the panel's own refresh path. Useful for
            // isolating "is AeroSpace itself the problem" from "is the panel the problem".
            Task { [aeroSpace] in
                let start = ContinuousClock.now
                do {
                    let snapshot = try await aeroSpace.snapshot()
                    let elapsed = start.duration(to: .now)
                    log.info("""
                        snapshot: \(snapshot.workspaces.count) workspaces, \
                        \(snapshot.windows.count) windows in \(elapsed.description, privacy: .public)
                        """)
                    let focused = snapshot.workspaces.first {
                        if case .workspace(let isFocused, _) = $0.kind { return isFocused }
                        return false
                    }
                    log.info("focused workspace: \(focused?.primaryText ?? "<none>", privacy: .public)")
                } catch {
                    log.error("snapshot failed: \(String(describing: error), privacy: .public)")
                }
            }
        case .quit:
            eventSubscriber.stop()
            controlSocket?.stop()
            NSApplication.shared.terminate(nil)
        }
    }
}
