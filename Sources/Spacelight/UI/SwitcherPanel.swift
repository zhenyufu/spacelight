import AppKit
import os

private let panelLog = Logger(subsystem: "com.spacelight", category: "panel")

/// The floating switcher surface. Created once at agent launch and only ever ordered in and out
/// after that, never rebuilt, since never reconstructing the window is the biggest single
/// contributor to a press feeling instant rather than assembled.
final class SwitcherPanel: NSPanel {
    let switcherViewController = SwitcherViewController()

    /// Where the panel's top edge sits as a fraction of the screen's visible height. This is
    /// where Spotlight itself sits on this machine at the time of writing (macOS 26.5); revisit
    /// against a real screenshot if it drifts on a future OS version.
    private static let topInsetFraction: CGFloat = 0.22

    init() {
        // .nonactivatingPanel: doesn't steal key window status from other panels or take a
        //   dock bounce; we drive activation explicitly in show()/hide() instead.
        // .borderless + .fullSizeContentView: no title bar, the visual effect view is the chrome.
        let initialWidth = SwitcherViewController.Metric.panelWidth
        let initialHeight = SwitcherViewController.Metric.searchFieldHeight
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        // .stationary (meant for desktop-picture-like windows pinned to their original Space) was
        // in this set originally and, combined with .canJoinAllSpaces, left the panel reporting
        // isVisible == true but occlusionState not containing .visible: ordered in from AppKit's
        // perspective but never actually composited on screen. Removed; .canJoinAllSpaces +
        // .fullScreenAuxiliary alone is the standard combination for a Spotlight-style panel.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // hidesOnDeactivate = true was tried here and caused a second, reproduced bug: its docs
        // say it doesn't just hide the window on deactivation, it also *restores* it automatically
        // on the next activation. That automatic restore and this class's own explicit
        // makeKeyAndOrderFront in show() are two independent code paths both trying to bring the
        // same window forward at once, and starting on the second show of a session (the first
        // time the "restore" half of hidesOnDeactivate is actually armed by a prior
        // deactivation), the window would end up reporting isVisible == true and isKeyWindow ==
        // true while never actually being composited on screen. Replaced with the explicit
        // notification observer below, so there is exactly one order-out code path, not two.
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false // this is the only instance; never let AppKit free it
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        contentViewController = switcherViewController
        reposition(rowCount: 0)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    /// Fires whenever Spacelight loses active-application status, whether that's because `hide()`
    /// explicitly reactivated another app or because the user clicked directly into another app's
    /// window without going through `hide()` at all. Either way, the panel should no longer be on
    /// screen; ordering out here is the one and only place that happens (see the doc comment on
    /// `hidesOnDeactivate` above for why it isn't the built-in property instead).
    @objc private func applicationDidResignActive() {
        orderOut(nil)
    }

    /// The screen resolved once per `show()` and reused for every `reposition(rowCount:)` call
    /// until the panel is next shown. This exists because of a real bug found in testing: content
    /// reloads happen continuously while the panel is open (every debounced background AeroSpace
    /// event re-renders it, see `EventSubscriber`), and re-resolving `NSScreen.main` on each of
    /// those reloads let the panel silently teleport to a different physical monitor mid-session
    /// whenever `NSScreen.main`'s answer changed for any transient reason — visibly vanishing from
    /// whichever screen the user was actually looking at. Resolving once per show and holding it
    /// fixed for that whole visible session is what a floating panel's position should do: track
    /// "where you were when you opened it," not "whatever the system says right now."
    private var screenForCurrentSession: NSScreen?

    /// Resizes to fit `rowCount` rows (see `SwitcherViewController.preferredHeight`).
    /// Horizontally centers and vertically top-anchors on `screenForCurrentSession`, falling back
    /// to `NSScreen.main` only if this is being called before any `show()` has ever run (e.g. the
    /// constructor's initial layout pass).
    func reposition(rowCount: Int) {
        guard let screen = screenForCurrentSession ?? NSScreen.main else {
            panelLog.error("reposition: no screen available, not repositioning")
            return
        }
        let width = switcherViewController.preferredWidth
        let height = switcherViewController.preferredHeight(forRowCount: rowCount)
        let visible = screen.visibleFrame
        let originX = visible.midX - width / 2
        let topY = visible.minY + visible.height * (1 - Self.topInsetFraction)
        let originY = topY - height
        setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
    }

    /// A borderless panel can't become key by default, which would leave the search field unable
    /// to receive keystrokes. Overriding this is the standard fix.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// +1 to move the selection down, -1 to move it up. Fired for ⌃J / ⌃K.
    var onMoveSelection: ((Int) -> Void)?

    /// ⌃J / ⌃K need to be caught here rather than in the search field's `doCommandBy:` switch,
    /// because AppKit's built-in Emacs-style text bindings already claim them: ⌃K resolves to
    /// "delete to end of line" by default, which would eat the query instead of moving the
    /// selection. AppKit only routes Command/Control/Option/Function-modified keydowns through
    /// `performKeyEquivalent` before the first responder's normal key-binding resolution runs, so
    /// intercepting them here is what lets this app claim the combination before that default
    /// binding does. Anything not explicitly claimed here falls through to `super`, which keeps
    /// normal typing, arrow keys, Return, and Escape flowing through the field editor as usual.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .control, let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "j":
                onMoveSelection?(1)
                return true
            case "k":
                onMoveSelection?(-1)
                return true
            default:
                break
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Show / hide

    /// Whichever app was frontmost right before `show()` activated Spacelight, captured so `hide()`
    /// can hand activation back to it explicitly. Found in testing to be necessary: the more
    /// obvious approach, `NSApp.hide(nil)`, triggers macOS's animated whole-application hide/unhide
    /// machinery, which is built for regular multi-window apps and raced against this panel's own
    /// explicit `makeKeyAndOrderFront` on a subsequent show — the window would report
    /// `isVisible == true` and `isKeyWindow == true` while never actually being composited on
    /// screen (`occlusionState` never containing `.visible`), a real, reproduced bug on this
    /// machine. Explicitly reactivating the specific previous app avoids that machinery entirely.
    private var previousFrontmostApp: NSRunningApplication?

    /// Brings the panel on screen. `NSApp.activate()` is what lets a `.accessory`-policy process
    /// (no Dock icon) still become the frontmost app and receive keystrokes while visible, the
    /// same mechanism Spotlight and similar launchers rely on.
    func show(rowCount: Int) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousFrontmostApp = frontmost
        }
        screenForCurrentSession = NSScreen.main
        // Clear before positioning: clearQuery() fires onQueryChanged, which re-filters and
        // repositions with the full unfiltered row count. Positioning first would size the panel
        // to the outgoing (possibly filtered) result count for a frame.
        switcherViewController.clearQuery()
        reposition(rowCount: rowCount)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        switcherViewController.focusSearchField()
    }

    /// Orders the panel out and reactivates whichever app was frontmost before `show()`. Callers
    /// that also need to dispatch an AeroSpace command must call this first and only then run the
    /// command: sending the command before hiding lets Spacelight's own deactivation land after
    /// the switch and steal focus back, which is the exact class of bug the current fzf-based tool
    /// suffers from.
    func hide() {
        // Ordering out has to be unconditional and synchronous here, not left to happen only as
        // a side effect of applicationDidResignActive firing below: that notification depends on
        // previousFrontmostApp.activate() actually landing, which is not guaranteed to be
        // synchronous (or to land at all, e.g. if that app has since quit). A version of this
        // method that hid *only* via that notification was tried and reproduced a real, worse
        // bug: the panel staying stuck on screen after accepting a selection, because the
        // reactivation didn't complete in time to trigger it. This call is what guarantees the
        // panel actually disappears regardless of what happens with the other app.
        orderOut(nil)
        // Best-effort focus handoff; applicationDidResignActive firing from this is now a no-op
        // redundant order-out, not the mechanism the panel's disappearance depends on.
        previousFrontmostApp?.activate()
        self.previousFrontmostApp = nil
        screenForCurrentSession = nil // next show() resolves fresh; see its doc comment
    }

    /// Counts actual `orderOut` calls by overriding the method itself, rather than having `hide()`
    /// set a flag: a flag set inside `hide()` would still be set even if the `orderOut` call were
    /// removed, which is exactly the regression being guarded against. Verified by reintroducing
    /// the bug and confirming the test then fails.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        orderOutCallCount += 1
    }

    // MARK: - Regression guards
    //
    // The two window-server bugs this class hit during development (a panel that reported itself
    // visible but never composited, and a panel that stayed stuck on screen) can only be fully
    // reproduced against a real window server, so they aren't directly unit-testable. What *is*
    // testable is the specific code invariant behind each one, which is what actually regressed
    // both times. These two properties expose exactly that much state for `SwitcherPanelTests`.

    /// Number of times `orderOut` has actually been invoked on this panel, incremented by the
    /// override above. Guards the stuck-panel regression: `hide()` must never make ordering out
    /// conditional on another app's activation succeeding.
    private(set) var orderOutCallCount = 0

    /// Exposed so a test can assert this stays `false`. Guards the invisible-panel regression:
    /// AppKit's `hidesOnDeactivate` doesn't only hide on deactivate, it also auto-restores on the
    /// next activate, which conflicts with this class's own explicit `makeKeyAndOrderFront`.
    var usesBuiltInHidesOnDeactivate: Bool { hidesOnDeactivate }
}
