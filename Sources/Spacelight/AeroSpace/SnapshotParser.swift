import Foundation

/// Parses the tab-delimited output of the two `aerospace list-*` invocations into `SwitcherItem`s.
/// Pure and side-effect free so it can be unit tested against fixture strings without a running
/// AeroSpace instance; `AeroSpaceClient` is the only caller in the real app.
enum SnapshotParser {
    /// Expects one line per workspace from:
    ///   aerospace list-workspaces --all --format
    ///     '%{workspace}%{tab}%{workspace-is-focused}%{tab}%{workspace-is-visible}%{tab}%{monitor-id}%{tab}%{monitor-appkit-nsscreen-screens-id}'
    ///
    /// The final field is AeroSpace's own monitor numbering translated to the `NSScreen` join key
    /// (see `SwitcherItem.nsScreenNumber`), which is what lets the panel be positioned on the
    /// correct physical display without a separate `list-monitors` round trip.
    static func parseWorkspaces(_ output: String) -> [SwitcherItem] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5 else { return nil }
            let name = fields[0]
            guard !name.isEmpty else { return nil }
            guard let monitorID = Int(fields[3]) else { return nil }
            guard let nsScreenNumber = Int(fields[4]) else { return nil }
            return SwitcherItem.workspace(
                name: name,
                isFocused: fields[1] == "true",
                isVisible: fields[2] == "true",
                monitorID: monitorID,
                nsScreenNumber: nsScreenNumber
            )
        }
    }

    /// Expects one line per window from:
    ///   aerospace list-windows --all --format
    ///     '%{window-id}%{tab}%{app-name}%{tab}%{window-title}%{tab}%{workspace}%{tab}%{app-bundle-path}%{tab}%{monitor-id}'
    ///
    /// Window titles can contain almost anything (pipes, asterisks, brackets) but never a literal
    /// tab, so splitting on "\t" is unambiguous. `app-bundle-path` is legitimately empty for some
    /// processes (e.g. background helpers with no `.app` bundle), so it is optional.
    static func parseWindows(_ output: String) -> [SwitcherItem] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 6 else { return nil }
            guard let windowID = Int(fields[0]) else { return nil }
            let appName = fields[1]
            let title = fields[2]
            let workspace = fields[3]
            let bundlePath = fields[4].isEmpty ? nil : fields[4]
            guard let monitorID = Int(fields[5]) else { return nil }
            return SwitcherItem.window(
                id: windowID,
                appName: appName,
                title: title,
                workspace: workspace,
                appBundlePath: bundlePath,
                monitorID: monitorID
            )
        }
    }
}
