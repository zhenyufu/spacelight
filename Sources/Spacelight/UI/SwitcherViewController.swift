import AppKit

/// Which of the two input modes the panel is in.
///
/// The panel is modal (in the vim sense) so that bare `j` / `k` can navigate. That only works
/// while the search field does *not* hold focus: with focus in a text field, a bare `j` is a
/// character the user is trying to type, and there is no way to tell "navigate" from "first letter
/// of a query starting with j" at the moment the key is pressed.
enum InputMode {
    /// Search field unfocused. Bare `j`/`k` and arrows move the selection, `/` starts a search.
    case navigation
    /// Search field focused and filtering. Arrows still move the selection; Esc returns to
    /// `.navigation`.
    case search
}

/// Hosts the blur background, search field, and result list inside `SwitcherPanel`.
final class SwitcherViewController: NSViewController {
    // Layout metrics tuned against real Spotlight.
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
        static let footerHeight: CGFloat = 28
        static let footerFontSize: CGFloat = 11
        static let footerLeadingInset: CGFloat = 16
    }

    private let visualEffectView = NSVisualEffectView()
    private let searchField = NSTextField()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let footerSeparator = NSBox()
    private let footerLabel = NSTextField(labelWithString: "")

    private var items: [SwitcherItem] = []
    private var iconCache: IconCache?
    private(set) var selectedIndex = 0
    private(set) var mode: InputMode = .navigation

    /// Whether the user has moved the selection themselves since the panel was last opened.
    ///
    /// Until they have, an incoming `setItems` re-points the selection at the current workspace.
    /// That matters because the panel is shown immediately against a possibly empty cache and the
    /// real snapshot lands asynchronously a moment later (see `AppDelegate.showPanel`): without
    /// this, the very first open of a session would highlight row 0 rather than where you are.
    /// Once the user has pressed j/k, their choice wins and background refreshes leave it alone.
    private var userHasAdjustedSelection = false

    /// Called with the current text every time it changes, so the owner (agent) can re-filter.
    var onQueryChanged: ((String) -> Void)?
    /// Called when the user commits a selection (Return or click) with a non-empty result list.
    var onAcceptItem: ((SwitcherItem) -> Void)?
    /// Called when the user wants to dismiss the panel entirely (Esc in navigation mode).
    var onCancel: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Metric.panelWidth, height: Metric.searchFieldHeight))
        view = root
        setUpVisualEffectView()
        setUpSearchField()
        setUpSeparator()
        setUpTable()
        setUpFooter()
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

    private func setUpFooter() {
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(footerSeparator)

        footerLabel.font = .systemFont(ofSize: Metric.footerFontSize, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(footerLabel)
        updateFooter()
    }

    /// The footer lists only the keys that actually do something in the current mode. Showing the
    /// navigation keys while searching would be actively misleading, since `j`/`k` are ordinary
    /// typed characters there rather than commands.
    private func updateFooter() {
        switch mode {
        case .navigation:
            footerLabel.attributedStringValue = Self.footerText([
                (keys: ["↑↓", "jk"], joinedBy: " or ", label: "navigate"),
                (keys: ["⏎"], joinedBy: "", label: "open"),
                (keys: ["/"], joinedBy: "", label: "search"),
                (keys: ["esc"], joinedBy: "", label: "close"),
            ])
        case .search:
            footerLabel.attributedStringValue = Self.footerText([
                (keys: ["↑↓"], joinedBy: "", label: "navigate"),
                (keys: ["⏎"], joinedBy: "", label: "open"),
                (keys: ["esc"], joinedBy: "", label: "cancel search"),
            ])
        }
    }

    /// Renders footer hints with the key names emphasized and their descriptions muted, so the
    /// keys are scannable at a glance without the whole line competing with the result list.
    /// Bold alone would barely register at 11pt in `secondaryLabelColor`, so the keys also step up
    /// to full `labelColor`; the two changes together are what make them read as keys.
    private static func footerText(
        _ groups: [(keys: [String], joinedBy: String, label: String)]
    ) -> NSAttributedString {
        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Metric.footerFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Metric.footerFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let result = NSMutableAttributedString()
        for (index, group) in groups.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "   ·   ", attributes: labelAttributes))
            }
            for (keyIndex, key) in group.keys.enumerated() {
                if keyIndex > 0 {
                    result.append(NSAttributedString(string: group.joinedBy, attributes: labelAttributes))
                }
                result.append(NSAttributedString(string: key, attributes: keyAttributes))
            }
            result.append(NSAttributedString(string: "  \(group.label)", attributes: labelAttributes))
        }
        return result
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
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),

            footerSeparator.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: Metric.separatorHeight),
            footerSeparator.bottomAnchor.constraint(
                equalTo: visualEffectView.bottomAnchor,
                constant: -Metric.footerHeight
            ),

            // Centered in the footer strip for the same reason the search field is centered in
            // its own area: a label draws its text toward the top of its frame.
            footerLabel.centerYAnchor.constraint(
                equalTo: visualEffectView.bottomAnchor,
                constant: -Metric.footerHeight / 2
            ),
            footerLabel.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: Metric.footerLeadingInset),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: visualEffectView.trailingAnchor, constant: -Metric.footerLeadingInset),
        ])
    }

    // MARK: - Public API

    /// Total height needed to show `rowCount` rows (capped at `Metric.maxVisibleRows`), plus the
    /// search field and separator. `SwitcherPanel` resizes to this every time the result set changes.
    func preferredHeight(forRowCount rowCount: Int) -> CGFloat {
        let visibleRows = min(rowCount, Metric.maxVisibleRows)
        let listHeight = CGFloat(visibleRows) * Metric.rowHeight
        // Two separators: one under the search field, one above the footer.
        return Metric.searchFieldHeight
            + Metric.separatorHeight
            + listHeight
            + Metric.separatorHeight
            + Metric.footerHeight
    }

    var preferredWidth: CGFloat { Metric.panelWidth }

    /// Enters search mode: focuses the search field so typing filters. Triggered by `/`.
    func enterSearchMode() {
        guard mode != .search else { return }
        mode = .search
        searchField.placeholderString = "Search workspaces and windows"
        updateFooter()
        view.window?.makeFirstResponder(searchField)
    }

    /// Returns to navigation mode: clears any query and drops focus from the search field so bare
    /// `j` / `k` are free to navigate again.
    ///
    /// Resigning first responder is what actually makes navigation-mode keys reachable: with the
    /// field focused, every bare keystroke is consumed by the field editor and never reaches
    /// `SwitcherPanel.keyDown`.
    func enterNavigationMode() {
        mode = .navigation
        // Placeholder doubles as the only mode indicator, so the panel doesn't need extra chrome
        // to tell the user that typing won't do what they expect until they press "/".
        searchField.placeholderString = "Press / to search"
        updateFooter()
        clearQuery()
        view.window?.makeFirstResponder(nil)
    }

    /// Clears the search field and re-filters.
    ///
    /// Setting `stringValue` programmatically does **not** fire `controlTextDidChange`, so the
    /// owner's `onQueryChanged` callback has to be invoked explicitly here. Without that, the panel
    /// reopened still showing the previous session's filtered results even though the visible text
    /// field looked empty, because `StateStore` never learned the query had been cleared.
    func clearQuery() {
        searchField.stringValue = ""
        onQueryChanged?("")
    }

    /// Selects the row for the currently focused AeroSpace workspace, so the panel opens oriented
    /// at where you already are. Falls back to the first row when there's no focused workspace in
    /// the list (e.g. an active filter excluded it).
    func selectCurrentWorkspace() {
        userHasAdjustedSelection = false
        selectedIndex = indexOfCurrentWorkspace() ?? 0
        guard !items.isEmpty else { return }
        tableView.reloadData()
        scrollToTop()
    }

    /// Pins the list to the very top, as opposed to `scrollRowToVisible`, which performs the
    /// *minimum* scroll needed to expose a row and therefore leaves the list wherever it happens
    /// to already be. That made the panel open inconsistently: depending on the previous scroll
    /// offset the highlighted workspace could appear at the top, in the middle, or at the bottom.
    /// The list always starting at row 0 is what makes the panel look the same every time.
    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The list's current vertical scroll offset. Exposed so a test can assert the panel always
    /// opens pinned to the top rather than wherever it was left.
    var verticalScrollOffset: CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    private func indexOfCurrentWorkspace() -> Int? {
        items.firstIndex { item in
            if case .workspace(let isFocused, _) = item.kind { return isFocused }
            return false
        }
    }

    /// Handles a key press that reached the window because nothing else claimed it, which in
    /// practice means navigation mode (in search mode the field editor consumes these first).
    /// Returns true if the key was handled.
    func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard mode == .navigation else { return false }
        // Only bare keystrokes drive navigation, so anything held down with Command, Control or
        // Option falls through and system/app shortcuts keep working.
        //
        // `.function`, `.numericPad` and `.capsLock` are explicitly *not* treated as "held down":
        // macOS sets .function and .numericPad on the arrow keys themselves, so a naive
        // `flags.isEmpty` check silently rejected every arrow press before it could be matched
        // below. Caps lock is excluded for the same reason — it should never disable navigation.
        let ignoredFlags: NSEvent.ModifierFlags = [.function, .numericPad, .capsLock]
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredFlags)
        guard flags.isEmpty || flags == .shift else { return false }

        switch event.charactersIgnoringModifiers {
        case "j":
            moveSelection(by: 1)
            return true
        case "k":
            moveSelection(by: -1)
            return true
        case "/":
            enterSearchMode()
            return true
        default:
            break
        }

        // Arrow keys, Return and Escape arrive as control characters rather than as the literal
        // strings above, so they're matched on key code instead.
        switch event.keyCode {
        case 125: // down arrow
            moveSelection(by: 1)
            return true
        case 126: // up arrow
            moveSelection(by: -1)
            return true
        case 36, 76: // Return, keypad Enter
            acceptSelection()
            return true
        case 53: // Escape
            onCancel?()
            return true
        default:
            return false
        }
    }

    /// Replaces the visible result list. Selection is clamped into the new bounds rather than
    /// reset to 0 outright, so that e.g. narrowing a query doesn't jump the selection away from
    /// a still-present top match. `iconCache` is passed in per call rather than owned here, since
    /// `AppDelegate` owns its lifetime alongside `StateStore`.
    func setItems(_ items: [SwitcherItem], iconCache: IconCache) {
        self.items = items
        self.iconCache = iconCache
        // `isFreshlyOpened` covers both halves of an open: the immediate render against the cached
        // snapshot, and the real snapshot landing asynchronously a moment later. Both need to pin
        // the list to the top, or the late arrival would re-scroll to wherever the selected row
        // happens to sit and reintroduce the inconsistent opening position.
        let isFreshlyOpened = mode == .navigation && !userHasAdjustedSelection
        if isFreshlyOpened {
            selectedIndex = indexOfCurrentWorkspace() ?? 0
        } else {
            selectedIndex = items.isEmpty ? 0 : min(selectedIndex, items.count - 1)
        }
        tableView.reloadData()
        guard !items.isEmpty else { return }
        if isFreshlyOpened {
            scrollToTop()
        } else {
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// +1 moves the selection down, -1 moves it up, clamped at the ends (no wraparound).
    /// Driven by bare `j`/`k` and arrows in navigation mode, arrows and ⌃J/⌃K in search mode.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        userHasAdjustedSelection = true
        let old = selectedIndex
        selectedIndex = max(0, min(items.count - 1, selectedIndex + delta))
        guard selectedIndex != old else { return }
        reloadSelectionRows(old: old, new: selectedIndex)
    }

    /// Jumps directly to a zero-based row index; used by row clicks (see `handleRowClicked`
    /// below). Out-of-range indexes are silently ignored rather than clamped.
    func jumpToIndex(_ index: Int) {
        guard items.indices.contains(index) else { return }
        userHasAdjustedSelection = true
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
        // A changed query produces a different result set, so the previous selection index is
        // meaningless against it; jump back to the top match the way any search UI does. Setting
        // the flag keeps `setItems` from overriding this with the current-workspace row.
        selectedIndex = 0
        userHasAdjustedSelection = true
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
            // Two-level escape: the first Esc cancels the search and returns to navigation mode,
            // a second Esc (handled in handleNavigationKey) closes the panel. This mirrors how Esc
            // behaves in vim-style search and means a mistyped query never costs the whole session.
            enterNavigationMode()
            selectCurrentWorkspace()
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
