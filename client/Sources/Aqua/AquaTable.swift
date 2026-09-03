import Cocoa

/// Row view with the classic pale-blue stripe and gradient selection.
final class AquaRowView: NSTableRowView {
    enum SelectionStyle { case blue, sidebar }
    var striped = false
    var alternate = false
    var plainBackground: NSColor = .white
    var selectionStyle: SelectionStyle = .blue

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {
        (striped && alternate ? Aqua.stripe : plainBackground).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        switch selectionStyle {
        case .blue:
            let top = isEmphasized ? Aqua.selectionTopKey : Aqua.selectionTopInactive
            let bottom = isEmphasized ? Aqua.selectionBottomKey : Aqua.selectionBottomInactive
            NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: -90)
        case .sidebar:
            // The dark slate bar iTunes drew behind the chosen source.
            let top = isEmphasized ? NSColor(srgbRed: 0.36, green: 0.44, blue: 0.55, alpha: 1) : NSColor(white: 0.66, alpha: 1)
            let bottom = isEmphasized ? NSColor(srgbRed: 0.19, green: 0.26, blue: 0.36, alpha: 1) : NSColor(white: 0.52, alpha: 1)
            NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: -90)
            (isEmphasized ? NSColor(srgbRed: 0.13, green: 0.19, blue: 0.28, alpha: 1) : NSColor(white: 0.45, alpha: 1)).setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
    }
}

/// Header cell: light gradient, hairline dividers, blue tint on the sort
/// column, and a small dark sort triangle.
final class AquaHeaderCell: NSTableHeaderCell {
    var sortKey: String?

    private func isSortColumn(_ controlView: NSView) -> Bool {
        guard let key = sortKey, let hv = controlView as? NSTableHeaderView,
              let d = hv.tableView?.sortDescriptors.first else { return false }
        return d.key == key
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let sorted = isSortColumn(controlView)
        let top = sorted ? NSColor(srgbRed: 0.85, green: 0.90, blue: 0.97, alpha: 1) : NSColor(white: 1.0, alpha: 1)
        let bottom = sorted ? NSColor(srgbRed: 0.72, green: 0.80, blue: 0.93, alpha: 1) : NSColor(white: 0.87, alpha: 1)
        NSGradient(starting: top, ending: bottom)!.draw(in: cellFrame, angle: -90)
        NSColor(white: 0.60, alpha: 1).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width, height: 1).fill()
        NSColor(white: 0.70, alpha: 1).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 1, width: 1, height: cellFrame.height - 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment == .right ? .right : .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(11), .foregroundColor: NSColor.black, .paragraphStyle: style,
        ]
        let inset = cellFrame.insetBy(dx: 5, dy: 0)
        let textRect = NSRect(x: inset.minX, y: cellFrame.midY - 7, width: inset.width - 10, height: 15)
        (stringValue as NSString).draw(in: textRect, withAttributes: attrs)
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        let size: CGFloat = 7
        let x = cellFrame.maxX - size - 6
        let y = cellFrame.midY
        let tri = NSBezierPath()
        if ascending {
            tri.move(to: NSPoint(x: x, y: y - size / 2))
            tri.line(to: NSPoint(x: x + size, y: y - size / 2))
            tri.line(to: NSPoint(x: x + size / 2, y: y + size / 2))
        } else {
            tri.move(to: NSPoint(x: x, y: y + size / 2))
            tri.line(to: NSPoint(x: x + size, y: y + size / 2))
            tri.line(to: NSPoint(x: x + size / 2, y: y - size / 2))
        }
        tri.close()
        NSColor(white: 0.25, alpha: 1).setFill()
        tri.fill()
    }
}

/// Header view with the height the old tables had.
final class AquaHeaderView: NSTableHeaderView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }
}

enum AquaTables {
    /// Applies the shared look to a table. Callers still supply row views.
    static func style(_ table: NSTableView, rowHeight: CGFloat = 18, background: NSColor = .white, header: Bool) {
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 3, height: 0)
        table.backgroundColor = background
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = false
        table.gridColor = Aqua.gridLine
        table.gridStyleMask = header ? [.solidVerticalGridLineMask] : []
        table.focusRingType = .none
        if header {
            let hv = AquaHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 18))
            table.headerView = hv
        } else {
            table.headerView = nil
        }
    }

    static func column(_ id: String, title: String, width: CGFloat, min: CGFloat = 40, sortable: Bool = true, rightAligned: Bool = false) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        let cell = AquaHeaderCell(textCell: title)
        cell.sortKey = sortable ? id : nil
        cell.alignment = rightAligned ? .right : .left
        c.headerCell = cell
        c.width = width
        c.minWidth = min
        c.resizingMask = .userResizingMask
        if sortable {
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        }
        return c
    }

    /// A reusable label cell. Text colour is semantic so it flips to white on
    /// an emphasized (selected) row automatically.
    static func labelCell(_ table: NSTableView, id: String, size: CGFloat = 11, rightAligned: Bool = false) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier("cell." + id)
        if let v = table.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView {
            return v
        }
        let cell = NSTableCellView()
        cell.identifier = ident
        let label = NSTextField(labelWithString: "")
        label.font = Aqua.font(size)
        label.textColor = .controlTextColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = rightAligned ? .right : .left
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func rowView(_ table: NSTableView, row: Int, striped: Bool, background: NSColor = .white,
                        selection: AquaRowView.SelectionStyle = .blue) -> AquaRowView {
        let ident = NSUserInterfaceItemIdentifier("row")
        let v = (table.makeView(withIdentifier: ident, owner: nil) as? AquaRowView) ?? AquaRowView()
        v.identifier = ident
        v.striped = striped
        v.alternate = row % 2 == 1
        v.plainBackground = background
        v.selectionStyle = selection
        return v
    }
}
