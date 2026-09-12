import AppKit

/** Command-line hooks used to exercise the UI headlessly (`--snapshot`). */
extension MainWindowController {
    /**
     * Applies the debug flags that drive the UI after a scan finishes.
     *
     * Used together with `--snapshot` to put the window into a specific state
     * before it is captured. Supported flags: `--size-mode logical|allocated`,
     * `--select <path>`, `--zoom <path>`, `--debug-remove <path>` (runs the
     * in-place tree update used after Move to Trash without touching the disk),
     * `--highlight-ext <ext>`, `--search <text>`, `--tab files`,
     * `--debug-wheel in,in,out` with optional `--debug-wheel-at x,y` (2× zoom
     * steps 0.3 s apart around a point, the treemap's centre by default),
     * `--show-fda-sheet`, `--show-denied-sheet`, `--debug-mark <path>`
     * (repeatable; toggles a deletion mark) and `--debug-delete-marked`
     * (deletes the marked items from disk without asking — test folders only).
     *
     * @param {[String]} args - The process arguments.
     *
     * @example
     * wc.applyDebugArguments(["MacTree", "--scan", "/Applications", "--tab", "files", "--search", "*.dylib"])
     */
    func applyDebugArguments(_ args: [String]) {
        /**
         * Returns the argument that follows a flag.
         *
         * @param {String} flag - The flag to look for, such as "--select".
         * @returns {String?} The next argument, or nil if the flag is absent or last.
         *
         * @example
         * let path = value("--select")
         */
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let mode = value("--size-mode") {
            sizeModeControl.selectedSegment = mode == "logical" ? 0 : 1
            sizeModeChanged(sizeModeControl)
        }
        if let path = value("--select"), let node = findNode(path) {
            treemap(treemap, didSelect: node)
        }
        if let path = value("--zoom"), let node = findNode(path) {
            zoom(to: node)
        }
        if let path = value("--debug-remove"), let node = findNode(path) {
            removeFromTree([node])
        }
        if let ext = value("--highlight-ext") {
            let id = ExtensionTable.shared.intern(ext)
            treemap.highlightExt = id
        }
        if let text = value("--search") {
            searchField.stringValue = text
            searchChanged(nil)
        }
        if value("--tab") == "files" { showTab(1) }
        if let steps = value("--debug-wheel") {
            let at = value("--debug-wheel-at")?.split(separator: ",").compactMap { Double($0) }
            let center = at?.count == 2 ? NSPoint(x: at![0], y: at![1])
                                        : NSPoint(x: treemap.bounds.midX, y: treemap.bounds.midY)
            for (i, step) in steps.split(separator: ",").enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i + 1)) { [weak self] in
                    self?.treemap.zoom(by: step == "in" ? 2 : 0.5, at: center)
                }
            }
        }
        for (i, arg) in args.enumerated() where arg == "--debug-mark" && i + 1 < args.count {
            if let node = findNode(args[i + 1]) { toggleDeletionMark(for: [node]) }
        }
        if args.contains("--debug-delete-marked") {
            performPermanentDelete(deletionTargets)
        }
        if args.contains("--show-fda-sheet") { presentFullDiskAccessSheet() }
        if args.contains("--show-denied-sheet"), let result, let window {
            let sheet = DeniedFoldersSheet(folders: result.denied, totalCount: result.deniedCount)
            activeSheet = sheet
            sheet.begin(on: window)
        }
    }

    /**
     * Resolves a path to a node in the current scan.
     *
     * Accepts an absolute path under the scan root or a path relative to it,
     * matching one name per component.
     *
     * @param {String} path - Absolute or root-relative path.
     * @returns {Node?} The matching node, or nil if there is no scan or a component is missing.
     *
     * @example
     * let xcode = findNode("/Applications/Xcode.app")
     */
    func findNode(_ path: String) -> Node? {
        guard let root = result?.root else { return nil }
        var node: Node? = root
        let rel = path.hasPrefix(root.path) ? String(path.dropFirst(root.path.count)) : path
        for part in rel.split(separator: "/") {
            node = node?.children.first { $0.name == part }
        }
        return node
    }

    /**
     * Writes the current window (or its sheet) to a PNG file.
     *
     * Three capture modes: `--capture-sheet` renders only the attached sheet
     * via `cacheDisplay`; `--capture-window` asks the window server for this
     * window alone through `screencapture -l`, which includes the toolbar
     * (`cacheDisplay` cannot draw the toolbar's glass items) but needs the
     * Screen Recording permission; otherwise the window's frame view is
     * rendered with `cacheDisplay`. Failures are silent.
     *
     * @param {String} path - Destination PNG path.
     *
     * @example
     * wc.saveSnapshot(to: "/tmp/mactree.png")
     */
    func saveSnapshot(to path: String) {
        if CommandLine.arguments.contains("--capture-sheet"), let sheet = window?.attachedSheet,
           let view = sheet.contentView?.superview {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            return
        }
        if CommandLine.arguments.contains("--capture-window"), let window {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? p.run()
            p.waitUntilExit()
            return
        }
        guard let frameView = window?.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        let rect = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: rect) else { return }
        frameView.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
