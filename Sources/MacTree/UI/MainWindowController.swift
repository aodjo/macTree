import AppKit

/** Identifiers of the main window's toolbar items. */
private extension NSToolbarItem.Identifier {
    /** Volume / folder picker. */
    static let location = NSToolbarItem.Identifier("location")
    /** Scan / Stop button. */
    static let scan = NSToolbarItem.Identifier("scan")
    /** Tree View / File View switch. */
    static let viewMode = NSToolbarItem.Identifier("viewMode")
    /** Size / Allocated switch. */
    static let sizeMode = NSToolbarItem.Identifier("sizeMode")
    /** Delete Permanently button, left of the search field. */
    static let deletePermanently = NSToolbarItem.Identifier("deletePermanently")
    /** File search field. */
    static let search = NSToolbarItem.Identifier("search")
}

/**
 * Owns the single main window and coordinates every pane.
 *
 * Holds the current scan result and selection, runs scans, and keeps the
 * tree, file list, extension list, treemap, summary and status bar in sync.
 * Actions, selection sync and Quick Look live in extensions in other files.
 */
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSplitViewDelegate {
    /** Top strip with the location, space usage and scan statistics. */
    let summary = SummaryBar()
    /** Bottom status line with the hovered or selected item. */
    let status = StatusBar()
    /** The Tree View pane. */
    let tree = TreeController()
    /** The File View pane. */
    let files = FileListController()
    /** The per-extension totals pane. */
    let exts = ExtensionListController()
    /** The cushion treemap. */
    let treemap = TreemapView()
    /** Breadcrumb and zoom buttons above the treemap. */
    let treemapHeader = TreemapHeader()
    /** Tabless container switching between the Tree View and the File View. */
    let tabView = NSTabView()
    /** Splits the lists (top) from the treemap (bottom). */
    let mainSplit = NSSplitView()
    /** Splits the tree / file list (left) from the extension list (right). */
    let topSplit = NSSplitView()

    /** Toolbar popup listing volumes, recent folders and "Choose Folder…". */
    let locationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /** Toolbar button that starts a scan or stops the running one. */
    let scanButton = NSButton()
    /** Toolbar switch between the Tree View and the File View. */
    let viewControl = NSSegmentedControl()
    /** Toolbar switch between logical and allocated size. */
    let sizeModeControl = NSSegmentedControl()
    /** Toolbar button that permanently deletes the items marked with Delete; disabled while nothing is marked. */
    let deleteButton = NSButton()
    /** Toolbar search field that filters the File View. */
    let searchField = NSSearchField()

    /** The finished scan being shown, if any. */
    var result: ScanResult?
    /** The full scan in progress, if any. */
    var scanner: Scanner?
    /** A "Rescan This Folder" scan in progress, if any. */
    var subScanner: Scanner?
    /** Refreshes progress text while a scan runs. */
    var progressTimer: Timer?
    /** Colour assignment per extension for the current result. */
    var colors: ExtColors?
    /** Nodes that menu actions and Quick Look apply to. */
    var selection: [Node] = []
    /** The location the Scan button scans. */
    var selectedLocation: URL = URL(fileURLWithPath: "/")
    /** Folders picked by the user this session, listed in the location popup. */
    var customLocations: [URL] = []
    /** Keeps the controller of an open sheet alive. */
    var activeSheet: NSWindowController?
    /** Nodes marked for permanent deletion, in the order they were marked. */
    var markedForDeletion: [Node] = []
    /** Identities of `markedForDeletion`, for fast lookups while drawing rows. */
    var markedIDs: Set<ObjectIdentifier> = []
    /** True while marked items are being deleted in the background. */
    var isDeleting = false

    /**
     * Size used for percentages, ordering and the treemap; persisted in user defaults.
     *
     * Allocated size is the default because sparse images and iCloud placeholders
     * would otherwise dominate the view.
     */
    var sizeMode: SizeMode = (UserDefaults.standard.object(forKey: "sizeMode") as? Int).flatMap(SizeMode.init) ?? .allocated {
        didSet { UserDefaults.standard.set(sizeMode.rawValue, forKey: "sizeMode") }
    }

    /**
     * Creates the main window with its toolbar and panes.
     *
     * Restores the autosaved window frame (centring the window on first launch),
     * shows the idle state, and starts listening for volume mounts and unmounts
     * so the location popup stays current.
     *
     * @example
     * let wc = MainWindowController()
     * wc.showWindow(nil)
     */
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L.appName
        window.minSize = NSSize(width: 900, height: 600)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        super.init(window: window)
        window.delegate = self
        buildToolbar()
        buildContent()
        rebuildLocationMenu()
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        showIdle()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    /**
     * Unsupported; the window is built in code.
     *
     * @param {NSCoder} coder - Unused.
     * @returns {MainWindowController?} Never returns.
     *
     * @example
     * // Not used: MainWindowController is never loaded from a nib.
     */
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    /**
     * Builds the window content: summary bar, split panes, treemap and status bar.
     *
     * Wires the panes to this controller, stacks the tree / file tabs next to the
     * extension list, and puts the treemap with its header below. Split positions
     * are autosaved; on first launch the lists get about half the height and the
     * extension list about 380 points, after which the saved positions take over.
     *
     * @example
     * buildContent() // called once from init()
     */
    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        tree.attach(owner: self)
        files.attach(owner: self)
        tree.isMarked = { [weak self] in self?.isMarked($0) ?? false }
        files.isMarked = { [weak self] in self?.isMarked($0) ?? false }
        exts.delegate = self
        treemap.delegate = self
        summary.onWarningClicked = { [weak self] in self?.showUnreadableFolders() }
        files.onCountsChanged = { [weak self] shown, total in self?.updateFileCount(shown: shown, total: total) }
        files.onBusyChanged = { [weak self] busy in
            if busy { self?.status.rightLabel.stringValue = "…" }
        }

        tabView.tabViewType = .noTabsNoBorder
        let treeTab = NSTabViewItem(identifier: "tree")
        treeTab.view = tree.scrollView
        let fileTab = NSTabViewItem(identifier: "files")
        fileTab.view = files.scrollView
        tabView.addTabViewItem(treeTab)
        tabView.addTabViewItem(fileTab)

        topSplit.isVertical = true
        topSplit.dividerStyle = .thin
        topSplit.delegate = self
        topSplit.addArrangedSubview(tabView)
        topSplit.addArrangedSubview(exts.scrollView)
        topSplit.setHoldingPriority(.init(240), forSubviewAt: 0)
        topSplit.setHoldingPriority(.init(260), forSubviewAt: 1)
        topSplit.autosaveName = "TopSplit"

        let treemapPane = NSView()
        for v in [treemapHeader, treemap] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            treemapPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            treemapHeader.topAnchor.constraint(equalTo: treemapPane.topAnchor),
            treemapHeader.leadingAnchor.constraint(equalTo: treemapPane.leadingAnchor),
            treemapHeader.trailingAnchor.constraint(equalTo: treemapPane.trailingAnchor),
            treemap.topAnchor.constraint(equalTo: treemapHeader.bottomAnchor),
            treemap.leadingAnchor.constraint(equalTo: treemapPane.leadingAnchor),
            treemap.trailingAnchor.constraint(equalTo: treemapPane.trailingAnchor),
            treemap.bottomAnchor.constraint(equalTo: treemapPane.bottomAnchor),
        ])
        treemapHeader.upButton.target = self
        treemapHeader.upButton.action = #selector(zoomOut(_:))
        treemapHeader.homeButton.target = self
        treemapHeader.homeButton.action = #selector(zoomReset(_:))

        mainSplit.isVertical = false
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        mainSplit.addArrangedSubview(topSplit)
        mainSplit.addArrangedSubview(treemapPane)
        mainSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        mainSplit.setHoldingPriority(.init(240), forSubviewAt: 1)
        mainSplit.autosaveName = "MainSplit"

        for v in [summary, mainSplit, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: summary.bottomAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: mainSplit.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            exts.scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            tabView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            topSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            treemapPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        let freshMain = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil
        let freshTop = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames TopSplit") == nil
        content.layoutSubtreeIfNeeded()
        if freshMain { mainSplit.setPosition(mainSplit.bounds.height * 0.52, ofDividerAt: 0) }
        if freshTop { topSplit.setPosition(max(400, topSplit.bounds.width - 380), ofDividerAt: 0) }
    }

    // MARK: - Toolbar

    /**
     * Configures the toolbar controls and installs the toolbar.
     *
     * The toolbar is attached last because it measures its item views as soon as
     * it is installed; attaching it earlier gives zero-sized items and AppKit
     * layout warnings.
     *
     * @example
     * buildToolbar() // called once from init()
     */
    private func buildToolbar() {
        locationPopup.target = self
        locationPopup.action = #selector(locationChosen(_:))
        locationPopup.controlSize = .regular

        scanButton.bezelStyle = .toolbar
        scanButton.setButtonType(.momentaryPushIn)
        scanButton.imagePosition = .imageLeading
        scanButton.target = self
        scanButton.action = #selector(scanOrStop(_:))
        setScanButton(scanning: false)

        viewControl.segmentCount = 2
        viewControl.setLabel(L.treeView, forSegment: 0)
        viewControl.setLabel(L.fileView, forSegment: 1)
        viewControl.setImage(NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: nil), forSegment: 0)
        viewControl.setImage(NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil), forSegment: 1)
        viewControl.trackingMode = .selectOne
        viewControl.selectedSegment = 0
        viewControl.target = self
        viewControl.action = #selector(viewModeChanged(_:))

        sizeModeControl.segmentCount = 2
        sizeModeControl.setLabel(L.sizeModeLogical, forSegment: 0)
        sizeModeControl.setLabel(L.sizeModeAllocated, forSegment: 1)
        sizeModeControl.trackingMode = .selectOne
        sizeModeControl.selectedSegment = sizeMode.rawValue
        sizeModeControl.target = self
        sizeModeControl.action = #selector(sizeModeChanged(_:))
        sizeModeControl.toolTip = L.t("Measure percentages and the treemap by logical size or by allocated (on-disk) size",
                                      "비율과 트리맵을 논리 크기 또는 실제 디스크 할당 크기로 계산")

        deleteButton.bezelStyle = .toolbar
        deleteButton.setButtonType(.momentaryPushIn)
        deleteButton.imagePosition = .imageLeading
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteButton.target = self
        deleteButton.action = #selector(deleteMarkedPermanently(_:))
        updateDeleteButton()

        for control in [scanButton, viewControl, sizeModeControl] as [NSControl] { control.sizeToFit() }

        searchField.placeholderString = L.searchPlaceholder
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    /**
     * Lists the toolbar items in display order.
     *
     * @param {NSToolbar} toolbar - The main window's toolbar.
     * @returns {[NSToolbarItem.Identifier]} Location, Scan, view switch, size switch, Delete Permanently and search.
     *
     * @example
     * let ids = toolbarDefaultItemIdentifiers(window.toolbar!)
     */
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.location, .scan, .space, .viewMode, .sizeMode, .flexibleSpace, .deletePermanently, .search]
    }

    /**
     * Lists the items the toolbar may contain; the same as the defaults since customisation is off.
     *
     * @param {NSToolbar} toolbar - The main window's toolbar.
     * @returns {[NSToolbarItem.Identifier]} The default identifiers.
     *
     * @example
     * let allowed = toolbarAllowedItemIdentifiers(window.toolbar!)
     */
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /**
     * Creates the toolbar item for an identifier, wrapping the matching control.
     *
     * The location popup gets a fixed 260-point width so its title never
     * resizes the toolbar; the search item uses `NSSearchToolbarItem`.
     *
     * @param {NSToolbar} toolbar - The main window's toolbar.
     * @param {NSToolbarItem.Identifier} id - The item to create.
     * @param {Bool} flag - Whether the item is going into the toolbar (always true here).
     * @returns {NSToolbarItem?} The item, or nil for identifiers this window does not use.
     *
     * @example
     * let item = toolbar(window.toolbar!, itemForItemIdentifier: .scan, willBeInsertedIntoToolbar: true)
     */
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .location:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L.location
            item.view = locationPopup
            locationPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
            return item
        case .scan:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L.scan
            item.view = scanButton
            return item
        case .viewMode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L.treeView
            item.view = viewControl
            return item
        case .sizeMode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L.sizeModeLabel
            item.view = sizeModeControl
            return item
        case .deletePermanently:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L.deletePermanently
            item.view = deleteButton
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField = searchField
            item.preferredWidthForSearchField = 300
            return item
        default:
            return nil
        }
    }

    /**
     * Switches the Scan button between its Scan and Stop appearance.
     *
     * Updates the title, symbol and tooltip, then resizes the button to fit.
     * Also refreshes the Delete Permanently button, which is disabled during scans.
     *
     * @param {Bool} scanning - True while a full or folder scan is running.
     *
     * @example
     * setScanButton(scanning: true) // shows "Stop"
     */
    func setScanButton(scanning: Bool) {
        scanButton.title = scanning ? L.stop : L.scan
        scanButton.image = NSImage(systemSymbolName: scanning ? "stop.fill" : "play.fill", accessibilityDescription: nil)
        scanButton.toolTip = scanning ? L.stop : L.scan
        scanButton.sizeToFit()
        updateDeleteButton()
    }

    /**
     * Refreshes the Delete Permanently button from the marked items.
     *
     * Enabled (and tinted red) only while something is marked and no scan or
     * deletion is running. The title shows the number of marked items and
     * the tooltip their total size, or how to mark items when there are none.
     *
     * @example
     * updateDeleteButton() // after marking, deleting or starting a scan
     */
    func updateDeleteButton() {
        let targets = deletionTargets
        let busy = scanner != nil || subScanner != nil || isDeleting
        deleteButton.isEnabled = !targets.isEmpty && !busy
        deleteButton.contentTintColor = deleteButton.isEnabled ? .systemRed : nil
        deleteButton.title = targets.isEmpty ? L.deletePermanently : L.deletePermanentlyCount(targets.count)
        let total = targets.reduce(Int64(0)) { $0 + $1.metric(sizeMode) }
        deleteButton.toolTip = targets.isEmpty ? L.deleteHint : L.markedSummary(targets.count, Fmt.bytes(total))
        deleteButton.sizeToFit()
    }

    // MARK: - Locations

    /**
     * Refreshes the location popup when a volume is mounted or unmounted.
     *
     * @param {Notification} note - The workspace mount or unmount notification.
     *
     * @example
     * // Posted by NSWorkspace when a USB drive is plugged in.
     */
    @objc private func volumesChanged(_ note: Notification) {
        rebuildLocationMenu()
    }

    /**
     * Rebuilds the location popup's menu.
     *
     * Lists mounted volumes with their free and total space, then the home folder
     * and folders picked this session, then "Choose Folder…". Duplicate paths are
     * listed once. Re-selects `selectedLocation` if it is in the menu.
     *
     * @example
     * customLocations.insert(url, at: 0)
     * rebuildLocationMenu()
     */
    func rebuildLocationMenu() {
        let menu = NSMenu()
        var seen = Set<String>()
        /**
         * Appends a menu item for a location unless its path is already listed.
         *
         * The item carries the URL as its represented object and shows the
         * Finder icon of the location at 16 points.
         *
         * @param {URL} url - The volume or folder.
         * @param {String} title - The menu item title.
         *
         * @example
         * add(FileManager.default.homeDirectoryForCurrentUser, title: "~")
         */
        func add(_ url: URL, title: String) {
            guard seen.insert(url.standardizedFileURL.path).inserted else { return }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        for v in VolumeInfo.mounted() {
            add(v.url, title: "\(v.name)   \(Fmt.bytes(v.available)) \(L.free) / \(Fmt.bytes(v.total))")
        }
        menu.addItem(.separator())
        add(FileManager.default.homeDirectoryForCurrentUser, title: FileManager.default.homeDirectoryForCurrentUser.path)
        for url in customLocations { add(url, title: url.path) }
        menu.addItem(.separator())
        let choose = NSMenuItem(title: L.chooseFolder, action: nil, keyEquivalent: "")
        choose.representedObject = "choose"
        menu.addItem(choose)
        locationPopup.menu = menu
        selectLocationItem(selectedLocation)
    }

    /**
     * Selects the popup item for a location, matching standardised paths.
     *
     * Leaves the current selection alone when the location is not listed.
     *
     * @param {URL} url - The location to show as selected.
     *
     * @example
     * selectLocationItem(URL(fileURLWithPath: "/"))
     */
    private func selectLocationItem(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let item = locationPopup.itemArray.first(where: { ($0.representedObject as? URL)?.standardizedFileURL.path == path }) {
            locationPopup.select(item)
        }
    }

    /**
     * Handles a pick from the location popup.
     *
     * Choosing a location starts scanning it right away. "Choose Folder…" puts
     * the popup back on the current location and opens the folder picker instead.
     *
     * @param {NSPopUpButton} sender - The location popup.
     *
     * @example
     * // Sent by locationPopup when the user picks "Macintosh HD".
     */
    @objc private func locationChosen(_ sender: NSPopUpButton) {
        let item = sender.selectedItem
        if item?.representedObject as? String == "choose" {
            selectLocationItem(selectedLocation)
            chooseFolder(nil)
            return
        }
        guard let url = item?.representedObject as? URL else { return }
        selectedLocation = url
        startScan(url)
    }

    /**
     * Asks for a folder in a sheet, then scans it.
     *
     * The chosen folder is remembered in `customLocations` for the rest of the
     * session so it stays in the location popup. Cancelling does nothing.
     *
     * @param {Any?} sender - The menu item or control that sent the action.
     *
     * @example
     * chooseFolder(nil) // same as File › Scan Folder… (⌘O)
     */
    @objc func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L.scan
        panel.directoryURL = selectedLocation
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if !self.customLocations.contains(url) { self.customLocations.insert(url, at: 0) }
            self.selectedLocation = url
            self.rebuildLocationMenu()
            self.startScan(url)
        }
    }

    // MARK: - Split view

    /**
     * Sets the smallest allowed divider position.
     *
     * Keeps at least 160 points for the lists above the treemap, and at least
     * 400 points for the tree / file list left of the extension list.
     *
     * @param {NSSplitView} splitView - The split view being dragged.
     * @param {CGFloat} proposedMinimumPosition - AppKit's proposed minimum.
     * @param {Int} dividerIndex - The divider being moved (always 0 here).
     * @returns {CGFloat} The minimum divider position.
     *
     * @example
     * // Called by NSSplitView while the user drags a divider.
     */
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === mainSplit ? max(proposedMinimumPosition, 160) : max(proposedMinimumPosition, 400)
    }

    /**
     * Sets the largest allowed divider position.
     *
     * Keeps at least 120 points for the treemap and at least 220 points for the
     * extension list.
     *
     * @param {NSSplitView} splitView - The split view being dragged.
     * @param {CGFloat} proposedMaximumPosition - AppKit's proposed maximum.
     * @param {Int} dividerIndex - The divider being moved (always 0 here).
     * @returns {CGFloat} The maximum divider position.
     *
     * @example
     * // Called by NSSplitView while the user drags a divider.
     */
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMaximumPosition, extent - (splitView === mainSplit ? 120 : 220))
    }
}
