import Cocoa

/// Row view with the classic pale-blue stripe and gradient selection.
final class AquaRowView: NSTableRowView {
    enum SelectionStyle { case blue, sidebar }
    var striped = false
    var alternate = false
    var plainBackground: NSColor = .white
    var selectionStyle: SelectionStyle = .blue

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // Modern: white text only on the accent pill of a focused table; the
        // grey pill of an unfocused one, and the sidebar's, keep dark text.
        if Theme.isModern { return isSelected && isEmphasized && selectionStyle == .blue ? .emphasized : .normal }
        return isSelected ? .emphasized : .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {
        (striped && alternate ? (Theme.isModern ? Theme.stripe : Aqua.stripe) : plainBackground).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if Theme.isModern {
            let pill = Theme.selectionPill(in: bounds)
            switch selectionStyle {
            case .blue: (isEmphasized ? Theme.accent : NSColor(white: 0, alpha: 0.10)).setFill()
            case .sidebar: NSColor(white: 0, alpha: isEmphasized ? 0.10 : 0.07).setFill()
            }
            pill.fill()
            return
        }
        switch selectionStyle {
        case .blue:
            let top = isEmphasized ? Aqua.selectionTopKey : Aqua.selectionTopInactive
            let bottom = isEmphasized ? Aqua.selectionBottomKey : Aqua.selectionBottomInactive
            NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: -90)
        case .sidebar:
            // iTunes 10's sidebar bar: the blue gradient with a darker top line.
            let top = isEmphasized ? NSColor(srgbRed: 0.40, green: 0.58, blue: 0.87, alpha: 1) : NSColor(white: 0.70, alpha: 1)
            let bottom = isEmphasized ? NSColor(srgbRed: 0.18, green: 0.39, blue: 0.78, alpha: 1) : NSColor(white: 0.56, alpha: 1)
            NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: -90)
            (isEmphasized ? NSColor(srgbRed: 0.14, green: 0.32, blue: 0.68, alpha: 1) : NSColor(white: 0.48, alpha: 1)).setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
    }
}

/// Header cell: light gradient, hairline dividers, blue tint on the sort
/// column, and a small dark sort triangle.
final class AquaHeaderCell: NSTableHeaderCell {
    var sortKey: String?

    /// The sort direction when this column is the one being sorted on, and
    /// nil when it is not.
    private func sortDirection(_ controlView: NSView) -> Bool? {
        guard let key = sortKey, let hv = controlView as? NSTableHeaderView,
              let d = hv.tableView?.sortDescriptors.first, d.key == key else { return nil }
        return d.ascending
    }

    private func isSortColumn(_ controlView: NSView) -> Bool {
        sortDirection(controlView) != nil
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let ascending = sortDirection(controlView)
        let sorted = ascending != nil
        if Theme.isModern {
            NSColor(white: 0.985, alpha: 1).setFill()
            cellFrame.fill()
            Theme.hairline.setFill()
            NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width, height: 1).fill()
            NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 4, width: 1, height: cellFrame.height - 8).fill()
            drawInterior(withFrame: cellFrame, in: controlView)
            if let ascending = ascending {
                drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
            }
            return
        }
        let top = sorted ? NSColor(srgbRed: 0.85, green: 0.90, blue: 0.97, alpha: 1) : NSColor(white: 1.0, alpha: 1)
        let bottom = sorted ? NSColor(srgbRed: 0.72, green: 0.80, blue: 0.93, alpha: 1) : NSColor(white: 0.87, alpha: 1)
        NSGradient(starting: top, ending: bottom)!.draw(in: cellFrame, angle: -90)
        NSColor(white: 0.60, alpha: 1).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width, height: 1).fill()
        NSColor(white: 0.70, alpha: 1).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 1, width: 1, height: cellFrame.height - 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
        // AppKit only calls drawSortIndicator when the table has been given an
        // indicator image for the column, which this app never does — so draw
        // it here, on the sorted column, at the right-hand edge.
        if let ascending = ascending {
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment == .right ? .right : .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.isModern ? NSFont.systemFont(ofSize: 11, weight: .medium) : Aqua.font(11),
            .foregroundColor: Theme.isModern ? (isSortColumn(controlView) ? Theme.text : Theme.secondaryText) : NSColor.black,
            .paragraphStyle: style,
        ]
        let inset = cellFrame.insetBy(dx: 5, dy: 0)
        // Keep the title clear of the sort triangle, which sits at the right
        // edge — right-aligned titles would otherwise run straight under it.
        let reserve: CGFloat = isSortColumn(controlView) ? 13 : 0
        let textRect = NSRect(x: inset.minX, y: cellFrame.midY - 7,
                              width: max(0, inset.width - 10 - reserve), height: 15)
        (stringValue as NSString).draw(in: textRect, withAttributes: attrs)
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        let size: CGFloat = 7
        let x = cellFrame.maxX - size - 6
        let y = cellFrame.midY
        // Ascending points up on screen. The header view is flipped, so the
        // apex has to sit at the smaller y there and the larger y otherwise —
        // hard-coding one of them drew every arrow the wrong way round.
        let pointsUpOnScreen = ascending
        // In a flipped view the smaller y is the top of the screen, so the
        // apex goes there exactly when those two agree.
        let apexAtSmallerY = pointsUpOnScreen == controlView.isFlipped
        let apexY = apexAtSmallerY ? y - size / 2 : y + size / 2
        let baseY = apexAtSmallerY ? y + size / 2 : y - size / 2
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: x, y: baseY))
        tri.line(to: NSPoint(x: x + size, y: baseY))
        tri.line(to: NSPoint(x: x + size / 2, y: apexY))
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
        table.gridColor = Theme.isModern ? Theme.hairline : Aqua.gridLine
        table.gridStyleMask = header && !Theme.isModern ? [.solidVerticalGridLineMask] : []
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


/// A table whose column grid lines stop at album header rows, so the Album
/// List's headers are not sliced by dividers.
final class AquaTableView: NSTableView {
    var isGroupRowProvider: (Int) -> Bool = { _ in false }

    override func drawGrid(inClipRect clipRect: NSRect) {
        let range = rows(in: clipRect)
        guard range.length > 0 else {
            super.drawGrid(inClipRect: clipRect)
            return
        }
        for row in range.location..<(range.location + range.length) where !isGroupRowProvider(row) {
            let r = rect(ofRow: row).intersection(clipRect)
            if !r.isEmpty { super.drawGrid(inClipRect: r) }
        }
        let last = rect(ofRow: range.location + range.length - 1)
        if clipRect.maxY > last.maxY {
            super.drawGrid(inClipRect: NSRect(x: clipRect.minX, y: last.maxY, width: clipRect.width, height: clipRect.maxY - last.maxY))
        }
    }
}
