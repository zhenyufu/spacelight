import Foundation

/// One row the switcher can show and act on: either a workspace or a specific window.
/// `searchHaystack` is precomputed once when the snapshot is built so that filtering on every
/// keystroke is pure string comparison with no per-keystroke lowercasing or concatenation.
struct SwitcherItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case workspace(isFocused: Bool, isVisible: Bool)
        case window(appName: String, appBundlePath: String?, workspace: String)
    }

    /// Stable identity: `"workspace:<name>"` or `"window:<id>"`. Used for diffing snapshots and
    /// for `NSTableView` row identity so selection survives a reload when nothing changed.
    let id: String
    let kind: Kind
    let monitorID: Int

    /// AeroSpace's own monitor numbering doesn't line up with AppKit's `NSScreen` identifiers, so
    /// positioning the panel needs this separate join key: `NSScreen.screens[i].deviceDescription`
    /// under `NSDeviceDescriptionKey("NSScreenNumber")` equals this value for the matching screen.
    /// Only ever set on workspace items, since positioning always keys off the focused workspace.
    let nsScreenNumber: Int?

    /// The workspace name, or the raw window title, exactly as AeroSpace reports it.
    let primaryText: String
    /// Cleaned-up display title for windows (trailing " - <app>" suffix stripped). Equal to
    /// `primaryText` for workspaces.
    let displayText: String

    /// "app name + raw title" (windows) or "workspace name" (workspaces), built once at snapshot
    /// time and reused by `FuzzyMatcher` on every keystroke. Deliberately kept in **original**
    /// case: `FuzzyMatcher` does its own per-character case folding so it can still see real case
    /// transitions for the camelCase boundary bonus, which a pre-lowercased haystack would hide.
    let searchHaystack: String

    /// For workspace rows only: a comma-joined summary of the app names of the windows currently
    /// in that workspace (e.g. "Chrome, Terminal"), shown as the row's subtitle instead of a
    /// generic "Workspace" label. `var` with a default rather than a constructor parameter because
    /// it can only be computed once both the workspace and window lists are available together
    /// (see `StateStore.refresh()`), after this item already exists.
    var windowSummary: String?

    static func workspace(
        name: String,
        isFocused: Bool,
        isVisible: Bool,
        monitorID: Int,
        nsScreenNumber: Int
    ) -> SwitcherItem {
        SwitcherItem(
            id: "workspace:\(name)",
            kind: .workspace(isFocused: isFocused, isVisible: isVisible),
            monitorID: monitorID,
            nsScreenNumber: nsScreenNumber,
            primaryText: name,
            displayText: name,
            searchHaystack: name
        )
    }

    static func window(
        id windowID: Int,
        appName: String,
        title: String,
        workspace: String,
        appBundlePath: String?,
        monitorID: Int
    ) -> SwitcherItem {
        let display = Self.stripTrailingAppSuffix(title: title, appName: appName)
        return SwitcherItem(
            id: "window:\(windowID)",
            kind: .window(appName: appName, appBundlePath: appBundlePath, workspace: workspace),
            monitorID: monitorID,
            nsScreenNumber: nil,
            primaryText: title,
            displayText: display,
            searchHaystack: "\(appName) \(title)"
        )
    }

    /// Many apps append " - <App Name>" to every window title, and Chrome specifically appends
    /// " - <App Name> - <Profile Name>" on top of that (real titles end e.g. " - Google Chrome -
    /// Profile 1"), so a plain `hasSuffix` check misses it: the match has to look for the marker
    /// anywhere and truncate from there, not just at the very end.
    /// Stripped for display only; the raw title is still what gets searched.
    private static func stripTrailingAppSuffix(title: String, appName: String) -> String {
        let marker = " - \(appName)"
        guard let range = title.range(of: marker) else { return title }
        return String(title[title.startIndex..<range.lowerBound])
    }

    var isWorkspace: Bool {
        if case .workspace = kind { return true }
        return false
    }

    var windowID: Int? {
        guard case .window = kind, id.hasPrefix("window:") else { return nil }
        return Int(id.dropFirst("window:".count))
    }

    var workspaceName: String? {
        switch kind {
        case .workspace: return String(id.dropFirst("workspace:".count))
        case .window(_, _, let workspace): return workspace
        }
    }
}
