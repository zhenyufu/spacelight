import AppKit

/// One row in the result list: icon, primary label, secondary label, and a rounded selection pill
/// drawn by the view itself rather than the table's built-in highlight (`SwitcherViewController`
/// sets `selectionHighlightStyle = .none` for exactly this reason), which is what lets the
/// selection color and shape match the rest of the panel's chrome instead of the system default.
final class ResultRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ResultRowView")

    private enum Metric {
        static let iconSize: CGFloat = 28
        static let horizontalInset: CGFloat = 16
        static let interItemSpacing: CGFloat = 10
        static let pillInset: CGFloat = 6
        static let pillCornerRadius: CGFloat = 8
    }

    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let selectionPill = NSView()

    private var isRowSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        selectionPill.wantsLayer = true
        selectionPill.layer?.cornerRadius = Metric.pillCornerRadius
        selectionPill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionPill)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        primaryLabel.font = .systemFont(ofSize: 14, weight: .regular)
        primaryLabel.textColor = .labelColor
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(primaryLabel)

        secondaryLabel.font = .systemFont(ofSize: 12, weight: .regular)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secondaryLabel)

        NSLayoutConstraint.activate([
            selectionPill.topAnchor.constraint(equalTo: topAnchor, constant: Metric.pillInset / 2),
            selectionPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metric.pillInset / 2),
            selectionPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.pillInset),
            selectionPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.pillInset),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.horizontalInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metric.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metric.iconSize),

            primaryLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Metric.interItemSpacing),
            primaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metric.horizontalInset),
            primaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            secondaryLabel.leadingAnchor.constraint(equalTo: primaryLabel.leadingAnchor),
            secondaryLabel.trailingAnchor.constraint(equalTo: primaryLabel.trailingAnchor),
            secondaryLabel.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 1),
        ])

        updateSelectionAppearance()
    }

    func configure(item: SwitcherItem, icon: NSImage, isSelected: Bool) {
        iconView.image = icon
        primaryLabel.stringValue = item.displayText
        secondaryLabel.stringValue = subtitle(for: item)
        self.isRowSelected = isSelected
        updateSelectionAppearance()
    }

    private func subtitle(for item: SwitcherItem) -> String {
        switch item.kind {
        case .workspace:
            // Every workspace shown here is non-empty (StateStore only lists ones with windows,
            // via `aerospace list-workspaces --empty no`), so windowSummary should always be
            // present; "Workspace" is just a defensive fallback for the rare race where every
            // window in it closed between the two halves of a snapshot.
            return item.windowSummary ?? "Workspace"
        case .window(let appName, _, let workspace):
            return "\(appName) · \(workspace)"
        }
    }

    private func updateSelectionAppearance() {
        guard isRowSelected else {
            selectionPill.layer?.backgroundColor = NSColor.clear.cgColor
            primaryLabel.textColor = .labelColor
            secondaryLabel.textColor = .secondaryLabelColor
            return
        }

        selectionPill.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        primaryLabel.textColor = .selectedMenuItemTextColor
        secondaryLabel.textColor = NSColor.selectedMenuItemTextColor.withAlphaComponent(0.7)
    }
}
