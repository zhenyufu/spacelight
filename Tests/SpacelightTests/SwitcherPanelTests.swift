import AppKit
import Testing
@testable import Spacelight

/// Regression guards for two window-server bugs hit during development. Both were only fully
/// reproducible against a real window server (they involve whether macOS actually composites the
/// panel), so these tests deliberately do not try to assert on-screen visibility. Instead each one
/// pins the specific code invariant whose violation caused the bug, since that invariant is what
/// actually regressed both times and is what a future refactor is most likely to undo.
@MainActor
@Suite struct SwitcherPanelTests {
    /// Regression guard: the panel must not use AppKit's built-in `hidesOnDeactivate`.
    ///
    /// The property's documented behavior isn't only "hide on deactivate" — it also *restores* the
    /// window automatically on the next activation. That automatic restore and `show()`'s own
    /// explicit `makeKeyAndOrderFront` are two independent paths trying to bring the same window
    /// forward, and starting on the second show of a session (the first time the restore half is
    /// armed by a prior deactivation) the panel would report `isVisible == true` and
    /// `isKeyWindow == true` while never actually being composited on screen.
    ///
    /// `SwitcherPanel` handles this itself via an explicit `didResignActiveNotification` observer,
    /// which keeps exactly one order-out code path instead of two.
    @Test func doesNotUseBuiltInHidesOnDeactivate() {
        let panel = SwitcherPanel()
        #expect(panel.usesBuiltInHidesOnDeactivate == false)
    }

    /// Regression guard: `hide()` must order the panel out unconditionally.
    ///
    /// An earlier version routed hiding *only* through the `applicationDidResignActive` observer,
    /// triggered as a side effect of reactivating the previously frontmost app. That made the
    /// panel's disappearance depend on another app's activation landing synchronously, which is
    /// not guaranteed — and it reproduced immediately as a panel left stuck on screen after
    /// accepting a selection.
    ///
    /// Here `previousFrontmostApp` is never populated (no `show()` is called first), which is
    /// exactly the case where the notification would never fire at all: the panel must still have
    /// ordered itself out.
    @Test func hideOrdersOutEvenWithNoPreviousAppToReactivate() {
        let panel = SwitcherPanel()
        let before = panel.orderOutCallCount

        panel.hide()

        // Counts real `orderOut` invocations (via an override), not a flag `hide()` sets itself:
        // a self-set flag would still be set with the `orderOut` call deleted, which is precisely
        // the regression this guards. Confirmed to fail when that call is removed.
        #expect(panel.orderOutCallCount == before + 1)
        #expect(panel.isVisible == false)
    }

    /// The panel is built once at agent launch and only ordered in and out after that, so it must
    /// survive being closed without AppKit deallocating it.
    @Test func isNotReleasedWhenClosed() {
        let panel = SwitcherPanel()
        #expect(panel.isReleasedWhenClosed == false)
    }

    /// A borderless panel can't become key by default, which would leave the search field unable to
    /// receive any keystrokes at all.
    @Test func canBecomeKeySoTheSearchFieldWorks() {
        let panel = SwitcherPanel()
        #expect(panel.canBecomeKey)
    }

    /// Regression guard: `.stationary` in the collection behavior (combined with
    /// `.canJoinAllSpaces`) left the panel reporting `isVisible == true` while `occlusionState`
    /// never contained `.visible` — ordered in from AppKit's perspective but never composited.
    @Test func collectionBehaviorOmitsStationary() {
        let panel = SwitcherPanel()
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.stationary) == false)
    }
}
