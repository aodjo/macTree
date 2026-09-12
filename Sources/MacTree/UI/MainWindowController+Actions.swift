import AppKit
import Quartz
import UniformTypeIdentifiers

// MARK: - Scanning

/** Scanning, tree updates, zoom, file actions and permissions for the main window. */
extension MainWindowController {
    /**
     * Resets the summary, status bar and treemap header to the pre-scan state.
     *
     * Called once when the window is built, before any location is scanned.
     *
     * @example
     * showIdle()
     */
    func showIdle() {
        summary.showIdle()
        status.label.stringValue = L.ready
        status.rightLabel.stringValue = ""
        treemapHeader.pathLabel.stringValue = ""
        updateZoomButtons()
    }

    /**
     * Toolbar Scan/Stop button: stops a running scan, otherwise scans the selected location.
     *
     * A folder rescan in progress also counts as running, so the button never
     * starts a second scan on top of it.
     *
     * @param {Any?} sender - The toolbar button.
     *
     * @example
     * scanButton.action = #selector(scanOrStop(_:))
     */
    @objc func scanOrStop(_ sender: Any?) {
        if scanner != nil || subScanner != nil {
            stopScan(nil)
        } else {
            startScan(selectedLocation)
        }
    }

    /**
     * Scans the current scan root again from scratch (⌘R).
     *
     * Falls back to the selected location when nothing has been scanned yet.
     * Ignored while a full scan is already running.
     *
     * @param {Any?} sender - The menu item or nil.
     *
     * @example
     * rescanAll(nil)
     */
    @objc func rescanAll(_ sender: Any?) {
        guard scanner == nil else { return }
        startScan(result.map { URL(fileURLWithPath: $0.rootPath) } ?? selectedLocation)
    }

    /**
     * Cancels the running full scan and any folder rescan (⌘.).
     *
     * A cancelled full scan still finishes with the partial tree gathered so
     * far; a cancelled folder rescan is discarded.
     *
     * @param {Any?} sender - The menu item, button or nil.
     *
     * @example
     * stopScan(nil)
     */
    @objc func stopScan(_ sender: Any?) {
        scanner?.cancel()
        subScanner?.cancel()
    }

    /**
     * Starts a full scan of `url`, replacing whatever is shown.
     *
     * Cancels running scans, releases the current tree, adds the location to
     * the picker if it is new, and shows live progress every 0.1 s. The scan
     * runs on a background queue; its result is ignored if another scan was
     * started meanwhile. If the size toggle flipped while scanning, the new
     * tree is re-sorted before display, which is safe because no view holds it yet.
     *
     * @param {URL} url - Volume or folder to scan.
     *
     * @example
     * startScan(URL(fileURLWithPath: "/Applications"))
     */
    func startScan(_ url: URL) {
        scanner?.cancel()
        subScanner?.cancel()
        subScanner = nil
        releaseCurrentTree()

        let scanner = Scanner(path: url.path, sizeMode: sizeMode)
        self.scanner = scanner
        selectedLocation = url
        let known = locationPopup.itemArray.contains {
            ($0.representedObject as? URL)?.standardizedFileURL.path == url.standardizedFileURL.path
        }
        if !known { customLocations.insert(url, at: 0) }
        rebuildLocationMenu()
        let title = VolumeInfo.info(for: url).flatMap { v in v.url.path == scanner.rootPath ? v.name : nil }
            ?? FileManager.default.displayName(atPath: scanner.rootPath)
        summary.showVolume(title: title, path: scanner.rootPath, volume: VolumeInfo.info(for: url), scanned: nil)
        summary.showProgress(scanner.progress)
        treemap.placeholder = "\(L.scanning)…"
        setScanButton(scanning: true)
        window?.title = "\(L.appName) — \(title)"

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak scanner] _ in
            guard let self, let scanner else { return }
            let p = scanner.progress
            self.summary.showProgress(p)
            self.status.label.stringValue = p.currentPath
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = scanner.run()
            DispatchQueue.main.async {
                guard let self, self.scanner === scanner else { return }
                if scanner.sizeMode != self.sizeMode { Scanner.sortAll(root: r.root, by: self.sizeMode) }
                self.finishScan(r, title: title)
            }
        }
    }

    /**
     * Detaches every view from the current tree and frees it off the main thread.
     *
     * A full-disk tree holds millions of nodes, and node deinit recurses once
     * per directory level, so the last reference is dropped on a utility
     * thread with a 16 MB stack instead of stalling (or overflowing) the main thread.
     *
     * @example
     * releaseCurrentTree()
     */
    private func releaseCurrentTree() {
        treemap.invalidate()
        treemap.root = nil
        treemap.selected = nil
        tree.setRoot(nil, sizeMode: sizeMode)
        files.setRoot(nil, sizeMode: sizeMode)
        exts.set(stats: [], colors: nil, sizeMode: sizeMode)
        selection = []
        clearMarks()
        if result != nil {
            var old: ScanResult? = result
            result = nil
            let t = Thread { if old != nil { old = nil } }
            t.stackSize = 16 << 20
            t.qualityOfService = .utility
            t.start()
        }
    }

    /**
     * Shows a finished (or stopped) scan in every pane.
     *
     * Builds the extension colours, loads the tree, file list, file types and
     * treemap, selects the root and reports totals, timing and any unreadable
     * folders in the summary bar.
     *
     * @param {ScanResult} r - The scan result.
     * @param {String} title - Display name of the scanned location.
     *
     * @example
     * finishScan(scanner.run(), title: "Macintosh HD")
     */
    private func finishScan(_ r: ScanResult, title: String) {
        progressTimer?.invalidate()
        progressTimer = nil
        scanner = nil
        setScanButton(scanning: false)
        treemap.placeholder = L.ready
        result = r

        colors = ExtColors(stats: r.extStats, mode: sizeMode)
        tree.setRoot(r.root, sizeMode: sizeMode)
        files.setRoot(r.root, sizeMode: sizeMode)
        exts.set(stats: r.extStats, colors: colors, sizeMode: sizeMode)
        treemap.sizeMode = sizeMode
        treemap.highlightExt = nil
        treemap.colors = colors
        zoom(to: r.root)
        selection = [r.root]
        treemap.selected = r.root
        summary.showVolume(title: title, path: r.rootPath, volume: r.volume, scanned: r.root.metric(sizeMode))
        summary.showResult(r, needsAccess: needsFullDiskAccess(for: r))
        updateStatus(for: r.root)
        window?.makeFirstResponder(files.isActive ? files.table as NSView : tree.outline)
    }

    // MARK: Rescan a subfolder

    /**
     * Rescans one folder and splices the fresh subtree into the current tree.
     *
     * Uses the traversal policy of the original scan so the same volumes and
     * firmlink exclusions apply. Rescanning the root is a full rescan. Ignored
     * while any scan runs. Progress goes to the status bar; a cancelled rescan
     * changes nothing.
     *
     * @param {Any?} sender - A context-menu item carrying the folder, or nil for the selection.
     *
     * @example
     * rescanFolder(nil) // rescans the first selected folder
     */
    @objc func rescanFolder(_ sender: Any?) {
        guard scanner == nil, subScanner == nil, !isDeleting, let result,
              let node = nodes(from: sender).first(where: { $0.isDir }) else { return }
        if node === result.root {
            rescanAll(sender)
            return
        }
        let sc = Scanner(path: node.path, sizeMode: sizeMode, policy: result.policy)
        subScanner = sc
        setScanButton(scanning: true)
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak sc] _ in
            guard let self, let sc else { return }
            let p = sc.progress
            self.status.label.stringValue = "\(L.scanning)… \(Fmt.count(p.files)) \(L.files) · \(p.currentPath)"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = sc.run()
            DispatchQueue.main.async {
                guard let self, self.subScanner === sc else { return }
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                self.subScanner = nil
                self.setScanButton(scanning: false)
                guard !r.cancelled else { return }
                if sc.sizeMode != self.sizeMode { Scanner.sortAll(root: r.root, by: self.sizeMode) }
                self.replace(node, with: r.root)
            }
        }
    }

    /**
     * Swaps a subtree for a freshly scanned one and fixes up every ancestor.
     *
     * Runs under `treeLock` so a background treemap layout never sees a
     * half-updated tree. Ancestors get the size and count differences and are
     * re-sorted along the path; extension totals are recomputed from scratch.
     * Finally the new folder is revealed and selected.
     *
     * @param {Node} old - The node currently in the tree.
     * @param {Node} new - The rescanned subtree root; renamed to `old.name` and attached in its place.
     *
     * @example
     * replace(folder, with: rescan.root)
     */
    private func replace(_ old: Node, with new: Node) {
        guard let result, let parent = old.parent,
              let index = parent.children.firstIndex(where: { $0 === old }) else { return }
        treemap.invalidate()
        treeLock.lock()
        new.name = old.name
        new.parent = parent
        parent.children[index] = new
        let dSize = new.size - old.size, dAlloc = new.alloc - old.alloc
        let dFiles = new.fileCount - old.fileCount, dDirs = new.dirCount - old.dirCount
        var a: Node? = parent
        while let p = a {
            p.size += dSize
            p.alloc += dAlloc
            p.fileCount += dFiles
            p.dirCount += dDirs
            if new.mtime > p.mtime { p.mtime = new.mtime }
            a = p.parent
        }
        parent.sortChildren(by: sizeMode)
        var c: Node = parent
        while let gp = c.parent { gp.sortChildren(by: sizeMode); c = gp }
        treeLock.unlock()

        result.extStats = ExtStats.compute(root: result.root)
        treeDidChange(zoomFallback: parent)
        tree.reveal(new)
        list(tree, didSelect: [new])
    }

    // MARK: Trash

    /**
     * Asks for confirmation, then moves the chosen items to the Trash (⌘⌫).
     *
     * The scan root is never trashed, and items whose ancestor is also chosen
     * are skipped because trashing the ancestor already covers them. The
     * confirmation sheet shows the total size and up to six paths. Ignored
     * while a scan runs.
     *
     * @param {Any?} sender - A context-menu item carrying the nodes, or nil for the selection.
     *
     * @example
     * moveToTrash(nil) // trashes the current selection after confirmation
     */
    @objc func moveToTrash(_ sender: Any?) {
        guard scanner == nil, subScanner == nil, !isDeleting, let window else { return }
        let picked = nodes(from: sender)
        let targets = picked.filter { n in
            n.parent != nil && !picked.contains { $0 !== n && n.isDescendant(of: $0) }
        }
        guard !targets.isEmpty else { return }
        let total = targets.reduce(Int64(0)) { $0 + $1.metric(sizeMode) }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.trashConfirmTitle(targets.count)
        var body = L.trashConfirmBody(Fmt.bytes(total))
        body += "\n\n" + targets.prefix(6).map { $0.path }.joined(separator: "\n")
        if targets.count > 6 { body += "\n…" }
        alert.informativeText = body
        alert.addButton(withTitle: L.moveToTrash)
        alert.addButton(withTitle: L.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performTrash(targets)
        }
    }

    /**
     * Moves items to the Trash and removes the successful ones from the tree.
     *
     * Each item is trashed independently; failures (for example on volumes
     * without a Trash) are collected and shown in one alert, up to eight lines.
     *
     * @param {[Node]} targets - Items to trash; none may contain another.
     *
     * @example
     * performTrash([bigFolder, oldArchive])
     */
    private func performTrash(_ targets: [Node]) {
        var removed: [Node] = []
        var errors: [String] = []
        for n in targets {
            do {
                try FileManager.default.trashItem(at: n.url, resultingItemURL: nil)
                removed.append(n)
            } catch {
                errors.append("\(n.name): \(error.localizedDescription)")
            }
        }
        if !removed.isEmpty { removeFromTree(removed) }
        if !errors.isEmpty, let window {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L.trashFailed
            alert.informativeText = errors.prefix(8).joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
    }

    /**
     * Removes nodes from the tree in place and refreshes every pane.
     *
     * Runs under `treeLock`. Subtracts each removed subtree from its ancestors
     * and re-sorts along the path. Per-extension totals are kept in step by
     * subtracting the removed subtree's tallies instead of walking the whole
     * tree again; extensions left with no files are dropped. Afterwards the
     * parent of the last removed node is revealed and selected.
     *
     * @param {[Node]} removed - Nodes already deleted from disk; none may contain another.
     *
     * @example
     * removeFromTree([trashedFolder])
     */
    func removeFromTree(_ removed: [Node]) {
        guard let result else { return }
        treemap.invalidate()
        var fallback: Node = result.root
        treeLock.lock()
        for n in removed {
            guard let parent = n.parent, let idx = parent.children.firstIndex(where: { $0 === n }) else { continue }
            for s in ExtStats.compute(root: n) {
                if let i = result.extStats.firstIndex(where: { $0.id == s.id }) {
                    result.extStats[i].size -= s.size
                    result.extStats[i].alloc -= s.alloc
                    result.extStats[i].count -= s.count
                }
            }
            parent.children.remove(at: idx)
            let dirs = n.isDir ? n.dirCount + 1 : 0
            var a: Node? = parent
            while let p = a {
                p.size -= n.size
                p.alloc -= n.alloc
                p.fileCount -= n.fileCount
                p.dirCount -= dirs
                a = p.parent
            }
            var c: Node = parent
            while let gp = c.parent { gp.sortChildren(by: sizeMode); c = gp }
            fallback = parent
        }
        treeLock.unlock()
        result.extStats.removeAll { $0.count <= 0 }
        treeDidChange(zoomFallback: fallback)
        tree.reveal(fallback)
        list(tree, didSelect: [fallback])
    }

    /**
     * Refreshes every pane after the tree was changed in place.
     *
     * Reloads the file types and tree (keeping expansion and selection), marks
     * the file list stale, re-renders the treemap, drops deletion marks on
     * removed nodes and updates the scanned total and file/folder counts. If the treemap was zoomed into a folder that no longer exists, it
     * moves to `zoomFallback`.
     *
     * @param {Node} zoomFallback - Folder to show if the treemap's folder was removed.
     *
     * @example
     * treeDidChange(zoomFallback: parent)
     */
    private func treeDidChange(zoomFallback: Node) {
        guard let result else { return }
        exts.set(stats: result.extStats, colors: colors, sizeMode: sizeMode)
        tree.reloadPreservingState()
        files.invalidate()
        if let z = treemap.root, !isAttached(z) {
            zoom(to: zoomFallback)
        }
        treemap.setNeedsRender()
        pruneMarks()
        summary.showVolume(title: summary.titleLabel.stringValue, path: result.rootPath,
                           volume: VolumeInfo.info(for: URL(fileURLWithPath: result.rootPath)),
                           scanned: result.root.metric(sizeMode))
        summary.showResult(result, needsAccess: needsFullDiskAccess(for: result))
    }

    /**
     * Tells whether a node is still reachable from the scan root.
     *
     * A trashed or replaced node keeps its parent pointer, so this checks
     * each parent really still lists the node among its children.
     *
     * @param {Node} node - The node to check.
     * @returns {Bool} False if the node or one of its ancestors was detached.
     *
     * @example
     * if !isAttached(zoomedFolder) { zoom(to: result.root) }
     */
    func isAttached(_ node: Node) -> Bool {
        guard let root = result?.root else { return false }
        var c = node
        while c !== root {
            guard let p = c.parent, p.children.contains(where: { $0 === c }) else { return false }
            c = p
        }
        return true
    }

    // MARK: Size mode / view mode

    /**
     * Switches between logical and allocated size (toolbar toggle or View menu).
     *
     * Persists the choice, re-sorts the whole tree under `treeLock`, rebuilds
     * extension colours and refreshes every pane. During a scan only the
     * setting changes; the finished tree is sorted to match when it arrives.
     *
     * @param {Any?} sender - A View-menu item (its tag is the mode) or the segmented control.
     *
     * @example
     * sizeModeControl.action = #selector(sizeModeChanged(_:))
     */
    @objc func sizeModeChanged(_ sender: Any?) {
        let mode: SizeMode
        if let item = sender as? NSMenuItem {
            mode = SizeMode(rawValue: item.tag) ?? .allocated
        } else {
            mode = SizeMode(rawValue: sizeModeControl.selectedSegment) ?? .allocated
        }
        sizeModeControl.selectedSegment = mode.rawValue
        guard mode != sizeMode else { return }
        sizeMode = mode
        guard let result, scanner == nil else { return }
        treemap.invalidate()
        treeLock.lock()
        Scanner.sortAll(root: result.root, by: mode)
        treeLock.unlock()
        colors = ExtColors(stats: result.extStats, mode: mode)
        tree.setSizeMode(mode)
        files.setRoot(result.root, sizeMode: mode)
        exts.set(stats: result.extStats, colors: colors, sizeMode: mode)
        treemap.sizeMode = mode
        treemap.colors = colors
        summary.showVolume(title: summary.titleLabel.stringValue, path: result.rootPath, volume: result.volume,
                           scanned: result.root.metric(mode))
        if let n = selection.first { updateStatus(for: n) }
    }

    /**
     * Switches between Tree View and File View (toolbar or ⌘1 / ⌘2).
     *
     * @param {Any?} sender - A View-menu item (tag 0 or 1) or the segmented control.
     *
     * @example
     * viewControl.action = #selector(viewModeChanged(_:))
     */
    @objc func viewModeChanged(_ sender: Any?) {
        let index: Int
        if let item = sender as? NSMenuItem { index = item.tag } else { index = viewControl.selectedSegment }
        showTab(index)
    }

    /**
     * Shows the tree (0) or file list (1) and focuses it.
     *
     * Activating the file list builds it on first use. The status bar's right
     * side shows the file count only while the file list is visible.
     *
     * @param {Int} index - 0 for Tree View, 1 for File View.
     *
     * @example
     * showTab(1)
     */
    func showTab(_ index: Int) {
        viewControl.selectedSegment = index
        tabView.selectTabViewItem(at: index)
        files.isActive = index == 1
        window?.makeFirstResponder(index == 0 ? tree.outline as NSView : files.table)
        if index == 0 {
            status.rightLabel.stringValue = ""
        } else if files.totalCount > 0 {
            updateFileCount(shown: files.rows.count, total: files.totalCount)
        }
    }

    /**
     * Applies the search field's text to the File View.
     *
     * A non-empty search switches to File View while keeping keyboard focus
     * in the search field so typing can continue.
     *
     * @param {Any?} sender - The search field or nil.
     *
     * @example
     * searchField.stringValue = "*.mov"
     * searchChanged(nil)
     */
    @objc func searchChanged(_ sender: Any?) {
        let text = searchField.stringValue
        files.setFilter(text)
        if !text.isEmpty && tabView.indexOfTabViewItem(tabView.selectedTabViewItem!) != 1 {
            showTab(1)
            window?.makeFirstResponder(searchField)
        }
    }

    /**
     * Moves keyboard focus to the search field (⌘F).
     *
     * @param {Any?} sender - The menu item.
     *
     * @example
     * focusSearch(nil)
     */
    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    /**
     * Shows how many files the File View lists, when it is visible.
     *
     * @param {Int} shown - Files matching the current filter.
     * @param {Int} total - All files in the scan.
     *
     * @example
     * updateFileCount(shown: 4_771, total: 1_076_094)
     */
    func updateFileCount(shown: Int, total: Int) {
        guard files.isActive else { return }
        status.rightLabel.stringValue = shown == total ? L.filesMatched(total) : L.filesShown(shown, total)
    }

    // MARK: Treemap zoom

    /**
     * Makes `node` the whole treemap, unzoomed.
     *
     * Files are ignored unless they are the scan root. If `node` is already
     * the treemap's folder, only the continuous zoom is reset.
     *
     * @param {Node} node - Folder to show.
     *
     * @example
     * zoom(to: result.root)
     */
    func zoom(to node: Node) {
        guard node.isDir || node.parent == nil else { return }
        if treemap.root === node { treemap.resetZoom() } else { treemap.root = node }
        updateTreemapHeader()
    }

    /**
     * Updates the header above the treemap.
     *
     * Shows the path of whatever fills the view (the treemap's focus, or its
     * folder) and, when zoomed beyond ×1.05, the zoom factor with one decimal
     * below ×10 and none from ×10 up. Also refreshes the zoom buttons.
     *
     * @example
     * updateTreemapHeader() // "/Applications/Unity   ×8.0"
     */
    func updateTreemapHeader() {
        var text = (treemap.focusNode ?? treemap.root)?.path ?? ""
        if treemap.zoomScale > 1.05 {
            text += treemap.zoomScale < 10 ? String(format: "   ×%.1f", treemap.zoomScale)
                                           : String(format: "   ×%.0f", treemap.zoomScale)
        }
        treemapHeader.pathLabel.stringValue = text
        updateZoomButtons()
    }

    /** Whether the treemap shows less than the whole scan (another folder or zoomed in). */
    var treemapIsZoomed: Bool {
        treemap.root != nil && (treemap.root !== result?.root || treemap.zoomScale > 1)
    }

    /**
     * Enables the treemap's Up and Whole-tree buttons only when they would do something.
     *
     * @example
     * updateZoomButtons()
     */
    func updateZoomButtons() {
        treemapHeader.upButton.isEnabled = treemapIsZoomed
        treemapHeader.homeButton.isEnabled = treemapIsZoomed
    }

    /**
     * Zooms the treemap out one step (Up button, ⌘↑, or scrolling out past the whole folder).
     *
     * When zoomed in, first returns to the whole folder. Otherwise moves up to
     * the parent folder, starting framed on the previous folder so zooming
     * out continues smoothly. Does nothing at the scan root.
     *
     * @param {Any?} sender - The button, menu item or nil.
     *
     * @example
     * zoomOut(nil)
     */
    @objc func zoomOut(_ sender: Any?) {
        if treemap.zoomScale > 1 {
            treemap.resetZoom()
        } else if let z = treemap.root, let p = z.parent {
            treemap.show(p, framing: z)
        }
        updateTreemapHeader()
    }

    /**
     * Shows the whole scan in the treemap, unzoomed (⌘0 or the grid button).
     *
     * @param {Any?} sender - The button, menu item or nil.
     *
     * @example
     * zoomReset(nil)
     */
    @objc func zoomReset(_ sender: Any?) {
        guard let result else { return }
        zoom(to: result.root)
    }

    /**
     * Context menu "Zoom Treemap Here": shows a folder on its own in the treemap.
     *
     * For a file, its folder is used. A folder inside the current treemap
     * grows from its current rectangle; anything else is shown directly.
     *
     * @param {Any?} sender - A context-menu item carrying the node, or nil for the selection.
     *
     * @example
     * zoomHere(nil)
     */
    @objc func zoomHere(_ sender: Any?) {
        guard let node = nodes(from: sender).first else { return }
        let folder = node.isDir ? node : (node.parent ?? node)
        if let root = treemap.root, folder.isDescendant(of: root), folder !== root {
            treemap.showFolder(folder)
            updateTreemapHeader()
        } else {
            zoom(to: folder)
        }
    }

    // MARK: File actions

    /**
     * Returns the nodes an action applies to.
     *
     * Context-menu items carry their nodes as `representedObject`; menu-bar
     * items and key equivalents act on the current selection.
     *
     * @param {Any?} sender - The item that triggered the action.
     * @returns {[Node]} The context-menu payload, or the selection.
     *
     * @example
     * let targets = nodes(from: sender)
     */
    func nodes(from sender: Any?) -> [Node] {
        if let item = sender as? NSMenuItem, let nodes = item.representedObject as? [Node] { return nodes }
        return selection
    }

    /**
     * Opens the items with their default applications.
     *
     * @param {Any?} sender - A context-menu item carrying the nodes, or nil for the selection.
     *
     * @example
     * openItems(nil)
     */
    @objc func openItems(_ sender: Any?) {
        for n in nodes(from: sender) { NSWorkspace.shared.open(n.url) }
    }

    /**
     * Selects the items in a Finder window (⇧⌘R).
     *
     * @param {Any?} sender - A context-menu item carrying the nodes, or nil for the selection.
     *
     * @example
     * revealInFinder(nil)
     */
    @objc func revealInFinder(_ sender: Any?) {
        let urls = nodes(from: sender).map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /**
     * Edit › Copy (⌘C) when a list or the treemap has focus: copies the selected paths.
     *
     * Text fields handle ⌘C themselves earlier in the responder chain.
     *
     * @param {Any?} sender - The menu item.
     *
     * @example
     * copy(nil)
     */
    @objc func copy(_ sender: Any?) {
        copyPath(sender)
    }

    /**
     * Puts the items' paths on the pasteboard, one per line (⌥⌘C).
     *
     * @param {Any?} sender - A context-menu item carrying the nodes, or nil for the selection.
     *
     * @example
     * copyPath(nil)
     */
    @objc func copyPath(_ sender: Any?) {
        let paths = nodes(from: sender).map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /**
     * Toggles the Quick Look panel (⌘Y).
     *
     * A context-menu item first makes its nodes the selection so the panel
     * previews them.
     *
     * @param {Any?} sender - A context-menu item carrying the nodes, or nil for the selection.
     *
     * @example
     * quickLook(nil)
     */
    @objc func quickLook(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let nodes = item.representedObject as? [Node] { selection = nodes }
        toggleQuickLook()
    }

    /**
     * Asks for a destination and exports the whole scan as CSV (⌘E).
     *
     * The export runs on a background queue with row counts shown in the
     * status bar; failures are shown as an alert sheet. The default file name
     * uses the volume or folder name.
     *
     * @param {Any?} sender - The menu item.
     *
     * @example
     * exportCSV(nil)
     */
    @objc func exportCSV(_ sender: Any?) {
        guard let result, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let base = result.root.parent == nil && result.rootPath == "/" ? "Macintosh HD" : (result.rootPath as NSString).lastPathComponent
        panel.nameFieldStringValue = "MacTree - \(base).csv"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let root = result.root
            self.status.label.stringValue = "\(L.exporting)…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = Result {
                    try CSVExporter.export(root: root, to: url) { rows in
                        DispatchQueue.main.async {
                            self?.status.label.stringValue = "\(L.exporting)… \(Fmt.count(rows))"
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch outcome {
                    case .success(let rows):
                        self.status.label.stringValue = L.exported(rows, url.path)
                    case .failure(let error):
                        let alert = NSAlert(error: error)
                        alert.messageText = L.exportFailed
                        if let window = self.window { alert.beginSheetModal(for: window) }
                    }
                }
            }
        }
    }

    // MARK: Permissions

    /**
     * Tells whether a Full Disk Access grant would reveal folders this scan could not read.
     *
     * True only if some folder failed with a privacy error (EPERM) and this
     * process does not have access; root-only folders need more than that.
     *
     * @param {ScanResult} r - The scan to check.
     * @returns {Bool} True if asking for Full Disk Access would help.
     *
     * @example
     * summary.showResult(r, needsAccess: needsFullDiskAccess(for: r))
     */
    func needsFullDiskAccess(for r: ScanResult) -> Bool {
        r.denied.contains { $0.isPrivacyProtected } && !FullDiskAccess.isGranted
    }

    /**
     * Shows the Full Disk Access sheet at launch until access is granted or the user opts out.
     *
     * @example
     * DispatchQueue.main.async { wc.requestFullDiskAccessIfNeeded() }
     */
    func requestFullDiskAccessIfNeeded() {
        guard !FullDiskAccess.isGranted, !FullDiskAccess.promptSuppressed else { return }
        presentFullDiskAccessSheet()
    }

    /**
     * App menu "Full Disk Access…": opens the permission sheet on demand.
     *
     * @param {Any?} sender - The menu item.
     *
     * @example
     * showFullDiskAccess(nil)
     */
    @objc func showFullDiskAccess(_ sender: Any?) {
        presentFullDiskAccessSheet()
    }

    /**
     * Presents the Full Disk Access sheet on the main window.
     *
     * Does nothing while another sheet is attached. When the sheet reports a
     * grant and the last scan skipped folders, the scan is repeated so those
     * folders are picked up.
     *
     * @example
     * presentFullDiskAccessSheet()
     */
    func presentFullDiskAccessSheet() {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = FullDiskAccessSheet(relaunchPath: result?.rootPath)
        activeSheet = sheet
        sheet.onFinish = { [weak self] granted in
            guard let self else { return }
            self.activeSheet = nil
            if granted, let r = self.result, r.deniedCount > 0, self.scanner == nil, self.subScanner == nil {
                self.rescanAll(nil)
            }
        }
        sheet.begin(on: window)
    }

    /**
     * Handles a click on the summary bar's unreadable-folders note.
     *
     * Asks for Full Disk Access if that would help; otherwise lists the
     * protected system folders that were skipped.
     *
     * @example
     * summary.onWarningClicked = { [weak self] in self?.showUnreadableFolders() }
     */
    func showUnreadableFolders() {
        guard let result, let window, window.attachedSheet == nil else { return }
        if needsFullDiskAccess(for: result) {
            presentFullDiskAccessSheet()
            return
        }
        let sheet = DeniedFoldersSheet(folders: result.denied, totalCount: result.deniedCount)
        activeSheet = sheet
        sheet.onClose = { [weak self] in self?.activeSheet = nil }
        sheet.begin(on: window)
    }

    /**
     * Shows a node's path, sizes and counts (folders) or date (files) in the status bar.
     *
     * @param {Node?} node - The node to describe; nil clears the status line.
     *
     * @example
     * updateStatus(for: treemap.hovered ?? selection.first)
     */
    func updateStatus(for node: Node?) {
        guard let node else {
            status.label.stringValue = ""
            return
        }
        var parts = [node.path, "\(L.colSize) \(Fmt.bytes(node.size))", "\(L.colAllocated) \(Fmt.bytes(node.alloc))"]
        if node.isDir {
            parts.append("\(Fmt.count(Int(node.fileCount))) \(L.files), \(Fmt.count(Int(node.dirCount))) \(L.folders)")
        } else if let d = node.modificationDate {
            parts.append(Fmt.date(d))
        }
        status.label.stringValue = parts.joined(separator: "   ·   ")
    }
}

// MARK: - Menu validation

/** Enables menu items only when their action can run. */
extension MainWindowController: NSMenuItemValidation {
    /**
     * Enables or disables a menu item and sets its check mark.
     *
     * Item actions need nodes to act on and most are blocked during scans and
     * permanent deletions.
     * Move to Trash is disabled while a text field is being edited, so ⌘⌫ in
     * the search field stays a text edit instead of trashing the selection.
     * The size-mode and view-mode items get a check mark for the current choice.
     *
     * @param {NSMenuItem} menuItem - The item AppKit is about to show.
     * @returns {Bool} Whether the item is enabled.
     *
     * @example
     * // AppKit calls this before showing each menu:
     * let enabled = validateMenuItem(trashItem)
     */
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasNodes = !nodes(from: menuItem).isEmpty
        let busy = scanner != nil || subScanner != nil || isDeleting
        switch menuItem.action {
        case #selector(openItems(_:)), #selector(revealInFinder(_:)), #selector(copyPath(_:)),
             #selector(copy(_:)), #selector(quickLook(_:)):
            return hasNodes
        case #selector(moveToTrash(_:)):
            if menuItem.representedObject == nil, window?.firstResponder is NSText { return false }
            return hasNodes && !busy && nodes(from: menuItem).contains { $0.parent != nil }
        case #selector(rescanFolder(_:)):
            return !busy && nodes(from: menuItem).contains { $0.isDir }
        case #selector(rescanAll(_:)), #selector(exportCSV(_:)):
            return !busy && result != nil
        case #selector(stopScan(_:)):
            return busy
        case #selector(zoomOut(_:)), #selector(zoomReset(_:)):
            return treemapIsZoomed
        case #selector(zoomHere(_:)):
            return hasNodes
        case #selector(toggleDeletionMarkFromMenu(_:)):
            return !isDeleting && nodes(from: menuItem).contains { $0.parent != nil }
        case #selector(deleteMarkedPermanently(_:)):
            return !busy && !deletionTargets.isEmpty
        case #selector(sizeModeChanged(_:)):
            menuItem.state = menuItem.tag == sizeMode.rawValue ? .on : .off
            return scanner == nil
        case #selector(viewModeChanged(_:)):
            menuItem.state = menuItem.tag == viewControl.selectedSegment ? .on : .off
            return true
        default:
            return true
        }
    }
}

// MARK: - Selection sync

/** Keeps the tree, file list, file types and treemap in step with each other. */
extension MainWindowController: NodeListOwner, TreemapViewDelegate, ExtensionListDelegate {
    /**
     * A list's selection changed: highlight it in the treemap and status bar.
     *
     * If the first node lies outside the treemap's folder, the treemap goes
     * back to the whole scan; when zoomed in, it pans to show the node. Also
     * refreshes an open Quick Look panel.
     *
     * @param {AnyObject} source - The tree or file-list controller.
     * @param {[Node]} nodes - The newly selected nodes.
     *
     * @example
     * list(tree, didSelect: [folder])
     */
    func list(_ source: AnyObject, didSelect nodes: [Node]) {
        selection = nodes
        guard let first = nodes.first else { return }
        if let root = treemap.root, !first.isDescendant(of: root), let r = result?.root {
            zoom(to: r)
        }
        treemap.selected = first
        treemap.reveal(first)
        updateStatus(for: first)
        refreshQuickLook()
    }

    /**
     * Builds the right-click menu shared by the tree, file list and treemap.
     *
     * Every item carries `nodes` so the action targets what was clicked.
     * Zoom Here needs a single node, Rescan a single folder, and Show Files of
     * This Type a single file. The deletion-mark item reads "Unmark" when all
     * of the nodes are already marked.
     *
     * @param {[Node]} nodes - The clicked (or selected) nodes.
     * @returns {NSMenu?} The menu, or nil when there is nothing to act on.
     *
     * @example
     * let menu = contextMenu(for: outline.selectedNodes)
     */
    func contextMenu(for nodes: [Node]) -> NSMenu? {
        guard !nodes.isEmpty else { return nil }
        let menu = NSMenu()
        /**
         * Appends an action item that targets `nodes`.
         *
         * @param {String} title - Localised item title.
         * @param {Selector} action - Window-controller action to invoke.
         * @param {String} symbol - SF Symbol name for the item's icon.
         *
         * @example
         * add(L.copyPath, #selector(copyPath(_:)), symbol: "doc.on.clipboard")
         */
        func add(_ title: String, _ action: Selector, symbol: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = nodes
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add(L.open, #selector(openItems(_:)), symbol: "arrow.up.forward.app")
        add(L.revealInFinder, #selector(revealInFinder(_:)), symbol: "folder")
        add(L.quickLook, #selector(quickLook(_:)), symbol: "eye")
        add(L.copyPath, #selector(copyPath(_:)), symbol: "doc.on.clipboard")
        menu.addItem(.separator())
        if nodes.count == 1 {
            add(L.zoomTreemap, #selector(zoomHere(_:)), symbol: "plus.magnifyingglass")
        }
        if nodes.count == 1, nodes[0].isDir {
            add(L.rescanFolder, #selector(rescanFolder(_:)), symbol: "arrow.clockwise")
        }
        if nodes.count == 1, !nodes[0].isDir {
            add(L.showFilesOfType, #selector(showFilesOfType(_:)), symbol: "line.3.horizontal.decrease.circle")
        }
        menu.addItem(.separator())
        let allMarked = nodes.allSatisfy { isMarked($0) }
        add(allMarked ? L.unmarkForDeletion : L.markForDeletion, #selector(toggleDeletionMarkFromMenu(_:)), symbol: "xmark.bin")
        add(L.moveToTrash, #selector(moveToTrash(_:)), symbol: "trash")
        return menu
    }

    /**
     * Context menu "Show Files of This Type": lists every file with the clicked file's extension.
     *
     * Files without an extension are ignored.
     *
     * @param {Any?} sender - A context-menu item carrying the file.
     *
     * @example
     * showFilesOfType(menuItem)
     */
    @objc func showFilesOfType(_ sender: Any?) {
        guard let node = nodes(from: sender).first, !node.isDir, node.ext != 0 else { return }
        extensionList(didActivate: node.ext)
    }

    /**
     * Double-clicked file in a list: previews it with Quick Look.
     *
     * Quick Look is used instead of opening the file so a double-click can
     * never launch an application or installer by accident.
     *
     * @param {Node} node - The double-clicked file.
     *
     * @example
     * openOrQuickLook(file)
     */
    func openOrQuickLook(_ node: Node) {
        selection = [node]
        toggleQuickLook()
    }

    /**
     * An item was clicked in the treemap: select it everywhere.
     *
     * Expands the tree to the item and, if the File View is showing, selects
     * it there too.
     *
     * @param {TreemapView} view - The treemap.
     * @param {Node} node - The clicked item.
     *
     * @example
     * treemap(treemap, didSelect: file)
     */
    func treemap(_ view: TreemapView, didSelect node: Node) {
        selection = [node]
        view.selected = node
        tree.reveal(node)
        if files.isActive { files.select(node) }
        updateStatus(for: node)
        refreshQuickLook()
    }

    /**
     * The pointer moved over a treemap item: describe it in the status bar.
     *
     * Leaving the treemap falls back to describing the selection.
     *
     * @param {TreemapView} view - The treemap.
     * @param {Node?} node - The hovered item, or nil when none.
     *
     * @example
     * treemap(treemap, didHover: nil)
     */
    func treemap(_ view: TreemapView, didHover node: Node?) {
        updateStatus(for: node ?? selection.first)
    }

    /**
     * A folder was double-clicked in the treemap: show it on its own.
     *
     * @param {TreemapView} view - The treemap.
     * @param {Node} node - The folder to show.
     *
     * @example
     * treemap(treemap, didZoomTo: folder)
     */
    func treemap(_ view: TreemapView, didZoomTo node: Node) {
        view.showFolder(node)
        updateTreemapHeader()
    }

    /**
     * The user kept zooming out past the whole folder: go up a level.
     *
     * @param {TreemapView} view - The treemap.
     *
     * @example
     * treemapDidRequestZoomOut(treemap)
     */
    func treemapDidRequestZoomOut(_ view: TreemapView) {
        zoomOut(nil)
    }

    /**
     * The treemap's zoom factor or focus folder changed: refresh the header.
     *
     * @param {TreemapView} view - The treemap.
     *
     * @example
     * treemapViewportDidChange(treemap)
     */
    func treemapViewportDidChange(_ view: TreemapView) {
        updateTreemapHeader()
    }

    /**
     * Supplies the right-click menu for a treemap item.
     *
     * @param {TreemapView} view - The treemap.
     * @param {Node} node - The item under the pointer.
     * @returns {NSMenu?} The shared context menu for that item.
     *
     * @example
     * let menu = treemap(treemap, menuFor: file)
     */
    func treemap(_ view: TreemapView, menuFor node: Node) -> NSMenu? {
        contextMenu(for: [node])
    }

    /**
     * A file type was selected: highlight its files in the treemap.
     *
     * @param {UInt16?} ext - The extension id, or nil to clear the highlight.
     *
     * @example
     * extensionList(didSelect: movID)
     */
    func extensionList(didSelect ext: UInt16?) {
        treemap.highlightExt = ext
    }

    /**
     * A file type was double-clicked: list its files in the File View.
     *
     * Fills the search field with `*.ext`. Files without an extension cannot
     * be expressed as a pattern, so that row is ignored.
     *
     * @param {UInt16} ext - The extension id.
     *
     * @example
     * extensionList(didActivate: movID) // File View filtered by "*.mov"
     */
    func extensionList(didActivate ext: UInt16) {
        let name = ExtensionTable.shared.name(ext)
        guard !name.isEmpty else { return }
        searchField.stringValue = "*." + name
        searchChanged(nil)
        showTab(1)
    }
}

// MARK: - Quick Look

/** Drives the Quick Look panel from the current selection. */
extension MainWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /**
     * Shows or hides the Quick Look panel for the selection (Space).
     *
     * Does nothing when nothing is selected.
     *
     * @example
     * toggleQuickLook()
     */
    func toggleQuickLook() {
        guard !selection.isEmpty else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    /**
     * Makes an open Quick Look panel preview the new selection.
     *
     * Leaves the panel closed if it is not showing.
     *
     * @example
     * refreshQuickLook()
     */
    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        QLPreviewPanel.shared().reloadData()
    }

    /**
     * Tells Quick Look this window controller can feed the panel.
     *
     * @param {QLPreviewPanel} panel - The shared preview panel.
     * @returns {Bool} Always true.
     *
     * @example
     * // Quick Look asks the responder chain when the panel opens:
     * acceptsPreviewPanelControl(QLPreviewPanel.shared()) // true
     */
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    /**
     * Takes over the panel as its data source and delegate.
     *
     * @param {QLPreviewPanel} panel - The shared preview panel.
     *
     * @example
     * // Called by Quick Look after acceptsPreviewPanelControl(_:) returns true.
     * beginPreviewPanelControl(QLPreviewPanel.shared())
     */
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    /**
     * Releases the panel when another controller takes it or it closes.
     *
     * @param {QLPreviewPanel} panel - The shared preview panel.
     *
     * @example
     * // Called by Quick Look when control moves elsewhere.
     * endPreviewPanelControl(QLPreviewPanel.shared())
     */
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    /**
     * Reports how many items the panel can page through.
     *
     * @param {QLPreviewPanel} panel - The shared preview panel.
     * @returns {Int} The number of selected nodes.
     *
     * @example
     * numberOfPreviewItems(in: QLPreviewPanel.shared()) // selection.count
     */
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selection.count }

    /**
     * Supplies the file to preview at a position in the selection.
     *
     * @param {QLPreviewPanel} panel - The shared preview panel.
     * @param {Int} index - Position in the selection.
     * @returns {QLPreviewItem} The node's file URL.
     *
     * @example
     * let item = previewPanel(QLPreviewPanel.shared(), previewItemAt: 0)
     */
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selection[index].url as NSURL
    }

    /**
     * Forwards key presses from the panel to the visible list.
     *
     * Lets the arrow keys move the selection in the tree or file list while
     * the panel is key, so the preview follows along.
     *
     * @param {QLPreviewPanel} panel - The shared preview panel.
     * @param {NSEvent} event - The event the panel received.
     * @returns {Bool} True if a key-down was forwarded; false for other events.
     *
     * @example
     * // Called by Quick Look for events in the panel.
     * previewPanel(QLPreviewPanel.shared(), handle: downArrowEvent)
     */
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let target: NSView = files.isActive ? files.table : tree.outline
        target.keyDown(with: event)
        return true
    }
}
