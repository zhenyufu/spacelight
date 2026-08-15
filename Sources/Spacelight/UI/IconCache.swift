import AppKit

/// Maps an app bundle path to its icon, memoized so repeated rows for the same app (very common:
/// several Chrome windows in one snapshot) only pay `NSWorkspace`'s icon lookup once each.
@MainActor
final class IconCache {
    private var cache: [String: NSImage] = [:]
    private let genericDocumentIcon = NSWorkspace.shared.icon(for: .item)
    /// Used for workspace rows, which never have a bundle path of their own.
    let workspaceIcon = NSImage(
        systemSymbolName: "square.grid.2x2",
        accessibilityDescription: "Workspace"
    ) ?? NSImage()

    func icon(forBundlePath path: String?) -> NSImage {
        guard let path else { return genericDocumentIcon }
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }

    func icon(for item: SwitcherItem) -> NSImage {
        switch item.kind {
        case .workspace:
            return workspaceIcon
        case .window(_, let appBundlePath, _):
            return icon(forBundlePath: appBundlePath)
        }
    }
}
