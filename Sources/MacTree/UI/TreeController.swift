import AppKit

/** Actions the node lists forward to the window controller. */
protocol NodeListOwner: AnyObject {
    /**
     * Reports that the user changed the selection in a list.
     *
     * Programmatic selection changes made by the lists themselves are not reported.
     *
     * @param {AnyObject} source - The list that changed (tree or file list controller).
     * @param {[Node]} nodes - The newly selected nodes, possibly empty.
     *
     * @example
     * owner?.list(self, didSelect: outline.selectedNodes)
     */
    func list(_ source: AnyObject, didSelect nodes: [Node])

    /**
     * Builds the context menu for a set of nodes.
     *
     * @param {[Node]} nodes - The nodes the menu should act on.
     * @returns {NSMenu?} The menu, or nil to show none.
     *
     * @example
     * return owner?.contextMenu(for: selectedNodes)
     */
    func contextMenu(for nodes: [Node]) -> NSMenu?

    /**
     * Opens or closes the Quick Look panel for the current selection.
     *
     * @example
     * owner?.toggleQuickLook() // on the space bar
     */
    func toggleQuickLook()

    /**
     * Previews a double-clicked file.
     *
     * @param {Node} node - The file that was double-clicked.
     *
     * @example
     * owner?.openOrQuickLook(rows[row])
     */
    func openOrQuickLook(_ node: Node)

    /**
     * Marks the selection for permanent deletion, or unmarks it.
     *
     * Sent when the user presses Delete in a list. If every selected node is
     * already marked the marks are removed, otherwise the unmarked ones are
     * added. Nothing is deleted until the user confirms Delete Permanently.
     *
     * @example
     * owner?.toggleDeletionMark() // Delete key in the Tree View
     */
    func toggleDeletionMark()
}

/** Outline view that routes right-clicks and the space bar to its owner. */
final class NodeOutlineView: NSOutlineView {
    /** Receives context-menu and Quick Look requests. */
    weak var owner: NodeListOwner?
    /** Nodes in the selected rows. */
    var selectedNodes: [Node] { selectedRowIndexes.compactMap { item(atRow: $0) as? Node } }

    /**
     * Builds the context menu for a right-click.
     *
     * Right-clicking an unselected row selects it first, matching Finder, so
     * the menu always acts on what is highlighted. Clicks outside any row get
     * no menu.
     *
     * @param {NSEvent} event - The right-mouse-down event.
     * @returns {NSMenu?} The owner's menu for the selected nodes, or nil.
     *
     * @example
     * // Called by AppKit on right-click; the owner builds the actual menu.
     */
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return owner?.contextMenu(for: selectedNodes)
    }

    /**
     * Handles the list's own shortcuts; other keys keep their outline behaviour.
     *
     * Space toggles Quick Look. Delete (⌫ or ⌦, without modifiers) marks or
     * unmarks the selection for permanent deletion.
     *
     * @param {NSEvent} event - The key-down event.
     *
     * @example
     * // Pressing Space in the Tree View opens the Quick Look panel.
     */
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            owner?.toggleQuickLook()
        } else if event.isPlainDeleteKey {
            owner?.toggleDeletionMark()
        } else {
            super.keyDown(with: event)
        }
    }
}

/**
 * The "Tree View": folders and files with WizTree's columns.
 *
 * The scan root is the single top-level row. Children are shown in the tree's
 * own order (largest first by the size mode) unless another column is sorted,
 * in which case sorted copies are cached per expanded folder, so the tree
 * itself is never reordered by the outline.
 */
final class TreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /** The outline view. */
    let outline = NodeOutlineView()
    /** Scroll view hosting the outline, placed in the Tree View tab. */
    let scrollView = NSScrollView()
    /** Receives selection, context-menu and Quick Look requests. */
    weak var owner: NodeListOwner?

    /** The scan root shown as the top-level row. */
    private(set) var root: Node?
    /** Size used for percentages and the natural order. */
    var sizeMode: SizeMode = .allocated

    /** Column identifier of the current sort. */
    private var sortKey = NSUserInterfaceItemIdentifier.colAlloc.rawValue
    /** Whether the current sort is ascending. */
    private var ascending = false
    /** Sorted children per folder for non-natural sorts; cleared on any change. */
    private var sortedCache: [ObjectIdentifier: [Node]] = [:]
    /** Set while changing the selection programmatically so the owner is not notified back. */
    private var suppressSelection = false
    /** Tells whether a node is marked for deletion; supplied by the window controller. */
    var isMarked: ((Node) -> Bool)?

    /**
     * Creates the outline with WizTree's columns and its scroll view.
     *
     * Columns: Name, % of Parent, Size, Allocated, Items, Files, Folders and
     * Modified; widths and sort order are autosaved. Double-clicking a folder
     * expands or collapses it, double-clicking a file previews it.
     *
     * @example
     * let tree = TreeController()
     * tree.attach(owner: windowController)
     */
    override init() {
        super.init()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        outline.rowHeight = 20
        outline.intercellSpacing = NSSize(width: 6, height: 0)
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.gridStyleMask = []

        let name = outline.addColumn(.colName, title: L.colName, width: 300, minWidth: 120, ascendingFirst: true)
        outline.outlineTableColumn = name
        outline.addColumn(.colPercent, title: L.colPercent, width: 110, minWidth: 60)
        outline.addColumn(.colSize, title: L.colSize, width: 80, alignment: .right)
        outline.addColumn(.colAlloc, title: L.colAllocated, width: 80, alignment: .right)
        outline.addColumn(.colItems, title: L.colItems, width: 70, alignment: .right)
        outline.addColumn(.colFiles, title: L.colFiles, width: 70, alignment: .right)
        outline.addColumn(.colFolders, title: L.colFolders, width: 60, alignment: .right)
        outline.addColumn(.colModified, title: L.colModified, width: 150)
        outline.autosaveName = "TreeOutline"
        outline.autosaveTableColumns = true

        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    /**
     * Connects the tree and its outline to the object handling selection and menus.
     *
     * @param {NodeListOwner} owner - Usually the main window controller; held weakly.
     *
     * @example
     * tree.attach(owner: self)
     */
    func attach(owner: NodeListOwner) {
        self.owner = owner
        outline.owner = owner
    }

    /**
     * Shows a new tree, or clears the outline.
     *
     * The root is expanded and selected without notifying the owner. A size
     * sort follows the new size mode.
     *
     * @param {Node?} node - The new scan root, or nil to clear.
     * @param {SizeMode} sizeMode - The size used for percentages and ordering.
     *
     * @example
     * tree.setRoot(result.root, sizeMode: .allocated)
     */
    func setRoot(_ node: Node?, sizeMode: SizeMode) {
        self.sizeMode = sizeMode
        root = node
        alignSortKeyWithSizeMode()
        sortedCache.removeAll()
        suppressSelection = true
        outline.reloadData()
        if let node {
            outline.expandItem(node)
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        suppressSelection = false
    }

    /**
     * Reloads after the tree was mutated in place (trash, rescan, size mode change).
     *
     * Drops cached sort orders and restores the selection for nodes that are
     * still in the tree, without notifying the owner. Expanded folders stay
     * expanded because the nodes keep their identity.
     *
     * @example
     * tree.reloadPreservingState()
     */
    func reloadPreservingState() {
        sortedCache.removeAll()
        let selected = outline.selectedNodes
        suppressSelection = true
        outline.reloadData()
        let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        suppressSelection = false
    }

    /**
     * Switches between logical and allocated size.
     *
     * Percentages are recomputed on reload, and a size sort switches to the
     * matching size column.
     *
     * @param {SizeMode} mode - The new size mode.
     *
     * @example
     * tree.setSizeMode(.logical)
     */
    func setSizeMode(_ mode: SizeMode) {
        sizeMode = mode
        alignSortKeyWithSizeMode()
        reloadPreservingState()
    }

    /**
     * Makes a size-column sort follow the Size / Allocated toggle.
     *
     * When the outline is sorted by Size or Allocated (or not sorted yet), the
     * sort moves to the column of the current size mode and the header shows
     * the indicator there. Sorts by other columns are left alone. Setting the
     * sort descriptors triggers `sortDescriptorsDidChange`, which reloads.
     *
     * @example
     * alignSortKeyWithSizeMode() // after sizeMode changed
     */
    private func alignSortKeyWithSizeMode() {
        let sizeKeys = [NSUserInterfaceItemIdentifier.colSize.rawValue, NSUserInterfaceItemIdentifier.colAlloc.rawValue]
        guard sizeKeys.contains(sortKey) || outline.sortDescriptors.isEmpty else { return }
        sortKey = sizeMode == .allocated ? sizeKeys[1] : sizeKeys[0]
        let descriptor = NSSortDescriptor(key: sortKey, ascending: ascending)
        if outline.sortDescriptors.first?.key != sortKey {
            outline.sortDescriptors = [descriptor]
        }
    }

    /**
     * Expands the path to a node, selects it and scrolls it into view.
     *
     * Used to mirror a treemap click; the owner is not notified. Nodes outside
     * the current root are ignored. Expanding a folder with many children
     * makes the outline load all of them, which can take a moment.
     *
     * @param {Node} node - The node to show.
     *
     * @example
     * tree.reveal(clickedNode)
     */
    func reveal(_ node: Node) {
        guard let root, node.isDescendant(of: root) else { return }
        suppressSelection = true
        for a in node.ancestors.reversed() { outline.expandItem(a) }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        suppressSelection = false
    }

    /** Nodes in the selected rows. */
    var selectedNodes: [Node] { outline.selectedNodes }

    /**
     * Updates the red deletion borders of the rows currently on screen.
     *
     * Rows scrolled in later get their state from `rowViewForItem`, so only
     * the existing row views need touching; no reload is required.
     *
     * @example
     * tree.refreshMarks() // after the set of marked nodes changed
     */
    func refreshMarks() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? MarkableRowView, let node = outline.item(atRow: row) as? Node else { return }
            rowView.isMarked = isMarked?(node) ?? false
        }
    }

    // MARK: Ordering

    /** Whether the current sort matches the tree's own order (size mode, largest first). */
    private var usesNaturalOrder: Bool {
        !ascending && (sortKey == NSUserInterfaceItemIdentifier.colPercent.rawValue
                       || sortKey == (sizeMode == .allocated ? NSUserInterfaceItemIdentifier.colAlloc.rawValue
                                                            : NSUserInterfaceItemIdentifier.colSize.rawValue))
    }

    /**
     * Returns a folder's children in display order.
     *
     * Uses `children` directly for the natural order; otherwise sorts a copy
     * once per folder and caches it until the next reload.
     *
     * @param {Node} node - The folder.
     * @returns {[Node]} The children in the current sort order.
     *
     * @example
     * let first = children(of: folder).first
     */
    private func children(of node: Node) -> [Node] {
        if usesNaturalOrder { return node.children }
        let key = ObjectIdentifier(node)
        if let cached = sortedCache[key] { return cached }
        let sorted = NodeSorting.sorted(node.children, key: sortKey, ascending: ascending, mode: sizeMode)
        sortedCache[key] = sorted
        return sorted
    }

    /**
     * Re-sorts after a column header click.
     *
     * @param {NSOutlineView} outlineView - The tree outline.
     * @param {[NSSortDescriptor]} oldDescriptors - The previous sort (unused).
     *
     * @example
     * // Called by NSOutlineView when the user clicks the "Name" header.
     */
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        ascending = d.ascending
        reloadPreservingState()
    }

    // MARK: Data source

    /**
     * Reports the number of children of an item.
     *
     * The invisible top level has exactly one row (the scan root) once a tree is set.
     *
     * @param {NSOutlineView} outlineView - The tree outline.
     * @param {Any?} item - A node, or nil for the top level.
     * @returns {Int} The number of child rows.
     *
     * @example
     * // Called by NSOutlineView when loading or expanding rows.
     */
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard root != nil else { return 0 }
        guard let node = item as? Node else { return 1 }
        return node.children.count
    }

    /**
     * Returns the child at an index of an item, in display order.
     *
     * @param {NSOutlineView} outlineView - The tree outline.
     * @param {Int} index - The child index.
     * @param {Any?} item - A node, or nil for the top level.
     * @returns {Any} The child node (the scan root for the top level).
     *
     * @example
     * // Called by NSOutlineView for each visible row.
     */
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return root! }
        return children(of: node)[index]
    }

    /**
     * Tells whether an item shows a disclosure triangle.
     *
     * @param {NSOutlineView} outlineView - The tree outline.
     * @param {Any} item - A node.
     * @returns {Bool} True for folders that have at least one entry.
     *
     * @example
     * // Called by NSOutlineView when drawing a row.
     */
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.isDir && !node.children.isEmpty
    }

    // MARK: Delegate

    /**
     * Provides the cell view for one column of a row.
     *
     * Unreadable folders, other volumes and iCloud placeholders (whose data is
     * not on disk) are greyed out, and their name shows the full path as a
     * tooltip. The % of Parent bar is coloured by depth; the scan root shows 100 %.
     *
     * @param {NSOutlineView} outlineView - The tree outline.
     * @param {NSTableColumn?} tableColumn - The column to fill.
     * @param {Any} item - The node for the row.
     * @returns {NSView?} The configured cell, or nil for an unknown item or column.
     *
     * @example
     * // Called by NSOutlineView for each visible cell while scrolling.
     */
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let id = tableColumn?.identifier else { return nil }
        let dim = !node.flags.isDisjoint(with: [.denied, .otherVolume, .dataless])
        switch id {
        case .colName:
            let cell = outlineView.cell(id) { TextCellView(identifier: id, alignment: .left, hasIcon: true) }
            cell.set(node.name, icon: Icons.icon(for: node), dimmed: dim)
            cell.toolTip = dim ? node.path : nil
            return cell
        case .colPercent:
            let cell = outlineView.cell(id) { BarCellView(identifier: id) }
            let parentValue = node.parent.map { Double($0.metric(sizeMode)) } ?? Double(node.metric(sizeMode))
            let f = parentValue > 0 ? Double(node.metric(sizeMode)) / parentValue : 0
            cell.fraction = f
            cell.text = Fmt.percent(f)
            cell.barColor = NodeSorting.barColor(depth: outlineView.level(forItem: node))
            return cell
        default:
            let cell = outlineView.cell(id) {
                TextCellView(identifier: id, alignment: id == .colModified ? .left : .right, hasIcon: false)
            }
            cell.set(NodeSorting.text(for: node, column: id), dimmed: dim)
            return cell
        }
    }

    /**
     * Provides the row view, which carries the deletion mark.
     *
     * @param {NSOutlineView} outlineView - The tree outline.
     * @param {Any} item - The node for the row.
     * @returns {NSTableRowView?} A row view outlined in red when the node is marked for deletion.
     *
     * @example
     * // Called by NSOutlineView before it fills a row's cells.
     */
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = MarkableRowView()
        if let node = item as? Node { rowView.isMarked = isMarked?(node) ?? false }
        return rowView
    }

    /**
     * Forwards a user selection to the owner.
     *
     * Ignored while the controller changes the selection itself.
     *
     * @param {Notification} notification - The outline's selection notification.
     *
     * @example
     * // Called by NSOutlineView when the user clicks a row.
     */
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        owner?.list(self, didSelect: outline.selectedNodes)
    }

    /**
     * Handles a double-click: toggles a folder, previews a file.
     *
     * Double-clicks on the header or empty space are ignored.
     *
     * @example
     * // Sent by the outline as its doubleAction.
     */
    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        if node.isDir {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            owner?.openOrQuickLook(node)
        }
    }
}

/** Column text and comparison shared by the tree and file lists. */
enum NodeSorting {
    /**
     * Returns the text a node shows in a column.
     *
     * Count columns are blank for files. The Folder column shows the parent
     * folder's path; unknown columns fall back to the name.
     *
     * @param {Node} node - The row's node.
     * @param {NSUserInterfaceItemIdentifier} column - The column identifier.
     * @returns {String} The cell text.
     *
     * @example
     * NodeSorting.text(for: node, column: .colSize) // "12.3 GB"
     */
    static func text(for node: Node, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case .colSize: return Fmt.bytes(node.size)
        case .colAlloc: return Fmt.bytes(node.alloc)
        case .colItems: return node.isDir ? Fmt.count(node.itemCount) : ""
        case .colFiles: return node.isDir ? Fmt.count(Int(node.fileCount)) : ""
        case .colFolders: return node.isDir ? Fmt.count(Int(node.dirCount)) : ""
        case .colModified: return Fmt.date(node.modificationDate)
        case .colPath: return node.parent?.path ?? ""
        default: return node.name
        }
    }

    /**
     * Returns nodes sorted by a column.
     *
     * @param {[Node]} nodes - The nodes to sort; the array is not modified.
     * @param {String} key - Column identifier raw value, as used in sort descriptors.
     * @param {Bool} ascending - Smallest first when true, largest first when false.
     * @param {SizeMode} mode - Size used by the % of Parent column.
     * @returns {[Node]} A sorted copy.
     *
     * @example
     * let byName = NodeSorting.sorted(folder.children, key: "name", ascending: true, mode: .allocated)
     */
    static func sorted(_ nodes: [Node], key: String, ascending: Bool, mode: SizeMode) -> [Node] {
        let cmp = comparator(key: key, mode: mode)
        return nodes.sorted { ascending ? cmp($0, $1) : cmp($1, $0) }
    }

    /**
     * Returns the "less than" ordering for a column key.
     *
     * Names and folder paths compare like Finder (numbers in names in numeric
     * order). Size and Allocated break ties with the other size. Unknown keys,
     * including % of Parent, order by the size mode's metric.
     *
     * @param {String} key - Column identifier raw value.
     * @param {SizeMode} mode - Size used for the fallback ordering.
     * @returns {(Node, Node) -> Bool} A strict "less than" predicate; swap the arguments for descending.
     *
     * @example
     * let cmp = NodeSorting.comparator(key: "alloc", mode: .allocated)
     * files.sort { cmp($1, $0) } // largest first
     */
    static func comparator(key: String, mode: SizeMode) -> (Node, Node) -> Bool {
        switch NSUserInterfaceItemIdentifier(key) {
        case .colName:
            return { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .colPath:
            return { ($0.parent?.path ?? "").localizedStandardCompare($1.parent?.path ?? "") == .orderedAscending }
        case .colSize: return { $0.size != $1.size ? $0.size < $1.size : $0.alloc < $1.alloc }
        case .colAlloc: return { $0.alloc != $1.alloc ? $0.alloc < $1.alloc : $0.size < $1.size }
        case .colItems: return { $0.itemCount < $1.itemCount }
        case .colFiles: return { $0.fileCount < $1.fileCount }
        case .colFolders: return { $0.dirCount < $1.dirCount }
        case .colModified: return { $0.mtime < $1.mtime }
        default:
            return mode == .allocated ? { $0.alloc < $1.alloc } : { $0.size < $1.size }
        }
    }

    /** % of Parent bar colours, cycled by outline depth so neighbouring levels differ. */
    private static let depthColors: [NSColor] = [
        NSColor(srgbRed: 0.55, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.32, green: 0.56, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.72, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.75, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.70, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.50, blue: 0.30, alpha: 1),
    ]

    /**
     * Returns the % of Parent bar colour for an outline depth.
     *
     * Negative depths are treated as 0; colours repeat every six levels.
     *
     * @param {Int} depth - Outline level, 0 for the scan root.
     * @returns {NSColor} The bar colour.
     *
     * @example
     * cell.barColor = NodeSorting.barColor(depth: outlineView.level(forItem: node))
     */
    static func barColor(depth: Int) -> NSColor {
        depthColors[max(0, depth) % depthColors.count]
    }
}
