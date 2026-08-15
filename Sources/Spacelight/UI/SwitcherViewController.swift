import AppKit

/// Hosts the blur background, search field, and result list inside `SwitcherPanel`.
final class SwitcherViewController: NSViewController {
    // Layout metrics tuned against real Spotlight; see PLAN.md's "The panel" section.
    // `panelWidth` is the single source of truth for the panel's width; `SwitcherPanel` reads it
    // via `preferredWidth` below rather than keeping its own copy.
    enum Metric {
        static let panelWidth: CGFloat = 720
        static let cornerRadius: CGFloat = 20
        static let searchFieldHeight: CGFloat = 68
        static let searchFieldFontSize: CGFloat = 24
        static let searchFieldLeadingInset: CGFloat = 24
        static let rowHeight: CGFloat = 44
        static let maxVisibleRows = 9
        static let separatorHeight: CGFloat = 1
    }

    private let visualEffectView = NSVisualEffectView()
    private let searchField = NSTextField()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var items: [SwitcherItem] = []
    private var iconCache: IconCache?
    private(set) var selectedIndex = 0

    /// Called with the current text every time it changes, so the owner (agent) can re-filter.
    var onQueryChanged: ((String) -> Void)?
    /// Called when the user commits a selection (Return or click) with a non-empty result list.
    var onAcceptItem: ((SwitcherItem) -> Void)?
    /// Called when the user cancels (Escape).
    var onCancel: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Metric.panelWidth, height: Metric.searchFieldHeight))
        view = root
        setUpVisualEffectView()
        setUpSearchField()
        setUpSeparator()
        setUpTable()
        setUpConstraints()
    }

    // MARK: - Subview setup

    private func setUpVisualEffectView() {
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = Metric.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(visualEffectView)
    }

    private func setUpSearchField() {
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: Metric.searchFieldFontSize, weight: .regular)
        searchField.textColor = .labelColor
        searchField.placeholderString = "Search workspaces and windows"
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(searchField)
    }

    private func setUpSeparator() {
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(separator)
    }

    private func setUpTable() {
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none // rows draw their own selection pill
        tableView.rowHeight = Metric.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(handleRowClicked)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: .init("main"))
        column.width = Metric.panelWidth
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(scrollView)
    }

    private func setUpConstraints() {
        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: view.topAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // The search field is centered within the search area rather than pinned to its top
            // with a fixed height: an NSTextField draws its single line of text toward the top of
            // its own frame, so stretching the field to the full 68pt area left the text visibly
            // riding high instead of sitting centered. Letting the field keep its intrinsic
            // (text-sized) height and centering that in the area is what actually centers the text,
            // without hand-tuning a magic top inset that would drift if the font size changed.
            searchField.centerYAnchor.constraint(
                equalTo: visualEffectView.topAnchor,
                constant: Metric.searchFieldHeight / 2
            ),
            searchField.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: Metric.searchFieldLeadingInset),
            searchField.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -Metric.searchFieldLeadingInset),

            separator.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: Metric.searchFieldHeight),
            separator.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: Metric.separatorHeight),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Total height needed to show `rowCount` rows (capped at `Metric.maxVisibleRows`), plus the
    /// search field and separator. `SwitcherPanel` resizes to this every time the result set changes.
    func preferredHeight(forRowCount rowCount: Int) -> CGFloat {
        let visibleRows = min(rowCount, Metric.maxVisibleRows)
        let listHeight = CGFloat(visibleRows) * Metric.rowHeight
        return Metric.searchFieldHeight + Metric.separatorHeight + listHeight
    }

    var preferredWidth: CGFloat { Metric.panelWidth }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    /// Clears the search field and resets the selection back to the top.
    ///
    /// Setting `stringValue` programmatically does **not** fire `controlTextDidChange`, so the
    /// owner's `onQueryChanged` callback has to be invoked explicitly here. Without that, the panel
    /// reopened still showing the previous session's filtered results even though the visible text
    /// field looked empty, because `StateStore` never learned the query had been cleared.
    func clearQuery() {
        searchField.stringValue = ""
        selectedIndex = 0
        onQueryChanged?("")
    }

    /// Replaces the visible result list. Selection is clamped into the new bounds rather than
    /// reset to 0 outright, so that e.g. narrowing a query doesn't jump the selection away from
    /// a still-present top match. `iconCache` is passed in per call rather than owned here, since
    /// `AppDelegate` owns its lifetime alongside `StateStore`.
    func setItems(_ items: [SwitcherItem], iconCache: IconCache) {
        self.items = items
        self.iconCache = iconCache
        selectedIndex = items.isEmpty ? 0 : min(selectedIndex, items.count - 1)
        tableView.reloadData()
        if !items.isEmpty {
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// +1 moves the selection down, -1 moves it up, clamped at the ends (no wraparound).
    /// Driven by both arrow keys (via `doCommandBy:` below) and ⌃J/⌃K (via `SwitcherPanel`).
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let old = selectedIndex
        selectedIndex = max(0, min(items.count - 1, selectedIndex + delta))
        guard selectedIndex != old else { return }
        reloadSelectionRows(old: old, new: selectedIndex)
    }

    /// Jumps directly to a zero-based row index; used by row clicks (see `handleRowClicked`
    /// below). Out-of-range indexes are silently ignored rather than clamped.
    func jumpToIndex(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let old = selectedIndex
        selectedIndex = index
        guard selectedIndex != old else { return }
        reloadSelectionRows(old: old, new: selectedIndex)
    }

    private func reloadSelectionRows(old: Int, new: Int) {
        let indexes = IndexSet([old, new].filter { items.indices.contains($0) })
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        tableView.scrollRowToVisible(new)
    }

    func acceptSelection() {
        guard items.indices.contains(selectedIndex) else { return }
        onAcceptItem?(items[selectedIndex])
    }

    /// `NSTableView.clickedRow` is populated on mouse tracking independent of the table's own
    /// (deliberately disabled, see `shouldSelectRow` below) selection machinery, so a single click
    /// on a row both selects and accepts it, matching Spotlight's own click behavior.
    @objc private func handleRowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        jumpToIndex(row)
        acceptSelection()
    }
}

// MARK: - NSTextFieldDelegate / key handling

extension SwitcherViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obligation: Notification) {
        onQueryChanged?(searchField.stringValue)
    }

    /// The correct AppKit seam for intercepting navigation keys without breaking normal text
    /// editing (selection, cursor movement, etc. all still flow through the field editor).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            acceptSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

// MARK: - Table

extension SwitcherViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rowView = tableView.makeView(withIdentifier: ResultRowView.reuseIdentifier, owner: self) as? ResultRowView
            ?? ResultRowView()
        rowView.identifier = ResultRowView.reuseIdentifier
        let item = items[row]
        let icon = iconCache?.icon(for: item) ?? NSImage()
        rowView.configure(item: item, icon: icon, isSelected: row == selectedIndex)
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Metric.rowHeight
    }

    // Rows draw their own selection pill (see ResultRowView), so the table's own selection model
    // is deliberately left untouched; clicking a row still selects and accepts it via the mouse
    // handling above rather than through NSTableView's selection machinery.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
