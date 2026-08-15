import Foundation

/// Owns the last known snapshot and the current filtered/ranked result list. Runs on the main
/// actor: filtering a few hundred short precomputed haystacks is fast enough to do synchronously
/// on every keystroke (see PLAN.md's latency budget), so there's no need to push it to a background
/// actor and pay a hop for it.
///
/// One merged list: workspaces first, then windows, matching the order the original `ff()` shell
/// function presented them in.
@MainActor
final class StateStore {
    private let aeroSpace: AeroSpaceClient
    private var allItems: [SwitcherItem] = []
    private(set) var query: String = ""
    private(set) var results: [SwitcherItem] = []

    init(aeroSpace: AeroSpaceClient) {
        self.aeroSpace = aeroSpace
    }

    /// Re-queries AeroSpace and re-applies the current filter. Called on every panel show and,
    /// via `EventSubscriber`, on relevant AeroSpace events.
    func refresh() async {
        do {
            let snapshot = try await aeroSpace.snapshot()
            allItems = snapshot.workspaces.map { withWindowSummary($0, allWindows: snapshot.windows) }
                + snapshot.windows
            refilter()
        } catch {
            // Leave the previous snapshot in place rather than clearing the list on a transient
            // failure; a stale-but-present list beats an empty panel.
        }
    }

    /// Fills in `windowSummary` for a workspace item: a comma-joined list of the (deduplicated,
    /// order-preserving) app names of the windows AeroSpace reports as belonging to it. This has
    /// to happen here rather than in `SwitcherItem.workspace(...)` because it needs the window
    /// list, which isn't available until both halves of the snapshot have come back.
    private func withWindowSummary(_ workspaceItem: SwitcherItem, allWindows: [SwitcherItem]) -> SwitcherItem {
        guard let name = workspaceItem.workspaceName else { return workspaceItem }
        var seenAppNames = Set<String>()
        var appNames: [String] = []
        for window in allWindows where window.workspaceName == name {
            guard case .window(let appName, _, _) = window.kind else { continue }
            if seenAppNames.insert(appName).inserted {
                appNames.append(appName)
            }
        }
        var item = workspaceItem
        item.windowSummary = appNames.joined(separator: ", ")
        return item
    }

    func setQuery(_ query: String) {
        self.query = query
        refilter()
    }

    private func refilter() {
        guard !query.isEmpty else {
            // AeroSpace's own listing order for workspaces, then windows.
            results = allItems
            return
        }

        // FuzzyMatcher expects an already-lowercased query (see its doc comment); lowercasing once
        // per keystroke here, rather than once per item, is the whole point of that contract.
        let loweredQuery = query.lowercased()
        results = allItems
            .compactMap { item -> (SwitcherItem, Int)? in
                guard let score = FuzzyMatcher.score(query: loweredQuery, haystack: item.searchHaystack) else {
                    return nil
                }
                return (item, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                // Tie-break: workspaces above windows, then alphabetical for stable ordering.
                if lhs.0.isWorkspace != rhs.0.isWorkspace { return lhs.0.isWorkspace }
                return lhs.0.displayText.localizedStandardCompare(rhs.0.displayText) == .orderedAscending
            }
            .map(\.0)
    }
}
