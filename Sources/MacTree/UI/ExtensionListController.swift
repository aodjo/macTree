import AppKit

/** Receives selections from the file-type list. */
protocol ExtensionListDelegate: AnyObject {
    /**
     * Called when the selected file type changes.
     *
     * Not called for selection changes the list makes itself while reloading.
     *
     * @param {UInt16?} ext - Selected extension id, or nil when nothing is selected.
     *
     * @example
     * func extensionList(didSelect ext: UInt16?) { treemap.highlightExt = ext }
     */
    func extensionList(didSelect ext: UInt16?)

    /**
     * Called when a file type is double-clicked.
     *
     * @param {UInt16} ext - The double-clicked extension id.
     *
     * @example
     * func extensionList(didActivate ext: UInt16) { searchField.stringValue = "*." + ExtensionTable.shared.name(ext) }
     */
    func extensionList(didActivate ext: UInt16)
}

/** Per-extension totals with the colour used in the treemap. */
final class ExtensionListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /** The file-type table. */
    let table = NSTableView()
    /** Scroll view hosting `table`; this is what goes into the window. */
    let scrollView = NSScrollView()
    /** Receives selection and double-click events. */
    weak var delegate: ExtensionListDelegate?

    /** Rows, in the current sort order. */
    private var stats: [ExtStat] = []
    /** Sum of all rows in the current size mode; the base for the percentage column. */
    private var total: Int64 = 0
    /** Swatch and bar colours per extension. */
    private var colors: ExtColors?
    /** Which size the Size and % columns show. */
    private var sizeMode: SizeMode = .allocated
    /** Column id the rows are sorted by. */
    private var sortKey = NSUserInterfaceItemIdentifier.colSize.rawValue
    /** Whether the current sort is ascending. */
    private var ascending = false
    /** Set while the list changes its own selection, so the delegate is not notified. */
    private var suppressSelection = false

    /**
     * Builds the table with Extension, %, Size and Files columns.
     *
     * Column widths and sort order are autosaved under "ExtTable". Double-click
     * is routed to `doubleClicked()`.
     *
     * @example
     * let exts = ExtensionListController()
     * exts.delegate = self
     */
    override init() {
        super.init()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addColumn(.colExt, title: L.colExtension, width: 92, minWidth: 60, ascendingFirst: true)
        table.addColumn(.colPercent, title: L.colPercentTotal, width: 72, minWidth: 50)
        table.addColumn(.colSize, title: L.colSize, width: 68, alignment: .right)
        table.addColumn(.colCount, title: L.colFiles, width: 60, alignment: .right)
        table.autosaveName = "ExtTable"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    /**
     * Replaces the rows, colours and size mode, then reloads.
     *
     * The Size column title switches between "Size" and "Allocated" to match
     * the mode. The selected extension, if still present, stays selected
     * without notifying the delegate.
     *
     * @param {[ExtStat]} stats - Per-extension totals of the scan.
     * @param {ExtColors?} colors - Colours for the swatches and bars; nil draws grey.
     * @param {SizeMode} sizeMode - Which size to show and sort by.
     *
     * @example
     * exts.set(stats: result.extStats, colors: colors, sizeMode: .allocated)
     */
    func set(stats: [ExtStat], colors: ExtColors?, sizeMode: SizeMode) {
        self.stats = stats
        self.colors = colors
        self.sizeMode = sizeMode
        total = stats.reduce(0) { $0 + $1.metric(sizeMode) }
        table.tableColumn(withIdentifier: .colSize)?.title = sizeMode == .allocated ? L.colAllocated : L.colSize
        let selected = selectedExt
        sort()
        suppressSelection = true
        table.reloadData()
        if let selected, let row = self.stats.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelection = false
    }

    /** Extension id of the selected row, or nil. */
    var selectedExt: UInt16? {
        let row = table.selectedRow
        return row >= 0 && row < stats.count ? stats[row].id : nil
    }

    /**
     * Sorts `stats` by the current sort key and direction.
     *
     * The Extension column sorts by display name, Files by count, and every
     * other column (%, Size) by the current size mode.
     *
     * @example
     * sortKey = NSUserInterfaceItemIdentifier.colCount.rawValue
     * sort()
     */
    private func sort() {
        let mode = sizeMode
        let asc = ascending
        switch NSUserInterfaceItemIdentifier(sortKey) {
        case .colExt:
            stats.sort { asc ? $0.displayName < $1.displayName : $0.displayName > $1.displayName }
        case .colCount:
            stats.sort { asc ? $0.count < $1.count : $0.count > $1.count }
        default:
            stats.sort { asc ? $0.metric(mode) < $1.metric(mode) : $0.metric(mode) > $1.metric(mode) }
        }
    }

    /**
     * Returns the number of file types.
     *
     * @param {NSTableView} tableView - The file-type table.
     * @returns {Int} Row count.
     *
     * @example
     * table.reloadData() // AppKit then asks numberOfRows(in:)
     */
    func numberOfRows(in tableView: NSTableView) -> Int { stats.count }

    /**
     * Builds the cell for one row and column.
     *
     * Extension shows a colour swatch and name, % a bar in the extension's
     * colour relative to all files, Size the total in the current mode, and
     * Files the file count.
     *
     * @param {NSTableView} tableView - The file-type table.
     * @param {NSTableColumn?} tableColumn - The column being drawn.
     * @param {Int} row - Row index into `stats`.
     * @returns {NSView?} The configured cell, or nil for an unknown column or row.
     *
     * @example
     * // Called by NSTableView for each visible cell after reloadData().
     */
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < stats.count else { return nil }
        let s = stats[row]
        switch id {
        case .colExt:
            let cell = tableView.cell(id) { SwatchCellView(identifier: id) }
            cell.label.stringValue = s.displayName
            cell.color = colors?.nsColor(s.id) ?? .gray
            return cell
        case .colPercent:
            let cell = tableView.cell(id) { BarCellView(identifier: id) }
            let f = total > 0 ? Double(s.metric(sizeMode)) / Double(total) : 0
            cell.fraction = f
            cell.text = Fmt.percent(f)
            cell.barColor = colors?.nsColor(s.id) ?? .gray
            return cell
        case .colSize:
            let cell = tableView.cell(id) { TextCellView(identifier: id, alignment: .right, hasIcon: false) }
            cell.set(Fmt.bytes(s.metric(sizeMode)))
            return cell
        default:
            let cell = tableView.cell(id) { TextCellView(identifier: id, alignment: .right, hasIcon: false) }
            cell.set(Fmt.count(s.count))
            return cell
        }
    }

    /**
     * Re-sorts after a header click, keeping the selected extension selected.
     *
     * @param {NSTableView} tableView - The file-type table.
     * @param {[NSSortDescriptor]} oldDescriptors - The previous sort descriptors (unused).
     *
     * @example
     * // Called by NSTableView when the user clicks a column header.
     */
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        ascending = d.ascending
        let selected = selectedExt
        sort()
        suppressSelection = true
        tableView.reloadData()
        if let selected, let row = stats.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelection = false
    }

    /**
     * Tells the delegate about user-made selection changes.
     *
     * @param {Notification} notification - The selection-change notification.
     *
     * @example
     * // Called by NSTableView after the user selects a row.
     */
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        delegate?.extensionList(didSelect: selectedExt)
    }

    /**
     * Forwards a double-click on a row to the delegate; clicks outside rows are ignored.
     *
     * @example
     * table.doubleAction = #selector(doubleClicked)
     */
    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < stats.count else { return }
        delegate?.extensionList(didActivate: stats[row].id)
    }
}
