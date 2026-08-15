import Testing
@testable import Spacelight

/// Fixtures below are synthetic, but each line is shaped after real `aerospace list-workspaces` /
/// `list-windows` output and deliberately preserves the awkward cases that motivated these tests:
/// pipe and asterisk characters in a title, unicode en-dashes, em-dashes and multiplication signs,
/// a bracketed tab-group label, an app with no bundle path, and Chrome's habit of appending
/// " - <App Name> - <Profile Name>" (two suffixes, not one) to every window title.
@Suite struct SnapshotParserTests {
    static let workspacesFixture = """
        1\tfalse\tfalse\t1\t1
        2\tfalse\tfalse\t1\t1
        dev\ttrue\ttrue\t1\t1
        media\tfalse\ttrue\t2\t2
        """

    static let windowsFixture = """
        78\tGoogle Chrome\tQuarterly Metrics | Dashboard * Draft * - Analytics - Part of group [Reports] Q3 - Google Chrome - Profile 1\tweb\t/Applications/Google Chrome.app\t1
        83\tGoogle Chrome\tRelease Notes - Google Docs - Google Chrome - Profile 1\tweb\t/Applications/Google Chrome.app\t1
        265\tNotes\tNotes \u{2013} 5 notes\tnotes\t/System/Applications/Notes.app\t1
        156\tTerminal\tbuild-scripts \u{2014} -zsh \u{2014} 123\u{d7}72\tdev\t/System/Applications/Utilities/Terminal.app\t1
        999\tSomeHelper\tno bundle here\thidden\t\t1
        """

    @Test func parsesWorkspaceFieldsAndFlags() throws {
        let items = SnapshotParser.parseWorkspaces(Self.workspacesFixture)
        #expect(items.count == 4)

        let dev = try #require(items.first { $0.id == "workspace:dev" })
        #expect(dev.isWorkspace)
        #expect(dev.primaryText == "dev")
        if case .workspace(let isFocused, let isVisible) = dev.kind {
            #expect(isFocused)
            #expect(isVisible)
        } else {
            Issue.record("expected .workspace kind")
        }

        let media = try #require(items.first { $0.id == "workspace:media" })
        if case .workspace(let isFocused, let isVisible) = media.kind {
            #expect(!isFocused)
            #expect(isVisible)
        } else {
            Issue.record("expected .workspace kind")
        }
        #expect(media.monitorID == 2)
        #expect(media.nsScreenNumber == 2)
    }

    @Test func parsesWindowFieldsAndDisplayTitle() throws {
        let items = SnapshotParser.parseWindows(Self.windowsFixture)
        #expect(items.count == 5)

        let pipeTitle = try #require(items.first { $0.windowID == 78 })
        // Raw title (used for search) keeps the pipe, asterisks, and bracketed group label intact.
        #expect(pipeTitle.primaryText.contains("|"))
        #expect(pipeTitle.primaryText.contains("*"))
        // searchHaystack is deliberately kept in original case (see SwitcherItem's doc comment)
        // so FuzzyMatcher can still detect camelCase boundaries; only the display title is cleaned.
        #expect(pipeTitle.searchHaystack.contains("Quarterly"))
        // Display title has the " - Google Chrome - Profile 1" tail stripped. This is the case a
        // plain `hasSuffix` check misses, since the app name is not the last thing in the title.
        #expect(pipeTitle.displayText == "Quarterly Metrics | Dashboard * Draft * - Analytics - Part of group [Reports] Q3")

        let docsTitle = try #require(items.first { $0.windowID == 83 })
        #expect(docsTitle.displayText == "Release Notes - Google Docs")

        let notesTitle = try #require(items.first { $0.windowID == 265 })
        // No " - Notes" marker present, so the en-dash title passes through unchanged.
        #expect(notesTitle.displayText == "Notes \u{2013} 5 notes")

        let terminalTitle = try #require(items.first { $0.windowID == 156 })
        #expect(terminalTitle.displayText == "build-scripts \u{2014} -zsh \u{2014} 123\u{d7}72")
    }

    @Test func handlesEmptyBundlePath() throws {
        let items = SnapshotParser.parseWindows(Self.windowsFixture)
        let helper = try #require(items.first { $0.windowID == 999 })
        guard case .window(_, let bundlePath, _) = helper.kind else {
            Issue.record("expected .window kind")
            return
        }
        #expect(bundlePath == nil)
    }

    @Test func skipsMalformedLines() throws {
        let malformed = "not-enough-fields\tfoo"
        #expect(SnapshotParser.parseWorkspaces(malformed).isEmpty)
        #expect(SnapshotParser.parseWindows(malformed).isEmpty)
    }

    @Test func handlesEmptyInput() throws {
        #expect(SnapshotParser.parseWorkspaces("").isEmpty)
        #expect(SnapshotParser.parseWindows("").isEmpty)
    }

    @Test func windowIDAndWorkspaceNameAccessors() throws {
        let items = SnapshotParser.parseWindows(Self.windowsFixture)
        let window = try #require(items.first { $0.windowID == 78 })
        #expect(window.windowID == 78)
        #expect(window.workspaceName == "web")

        let workspaces = SnapshotParser.parseWorkspaces(Self.workspacesFixture)
        let dev = try #require(workspaces.first { $0.id == "workspace:dev" })
        #expect(dev.windowID == nil)
        #expect(dev.workspaceName == "dev")
    }
}
