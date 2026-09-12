import AppKit

/** Table view that routes right-clicks and the space bar to its owner. */
final class NodeTableView: NSTableView {
    /** Receives context-menu and Quick Look requests. */
    weak var owner: NodeListOwner?
    /** Maps a row index to the node shown in it. */
    var nodeProvider: ((Int) -> Node?)?

    /** Nodes in the selected rows. */
    var selectedNodes: [Node] { selectedRowIndexes.compactMap { nodeProvider?($0) } }

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
     * Handles the list's own shortcuts; other keys keep their table behaviour.
     *
     * Space toggles Quick Look. Delete (⌫ or ⌦, without modifiers) marks or
     * unmarks the selection for permanent deletion.
     *
     * @param {NSEvent} event - The key-down event.
     *
     * @example
     * // Pressing Space in the File View opens the Quick Look panel.
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
 * Name filter for the File View.
 *
 * Terms separated by `;` or `|` are OR-ed. A term with `*` / `?` / `[` is a
 * wildcard on the file name, `*.ext` matches an extension exactly, and
 * anything else is a case-insensitive substring.
 */
struct FileFilter {
    /** One parsed search term. */
    private enum Term {
        /** `*.ext`: compare extension ids, the fastest check. */
        case ext(UInt16)
        /** Glob pattern as a NUL-terminated C string for `fnmatch`. */
        case wildcard([CChar])
        /** Lowercased ASCII bytes, matched with a byte scan. */
        case asciiSubstring([UInt8])
        /** Non-ASCII text, matched with Foundation's case- and diacritic-insensitive search. */
        case substring(String)
    }

    /** The parsed terms; empty means "match everything". */
    private let terms: [Term]

    /** Whether the filter has no terms and therefore lets every file through. */
    var isEmpty: Bool { terms.isEmpty }

    /**
     * Parses search text into terms.
     *
     * Each term is classified once so matching millions of files stays cheap:
     * `*.ext` (no other wildcard or dot) becomes an extension-id check, other
     * wildcards go to `fnmatch`, ASCII text gets a byte scan and non-ASCII
     * text (e.g. Korean) uses Foundation search. Blank terms are ignored.
     * Interns unknown extensions into `ExtensionTable` as a side effect.
     *
     * @param {String} text - The search field's contents.
     *
     * @example
     * let filter = FileFilter("*.mov; *.mp4 | cache")
     */
    init(_ text: String) {
        var terms: [Term] = []
        for raw in text.split(whereSeparator: { $0 == ";" || $0 == "|" }) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("*."), t.count > 2, !t.dropFirst(2).contains(where: { "*?[.".contains($0) }) {
                let ext = t.dropFirst(2).lowercased()
                terms.append(.ext(ExtensionTable.shared.intern(ext)))
            } else if t.contains(where: { "*?[".contains($0) }) {
                terms.append(.wildcard(Array(t.utf8CString)))
            } else if t.allSatisfy(\.isASCII) {
                terms.append(.asciiSubstring(Array(t.lowercased().utf8)))
            } else {
                terms.append(.substring(t))
            }
        }
        self.terms = terms
    }

    /**
     * Tells whether a file matches any term.
     *
     * Only the file name is tested, never the path. Safe to call from
     * several threads at once.
     *
     * @param {Node} node - The file to test.
     * @returns {Bool} True if at least one term matches.
     *
     * @example
     * FileFilter("*.mov").matches(movieNode) // true
     */
    func matches(_ node: Node) -> Bool {
        for term in terms {
            switch term {
            case .ext(let e):
                if node.ext == e { return true }
            case .wildcard(let pattern):
                if node.name.withCString({ fnmatch(pattern, $0, FNM_CASEFOLD) == 0 }) { return true }
            case .asciiSubstring(let needle):
                if FileFilter.containsASCII(node.name, needle) { return true }
            case .substring(let s):
                if node.name.range(of: s, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            }
        }
        return false
    }

    /**
     * Case-insensitive ASCII substring search over a string's UTF-8 bytes.
     *
     * Folds A–Z to lowercase on the fly and compares against an already
     * lowercased needle, avoiding allocation per file. Non-ASCII bytes in the
     * haystack are compared as-is.
     *
     * @param {String} haystack - The file name to search.
     * @param {[UInt8]} needle - Lowercased ASCII bytes to look for; must not be empty.
     * @returns {Bool} True if the needle occurs in the haystack.
     *
     * @example
     * FileFilter.containsASCII("DerivedData", Array("data".utf8)) // true
     */
    private static func containsASCII(_ haystack: String, _ needle: [UInt8]) -> Bool {
        var name = haystack
        return name.withUTF8 { h in
            let n = needle.count
            guard n <= h.count else { return false }
            let first = needle[0]
            var i = 0
            let last = h.count - n
            while i <= last {
                var c = h[i]
                if c >= 0x41 && c <= 0x5A { c |= 0x20 }
                if c == first {
                    var j = 1
                    while j < n {
                        var d = h[i + j]
                        if d >= 0x41 && d <= 0x5A { d |= 0x20 }
                        if d != needle[j] { break }
                        j += 1
                    }
                    if j == n { return true }
                }
                i += 1
            }
            return false
        }
    }

    /**
     * Returns the files that match, keeping their order.
     *
     * Splits the input into chunks of 32,768 and filters them in parallel,
     * then joins the chunks in order. An empty filter returns the input as is.
     *
     * @param {[Node]} nodes - Files in display order.
     * @returns {[Node]} The matching files in the same order.
     *
     * @example
     * let shown = FileFilter("*.dylib").apply(allFiles)
     */
    func apply(_ nodes: [Node]) -> [Node] {
        guard !isEmpty else { return nodes }
        let chunk = 32_768
        let chunks = (nodes.count + chunk - 1) / chunk
        guard chunks > 0 else { return [] }
        var parts = [[Node]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { out in
            nodes.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = c * chunk, hi = min(src.count, lo + chunk)
                    var local: [Node] = []
                    for i in lo..<hi where matches(src[i]) { local.append(src[i]) }
                    out[c] = local
                }
            }
        }
        return Array(parts.joined())
    }
}

/**
 * The "File View": every file under the root in one sortable, filterable list.
 *
 * Collecting, sorting and filtering millions of files happens on a background
 * queue; a generation counter discards results that were overtaken by a newer
 * request. The list is built lazily, only while the tab is visible.
 */
final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /** The file table. */
    let table = NodeTableView()
    /** Scroll view hosting the table, placed in the File View tab. */
    let scrollView = NSScrollView()
    /** Receives selection, context-menu and Quick Look requests. */
    weak var owner: NodeListOwner?
    /** Called with (shown, total) after every rebuild or filter. */
    var onCountsChanged: ((Int, Int) -> Void)?
    /** Called when a background rebuild starts or ends. */
    var onBusyChanged: ((Bool) -> Void)?

    /** Files currently shown (sorted and filtered). */
    private(set) var rows: [Node] = []
    /** Every file under the root in the current sort order, before filtering. */
    private var all: [Node] = []
    /** The scan root whose files are listed. */
    private var root: Node?
    /** Size used for the default size sort. */
    private var sizeMode: SizeMode = .allocated
    /** The current search text. */
    private var filterText = ""
    /** Column identifier of the current sort. */
    private var sortKey = NSUserInterfaceItemIdentifier.colAlloc.rawValue
    /** Whether the current sort is ascending. */
    private var ascending = false
    /** Incremented per request so late background results can be dropped. */
    private var generation = 0
    /** The file list is stale and must be rebuilt before it is shown. */
    private var needsRebuild = false
    /** Serial background queue for collecting, sorting and filtering. */
    private let queue = DispatchQueue(label: "filelist", qos: .userInitiated)
    /** Whether the File View tab is visible; becoming visible triggers a pending rebuild. */
    var isActive = false { didSet { if isActive && needsRebuild { rebuild() } } }

    /**
     * Creates the table with its columns and scroll view.
     *
     * Columns: Name, Size, Allocated, Modified and Folder; widths and sort
     * order are autosaved. Double-clicking a row asks the owner to Quick Look it.
     *
     * @example
     * let files = FileListController()
     * files.attach(owner: windowController)
     */
    override init() {
        super.init()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.addColumn(.colName, title: L.colName, width: 280, minWidth: 100, ascendingFirst: true)
        table.addColumn(.colSize, title: L.colSize, width: 80, alignment: .right)
        table.addColumn(.colAlloc, title: L.colAllocated, width: 80, alignment: .right)
        table.addColumn(.colModified, title: L.colModified, width: 150)
        table.addColumn(.colPath, title: L.colPath, width: 480, minWidth: 100, ascendingFirst: true)
        table.autosaveName = "FileTable"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.nodeProvider = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count else { return nil }
            return self.rows[row]
        }

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    /**
     * Connects the list and its table to the object handling selection and menus.
     *
     * @param {NodeListOwner} owner - Usually the main window controller; held weakly.
     *
     * @example
     * files.attach(owner: self)
     */
    func attach(owner: NodeListOwner) {
        self.owner = owner
        table.owner = owner
    }

    /** Files in the selected rows. */
    var selectedNodes: [Node] { table.selectedNodes }
    /** Number of files under the root, before filtering. */
    var totalCount: Int { all.count }
    /** Tells whether a file is marked for deletion; supplied by the window controller. */
    var isMarked: ((Node) -> Bool)?

    /**
     * Updates the red deletion borders of the rows currently on screen.
     *
     * Rows scrolled in later get their state from `rowViewForRow`, so only
     * the existing row views need touching; no reload is required.
     *
     * @example
     * files.refreshMarks() // after the set of marked nodes changed
     */
    func refreshMarks() {
        table.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? MarkableRowView, row < rows.count else { return }
            rowView.isMarked = isMarked?(rows[row]) ?? false
        }
    }

    /**
     * Shows the files of a new tree, or clears the list.
     *
     * Clears the current rows at once and marks the list stale; the rebuild
     * happens now if the tab is visible, otherwise when it is next shown. If
     * the list is sorted by size, the sort follows the new size mode.
     *
     * @param {Node?} node - The new scan root, or nil to clear.
     * @param {SizeMode} sizeMode - The size used for the default sort.
     *
     * @example
     * files.setRoot(result.root, sizeMode: .allocated)
     */
    func setRoot(_ node: Node?, sizeMode: SizeMode) {
        root = node
        self.sizeMode = sizeMode
        if sortKey == NSUserInterfaceItemIdentifier.colAlloc.rawValue || sortKey == NSUserInterfaceItemIdentifier.colSize.rawValue {
            sortKey = sizeMode == .allocated ? NSUserInterfaceItemIdentifier.colAlloc.rawValue
                                             : NSUserInterfaceItemIdentifier.colSize.rawValue
        }
        generation += 1
        all = []
        rows = []
        table.reloadData()
        onCountsChanged?(0, 0)
        invalidate()
    }

    /**
     * Marks the list stale after the tree changed.
     *
     * Rebuilds right away if the tab is visible, otherwise when it is next shown.
     *
     * @example
     * files.invalidate() // after moving files to the Trash
     */
    func invalidate() {
        needsRebuild = true
        if isActive { rebuild() }
    }

    /**
     * Applies new search text.
     *
     * Filters the already sorted file list on the background queue; results
     * from an older request are dropped. If the list is stale it is rebuilt
     * (with the new filter) instead, or later when the tab becomes visible.
     * Unchanged text does nothing.
     *
     * @param {String} text - The search field's contents; empty shows every file.
     *
     * @example
     * files.setFilter("*.mov")
     */
    func setFilter(_ text: String) {
        guard text != filterText else { return }
        filterText = text
        if needsRebuild { if isActive { rebuild() }; return }
        generation += 1
        let gen = generation, all = self.all, filter = FileFilter(text)
        onBusyChanged?(true)
        queue.async { [weak self] in
            let matched = filter.apply(all)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.show(matched, total: all.count)
            }
        }
    }

    /** Set while selecting programmatically so the owner is not notified back. */
    private var suppressSelection = false

    /**
     * Selects a file if it is in the current list, without notifying the owner.
     *
     * Used to mirror a treemap click. Searches the visible rows linearly and
     * scrolls the match into view; clears the selection if the file is not
     * listed (e.g. filtered out).
     *
     * @param {Node} node - The file to select.
     *
     * @example
     * files.select(clickedNode)
     */
    func select(_ node: Node) {
        suppressSelection = true
        defer { suppressSelection = false }
        guard let row = rows.firstIndex(where: { $0 === node }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /**
     * Collects, sorts and filters every file under the root in the background.
     *
     * The tree walk holds `treeLock` so main-thread mutations cannot change
     * children arrays under it; sorting and filtering happen after the lock is
     * released. The result is applied on the main thread only if no newer
     * request was made in the meantime.
     *
     * @example
     * rebuild() // via invalidate() or when the tab becomes visible
     */
    private func rebuild() {
        needsRebuild = false
        generation += 1
        guard let root else {
            all = []
            show([], total: 0)
            return
        }
        let gen = generation
        let key = sortKey, asc = ascending, mode = sizeMode, filter = FileFilter(filterText)
        onBusyChanged?(true)
        queue.async { [weak self] in
            treeLock.lock()
            var files: [Node] = []
            files.reserveCapacity(Int(root.fileCount))
            if root.isDir {
                var stack: [Node] = [root]
                while let n = stack.popLast() {
                    for c in n.children {
                        if c.isDir { stack.append(c) } else { files.append(c) }
                    }
                }
            } else {
                files.append(root)
            }
            treeLock.unlock()
            let cmp = NodeSorting.comparator(key: key, mode: mode)
            files.sort { asc ? cmp($0, $1) : cmp($1, $0) }
            let matched = filter.apply(files)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.all = files
                self.show(matched, total: files.count)
            }
        }
    }

    /**
     * Displays filtered rows and reports the counts.
     *
     * Ends the busy state and tells the owner how many files are shown out of
     * how many exist.
     *
     * @param {[Node]} matched - Rows to display.
     * @param {Int} total - Number of files before filtering.
     *
     * @example
     * show(matched, total: all.count)
     */
    private func show(_ matched: [Node], total: Int) {
        rows = matched
        table.reloadData()
        onBusyChanged?(false)
        onCountsChanged?(matched.count, total)
    }

    // MARK: Table

    /**
     * Reports the number of rows.
     *
     * @param {NSTableView} tableView - The file table.
     * @returns {Int} Number of files currently shown.
     *
     * @example
     * // Called by NSTableView after reloadData().
     */
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /**
     * Provides the cell view for one column of a row.
     *
     * The Name column shows the file-type icon; size columns are right-aligned
     * and the Folder column is dimmed. Cell views are reused by identifier.
     *
     * @param {NSTableView} tableView - The file table.
     * @param {NSTableColumn?} tableColumn - The column to fill.
     * @param {Int} row - The row index into `rows`.
     * @returns {NSView?} The configured cell, or nil for an invalid column or row.
     *
     * @example
     * // Called by NSTableView for each visible cell while scrolling.
     */
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let node = rows[row]
        switch id {
        case .colName:
            let cell = tableView.cell(id) { TextCellView(identifier: id, alignment: .left, hasIcon: true) }
            cell.set(node.name, icon: Icons.icon(for: node))
            return cell
        default:
            let cell = tableView.cell(id) {
                TextCellView(identifier: id, alignment: (id == .colSize || id == .colAlloc) ? .right : .left, hasIcon: false)
            }
            cell.set(NodeSorting.text(for: node, column: id), dimmed: id == .colPath)
            return cell
        }
    }

    /**
     * Re-sorts after a column header click.
     *
     * Sorts the full list and re-applies the filter on the background queue,
     * dropping the result if another request overtook it.
     *
     * @param {NSTableView} tableView - The file table.
     * @param {[NSSortDescriptor]} oldDescriptors - The previous sort (unused).
     *
     * @example
     * // Called by NSTableView when the user clicks the "Size" header.
     */
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        ascending = d.ascending
        generation += 1
        let gen = generation, all = self.all, filter = FileFilter(filterText), mode = sizeMode
        onBusyChanged?(true)
        queue.async { [weak self] in
            let cmp = NodeSorting.comparator(key: key, mode: mode)
            let sorted = all.sorted { d.ascending ? cmp($0, $1) : cmp($1, $0) }
            let matched = filter.apply(sorted)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.all = sorted
                self.show(matched, total: sorted.count)
            }
        }
    }

    /**
     * Provides the row view, which carries the deletion mark.
     *
     * @param {NSTableView} tableView - The file table.
     * @param {Int} row - Row index into the filtered list.
     * @returns {NSTableRowView?} A row view outlined in red when the file is marked for deletion.
     *
     * @example
     * // Called by NSTableView before it fills a row's cells.
     */
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = MarkableRowView()
        if row < rows.count { rowView.isMarked = isMarked?(rows[row]) ?? false }
        return rowView
    }

    /**
     * Forwards a user selection to the owner.
     *
     * Ignored while `select(_:)` changes the selection programmatically.
     *
     * @param {Notification} notification - The table's selection notification.
     *
     * @example
     * // Called by NSTableView when the user clicks a row.
     */
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        owner?.list(self, didSelect: table.selectedNodes)
    }

    /**
     * Opens Quick Look for a double-clicked file.
     *
     * Double-clicks on the header or empty space are ignored.
     *
     * @example
     * // Sent by the table as its doubleAction.
     */
    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        owner?.openOrQuickLook(rows[row])
    }
}
