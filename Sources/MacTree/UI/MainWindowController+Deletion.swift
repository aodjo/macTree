import AppKit

/**
 * Permanent deletion: Delete marks items (red borders in every pane), and the
 * toolbar's Delete Permanently button removes them from disk after one
 * confirmation.
 */
extension MainWindowController {
    /**
     * Marked items that would actually be deleted.
     *
     * Leaves out the scan root and any item inside another marked folder,
     * since deleting the folder already covers it.
     */
    var deletionTargets: [Node] {
        let marked = markedForDeletion
        return marked.filter { n in
            n.parent != nil && !marked.contains { $0 !== n && n.isDescendant(of: $0) }
        }
    }

    /**
     * Tells whether a node is marked for deletion.
     *
     * @param {Node} node - The node to check.
     * @returns {Bool} True if the node itself is marked (its ancestors are not considered).
     *
     * @example
     * rowView.isMarked = isMarked(node)
     */
    func isMarked(_ node: Node) -> Bool {
        markedIDs.contains(ObjectIdentifier(node))
    }

    /**
     * Delete key in the tree or file list: toggles the mark on the selection.
     *
     * @example
     * toggleDeletionMark() // after the user pressed Delete
     */
    func toggleDeletionMark() {
        toggleDeletionMark(for: selection)
    }

    /**
     * Delete key in the treemap: toggles the mark on the clicked item.
     *
     * @param {TreemapView} view - The treemap that received the key.
     *
     * @example
     * treemapDidRequestToggleMark(treemap)
     */
    func treemapDidRequestToggleMark(_ view: TreemapView) {
        toggleDeletionMark(for: selection)
    }

    /**
     * Context menu "Mark for Deletion" / "Unmark for Deletion".
     *
     * @param {Any?} sender - A context-menu item carrying the nodes.
     *
     * @example
     * toggleDeletionMarkFromMenu(menuItem)
     */
    @objc func toggleDeletionMarkFromMenu(_ sender: Any?) {
        toggleDeletionMark(for: nodes(from: sender))
    }

    /**
     * Marks nodes for deletion, or unmarks them if they are all marked already.
     *
     * The scan root can never be marked. While a deletion is running nothing
     * changes and the system beeps. Afterwards every pane redraws its red
     * borders and the status bar shows the marked count and total size.
     *
     * @param {[Node]} nodes - The nodes to toggle.
     *
     * @example
     * toggleDeletionMark(for: [bigFolder])
     */
    func toggleDeletionMark(for nodes: [Node]) {
        let candidates = nodes.filter { $0.parent != nil }
        guard !candidates.isEmpty, !isDeleting else {
            NSSound.beep()
            return
        }
        if candidates.allSatisfy(isMarked) {
            let ids = Set(candidates.map(ObjectIdentifier.init))
            markedForDeletion.removeAll { ids.contains(ObjectIdentifier($0)) }
        } else {
            markedForDeletion += candidates.filter { !isMarked($0) }
        }
        marksDidChange()
        let targets = deletionTargets
        if targets.isEmpty {
            updateStatus(for: selection.first)
        } else {
            let total = targets.reduce(Int64(0)) { $0 + $1.metric(sizeMode) }
            status.label.stringValue = L.markedSummary(targets.count, Fmt.bytes(total))
        }
    }

    /**
     * Pushes the current marks to every pane and the toolbar button.
     *
     * Rebuilds the lookup set, then redraws the treemap borders and the
     * visible list rows and refreshes the Delete Permanently button.
     *
     * @example
     * markedForDeletion.removeAll(); marksDidChange()
     */
    func marksDidChange() {
        markedIDs = Set(markedForDeletion.map(ObjectIdentifier.init))
        treemap.marked = markedForDeletion
        tree.refreshMarks()
        files.refreshMarks()
        updateDeleteButton()
    }

    /**
     * Drops marks on nodes that are no longer in the tree.
     *
     * Needed after Move to Trash, a folder rescan or a deletion, which detach
     * nodes (and everything under them) from the tree.
     *
     * @example
     * pruneMarks() // from treeDidChange
     */
    func pruneMarks() {
        guard !markedForDeletion.isEmpty else { return }
        markedForDeletion.removeAll { !isAttached($0) }
        marksDidChange()
    }

    /**
     * Removes every mark, e.g. when a new scan replaces the tree.
     *
     * @example
     * clearMarks()
     */
    func clearMarks() {
        markedForDeletion = []
        marksDidChange()
    }

    /**
     * Toolbar "Delete Permanently": confirms, then deletes the marked items.
     *
     * The confirmation lists the count, the total size and up to six paths,
     * and says the deletion skips the Trash and cannot be undone. Cancel is
     * the default button, so pressing Return never deletes anything. Ignored
     * while a scan or another deletion runs.
     *
     * @param {Any?} sender - The toolbar button.
     *
     * @example
     * deleteMarkedPermanently(nil)
     */
    @objc func deleteMarkedPermanently(_ sender: Any?) {
        let targets = deletionTargets
        guard !targets.isEmpty, scanner == nil, subScanner == nil, !isDeleting, let window else { return }
        let total = targets.reduce(Int64(0)) { $0 + $1.metric(sizeMode) }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L.deleteConfirmTitle(targets.count)
        var body = L.deleteConfirmBody(Fmt.bytes(total))
        body += "\n\n" + targets.prefix(6).map { $0.path }.joined(separator: "\n")
        if targets.count > 6 { body += "\n…" }
        alert.informativeText = body
        alert.addButton(withTitle: L.cancel)
        let delete = alert.addButton(withTitle: L.deletePermanently)
        delete.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.performPermanentDelete(targets)
        }
    }

    /**
     * Deletes items from disk in the background, then updates the tree.
     *
     * Paths are captured on the main thread; `FileManager.removeItem` runs on
     * a background queue because large folders take a while. Successfully
     * deleted items are removed from the tree, which also drops their marks.
     * Failures are listed in an alert, noting that a folder may have been
     * partly deleted before the error. If a new scan replaced the tree in the
     * meantime, only the alert is shown.
     *
     * @param {[Node]} targets - Items to delete; none may contain another.
     *
     * @example
     * performPermanentDelete(deletionTargets)
     */
    func performPermanentDelete(_ targets: [Node]) {
        isDeleting = true
        updateDeleteButton()
        status.label.stringValue = L.deleting
        let items = targets.map { ($0, $0.url) }
        let resultAtStart = result
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var deleted: [Node] = []
            var errors: [String] = []
            let fm = FileManager()
            for (node, url) in items {
                do {
                    try fm.removeItem(at: url)
                    deleted.append(node)
                } catch {
                    errors.append("\(url.path): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDeleting = false
                if self.result === resultAtStart, !deleted.isEmpty {
                    self.removeFromTree(deleted)
                } else {
                    self.pruneMarks()
                    self.updateDeleteButton()
                }
                if !errors.isEmpty, let window = self.window {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = L.deleteFailed
                    alert.informativeText = errors.prefix(8).joined(separator: "\n") + "\n\n" + L.deletePartialHint
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }
}
