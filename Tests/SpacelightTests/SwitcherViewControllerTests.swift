import AppKit
import Testing
@testable import Spacelight

/// Covers the modal input behavior: the panel opens in navigation mode oriented at the current
/// workspace, bare j/k and arrows move the selection, and `/` switches into search.
@MainActor
@Suite struct SwitcherViewControllerTests {
    /// Three workspaces (the second one focused) followed by two windows, matching the real
    /// ordering `StateStore` produces: workspaces first, then windows.
    private static func makeItems() -> [SwitcherItem] {
        [
            .workspace(name: "alpha", isFocused: false, isVisible: false, monitorID: 1, nsScreenNumber: 1),
            .workspace(name: "beta", isFocused: true, isVisible: true, monitorID: 1, nsScreenNumber: 1),
            .workspace(name: "gamma", isFocused: false, isVisible: false, monitorID: 1, nsScreenNumber: 1),
            .window(id: 10, appName: "Terminal", title: "zsh", workspace: "beta", appBundlePath: nil, monitorID: 1),
            .window(id: 11, appName: "Notes", title: "Scratch", workspace: "alpha", appBundlePath: nil, monitorID: 1),
        ]
    }

    private static func makeLoadedController() -> SwitcherViewController {
        let vc = SwitcherViewController()
        _ = vc.view // force loadView so the table and search field exist
        vc.setItems(makeItems(), iconCache: IconCache())
        return vc
    }

    @Test func startsInNavigationModeSelectingTheCurrentWorkspace() {
        let vc = Self.makeLoadedController()
        #expect(vc.mode == .navigation)
        // "beta" is the focused workspace and sits at index 1, not index 0, so this would fail if
        // the panel simply defaulted to the first row.
        #expect(vc.selectedIndex == 1)
    }

    /// The panel is shown immediately against a possibly empty cache, with the real snapshot
    /// arriving asynchronously (see `AppDelegate.showPanel`). The selection must land on the
    /// current workspace when that late data arrives, not stay pinned at row 0.
    @Test func selectsCurrentWorkspaceWhenItemsArriveAfterOpening() {
        let vc = SwitcherViewController()
        _ = vc.view
        vc.setItems([], iconCache: IconCache())
        #expect(vc.selectedIndex == 0)

        vc.setItems(Self.makeItems(), iconCache: IconCache())
        #expect(vc.selectedIndex == 1)
    }

    /// Once the user has moved the selection themselves, a background refresh must not yank it
    /// back to the current workspace under them.
    @Test func backgroundRefreshDoesNotOverrideAUserMovedSelection() {
        let vc = Self.makeLoadedController()
        vc.moveSelection(by: 2) // 1 -> 3
        #expect(vc.selectedIndex == 3)

        vc.setItems(Self.makeItems(), iconCache: IconCache())
        #expect(vc.selectedIndex == 3)
    }

    @Test func bareJAndKMoveTheSelectionInNavigationMode() throws {
        let vc = Self.makeLoadedController()
        #expect(vc.selectedIndex == 1)

        #expect(vc.handleNavigationKey(try #require(Self.key("j"))))
        #expect(vc.selectedIndex == 2)

        #expect(vc.handleNavigationKey(try #require(Self.key("k"))))
        #expect(vc.selectedIndex == 1)
    }

    @Test func arrowKeysMoveTheSelectionInNavigationMode() throws {
        let vc = Self.makeLoadedController()

        #expect(vc.handleNavigationKey(try #require(Self.arrowKey(keyCode: 125)))) // down
        #expect(vc.selectedIndex == 2)

        #expect(vc.handleNavigationKey(try #require(Self.arrowKey(keyCode: 126)))) // up
        #expect(vc.selectedIndex == 1)
    }

    @Test func selectionIsClampedAtBothEndsWithNoWraparound() throws {
        let vc = Self.makeLoadedController()

        for _ in 0..<10 { _ = vc.handleNavigationKey(try #require(Self.key("k"))) }
        #expect(vc.selectedIndex == 0)

        for _ in 0..<10 { _ = vc.handleNavigationKey(try #require(Self.key("j"))) }
        #expect(vc.selectedIndex == Self.makeItems().count - 1)
    }

    /// The panel must look the same every time it opens. `scrollRowToVisible` performs only the
    /// minimum scroll needed to expose a row, so with a list long enough to scroll it would leave
    /// the previous offset in place and the highlighted workspace could land at the top, middle,
    /// or bottom depending on history. Opening pins the list to row 0 instead.
    @Test func opensScrolledToTopEvenAfterScrollingAway() {
        let vc = SwitcherViewController()
        _ = vc.view
        // Force a viewport small enough that the list genuinely scrolls.
        vc.view.frame = NSRect(x: 0, y: 0, width: 720, height: 240)
        vc.view.layoutSubtreeIfNeeded()

        var many = Self.makeItems()
        for index in 0..<40 {
            many.append(
                .window(
                    id: 100 + index,
                    appName: "App\(index)",
                    title: "Window \(index)",
                    workspace: "alpha",
                    appBundlePath: nil,
                    monitorID: 1
                )
            )
        }
        vc.setItems(many, iconCache: IconCache())

        // Scroll far down, the way a user browsing a long list would leave it.
        vc.moveSelection(by: 30)
        vc.view.layoutSubtreeIfNeeded()

        // Reopening re-selects the current workspace and must also reset the scroll offset.
        vc.selectCurrentWorkspace()
        vc.view.layoutSubtreeIfNeeded()

        #expect(vc.verticalScrollOffset == 0)
    }

    @Test func slashEntersSearchMode() throws {
        let vc = Self.makeLoadedController()
        #expect(vc.mode == .navigation)

        #expect(vc.handleNavigationKey(try #require(Self.key("/"))))
        #expect(vc.mode == .search)
    }

    /// Once in search mode, `j` and `k` must stop being navigation commands so they can be typed
    /// into a query like "japanese". `handleNavigationKey` is the only path that treats them as
    /// commands, so it must decline everything while searching.
    @Test func navigationKeysAreInertInSearchMode() throws {
        let vc = Self.makeLoadedController()
        vc.enterSearchMode()
        #expect(vc.mode == .search)

        #expect(vc.handleNavigationKey(try #require(Self.key("j"))) == false)
        #expect(vc.handleNavigationKey(try #require(Self.key("k"))) == false)
        #expect(vc.selectedIndex == 1) // unchanged
    }

    @Test func returningToNavigationModeReselectsTheCurrentWorkspace() throws {
        let vc = Self.makeLoadedController()
        vc.moveSelection(by: 3)
        vc.enterSearchMode()

        vc.enterNavigationMode()
        vc.selectCurrentWorkspace()

        #expect(vc.mode == .navigation)
        #expect(vc.selectedIndex == 1)
    }

    /// Modified keys must fall through so system and app shortcuts keep working; only bare
    /// keystrokes drive navigation.
    @Test func modifiedKeysAreNotTreatedAsNavigation() throws {
        let vc = Self.makeLoadedController()
        let commandJ = try #require(Self.key("j", flags: .command))
        #expect(vc.handleNavigationKey(commandJ) == false)
        #expect(vc.selectedIndex == 1)
    }

    // MARK: - Helpers

    private static func key(_ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )
    }

    /// Builds an arrow-key event the way macOS actually delivers one.
    ///
    /// `.function` and `.numericPad` are set by the system on real arrow presses, and omitting
    /// them here previously made this helper lie: the tests passed while arrow keys were broken in
    /// the running app, because production code rejected the real (flagged) events that the
    /// synthetic (unflagged) ones never exercised. Any future key helper should mirror the real
    /// event as closely as possible for the same reason.
    private static func arrowKey(keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.function, .numericPad],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
