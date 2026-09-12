import AppKit

/**
 * Application delegate: builds the menu bar, owns the main window and handles
 * launch arguments, Dock drops and quit requests.
 */
final class AppDelegate: NSObject, NSApplicationDelegate {
    /** The single main window. */
    private var windowController: MainWindowController?
    /** Polls for the end of the scan in `--snapshot` mode. */
    private var snapshotTimer: Timer?
    /** A folder dropped on the Dock icon before the window existed. */
    private var pendingOpen: URL?

    /**
     * Installs a custom handler for the "quit" Apple Event before launch finishes.
     *
     * System Settings' "Quit & Reopen" (shown after granting Full Disk Access)
     * sends a quit Apple Event. AppKit's default handler refuses to quit while
     * a sheet is attached, which would leave the app running behind the
     * permission sheet, so the event is routed through `handleQuitEvent`.
     *
     * @param {Notification} notification - The will-finish-launching notification.
     *
     * @example
     * // Called by AppKit during launch, before applicationDidFinishLaunching(_:).
     */
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    /**
     * Quits in response to a quit Apple Event, closing any sheets first.
     *
     * @param {NSAppleEventDescriptor} event - The quit event.
     * @param {NSAppleEventDescriptor} reply - The reply event (unused).
     *
     * @example
     * NSRunningApplication(processIdentifier: pid)?.terminate() // arrives here
     */
    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        NSApp.terminateClosingSheets()
    }

    /**
     * Builds the menu bar and the main window, then acts on launch arguments.
     *
     * Normally shows and activates the window and, on the next run-loop turn,
     * asks for Full Disk Access if it is missing. `--scan <path>` starts a scan
     * right away; otherwise a folder dropped on the Dock icon during launch is
     * scanned.
     *
     * Debug aids: `--snapshot <out.png>` keeps the window behind other windows
     * (no activation, no permission sheet) and saves a picture of it; add
     * `--activate` to bring it to the front instead, so the toolbar and
     * selection are drawn in their active colours (e.g. for README screenshots). With
     * `--snapshot-at <seconds>` the picture is taken at a fixed time, for
     * example to capture a scan in progress; otherwise it is taken 2.5 s after
     * the scan finishes and after the other debug arguments were applied. The
     * app then quits unless `--keep-open` is given.
     *
     * @param {Notification} notification - The did-finish-launching notification.
     *
     * @example
     * // MacTree --scan /Applications --snapshot /tmp/window.png
     */
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        let wc = MainWindowController()
        windowController = wc

        let args = CommandLine.arguments
        let snapshotPath = args.firstIndex(of: "--snapshot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if snapshotPath != nil && !args.contains("--activate") {
            wc.window?.orderBack(nil)
        } else {
            wc.showWindow(nil)
            NSApp.activate()
            if snapshotPath == nil { DispatchQueue.main.async { wc.requestFullDiskAccessIfNeeded() } }
        }

        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            wc.startScan(URL(fileURLWithPath: args[i + 1]))
        } else if let url = pendingOpen {
            pendingOpen = nil
            wc.startScan(url)
        }
        if let snapshotPath, let i = args.firstIndex(of: "--snapshot-at"), i + 1 < args.count,
           let delay = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                wc.saveSnapshot(to: snapshotPath)
                NSApp.terminateClosingSheets()
            }
        } else if let snapshotPath {
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
                guard wc.scanner == nil, wc.result != nil else { return }
                t.invalidate()
                self?.snapshotTimer = nil
                wc.applyDebugArguments(args)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    wc.saveSnapshot(to: snapshotPath)
                    if !args.contains("--keep-open") { NSApp.terminateClosingSheets() }
                }
            }
        }
    }

    /**
     * Quits when the main window closes; the app has no window-less mode.
     *
     * @param {NSApplication} sender - The application.
     * @returns {Bool} Always true.
     *
     * @example
     * // Closing the window with ⌘W ends the app.
     */
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /**
     * Menu action for "Quit MacTree" (⌘Q).
     *
     * Goes through `terminateClosingSheets()` so quitting also works while the
     * permission sheet is open.
     *
     * @param {Any?} sender - The menu item.
     *
     * @example
     * appMenu.addItem(withTitle: L.menuQuit, action: #selector(quit(_:)), keyEquivalent: "q")
     */
    @objc func quit(_ sender: Any?) {
        NSApp.terminateClosingSheets()
    }

    /**
     * Scans a folder or volume dropped on the Dock icon or opened with the app.
     *
     * Only the first URL is used. If the window does not exist yet (the open
     * request arrived during launch), the URL is kept and scanned once
     * `applicationDidFinishLaunching` runs.
     *
     * @param {NSApplication} sender - The application.
     * @param {[URL]} urls - The items to open.
     *
     * @example
     * // Dropping ~/Downloads on the Dock icon scans ~/Downloads.
     */
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let wc = windowController { wc.startScan(url) } else { pendingOpen = url }
    }

    // MARK: Menu

    /**
     * Builds the menu bar: app, File, Edit, View and Window menus.
     *
     * Most items target nil so they travel the responder chain to the main
     * window controller, which validates them. "Move to Trash" uses ⌘⌫, Show
     * in Finder ⇧⌘R, Copy Path ⌥⌘C and treemap zoom out ⌘↑.
     *
     * @returns {NSMenu} The main menu.
     *
     * @example
     * NSApp.mainMenu = buildMainMenu()
     */
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.menuAbout, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.menuFullDiskAccess, action: #selector(MainWindowController.showFullDiskAccess(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.menuHide, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L.menuHideOthers, action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.menuQuit, action: #selector(quit(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: L.appName)

        let file = NSMenu(title: L.menuFile)
        file.addItem(withTitle: L.menuScanFolder, action: #selector(MainWindowController.chooseFolder(_:)), keyEquivalent: "o")
        file.addItem(withTitle: L.rescan, action: #selector(MainWindowController.rescanAll(_:)), keyEquivalent: "r")
        file.addItem(withTitle: L.stop, action: #selector(MainWindowController.stopScan(_:)), keyEquivalent: ".")
        file.addItem(withTitle: L.exportCSV, action: #selector(MainWindowController.exportCSV(_:)), keyEquivalent: "e")
        file.addItem(.separator())
        file.addItem(withTitle: L.open, action: #selector(MainWindowController.openItems(_:)), keyEquivalent: "")
        let reveal = file.addItem(withTitle: L.revealInFinder, action: #selector(MainWindowController.revealInFinder(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L.quickLook, action: #selector(MainWindowController.quickLook(_:)), keyEquivalent: "y")
        file.addItem(withTitle: L.rescanFolder, action: #selector(MainWindowController.rescanFolder(_:)), keyEquivalent: "")
        file.addItem(.separator())
        let trash = file.addItem(withTitle: L.moveToTrash, action: #selector(MainWindowController.moveToTrash(_:)),
                                 keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
        trash.keyEquivalentModifierMask = [.command]
        file.addItem(.separator())
        file.addItem(withTitle: L.menuClose, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file, title: L.menuFile)

        let edit = NSMenu(title: L.menuEdit)
        edit.addItem(withTitle: L.t("Undo", "실행 취소"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L.t("Cut", "오려두기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L.menuCopy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let copyPath = edit.addItem(withTitle: L.copyPath, action: #selector(MainWindowController.copyPath(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        edit.addItem(withTitle: L.t("Paste", "붙이기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L.menuSelectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: L.menuFind, action: #selector(MainWindowController.focusSearch(_:)), keyEquivalent: "f")
        main.addItem(submenu: edit, title: L.menuEdit)

        let view = NSMenu(title: L.menuView)
        let treeItem = view.addItem(withTitle: L.menuShowTree, action: #selector(MainWindowController.viewModeChanged(_:)), keyEquivalent: "1")
        treeItem.tag = 0
        let filesItem = view.addItem(withTitle: L.menuShowFiles, action: #selector(MainWindowController.viewModeChanged(_:)), keyEquivalent: "2")
        filesItem.tag = 1
        view.addItem(.separator())
        let logical = view.addItem(withTitle: L.menuUseLogical, action: #selector(MainWindowController.sizeModeChanged(_:)), keyEquivalent: "")
        logical.tag = SizeMode.logical.rawValue
        let allocated = view.addItem(withTitle: L.menuUseAllocated, action: #selector(MainWindowController.sizeModeChanged(_:)), keyEquivalent: "")
        allocated.tag = SizeMode.allocated.rawValue
        view.addItem(.separator())
        let zoomOut = view.addItem(withTitle: L.zoomOut, action: #selector(MainWindowController.zoomOut(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        zoomOut.keyEquivalentModifierMask = [.command]
        view.addItem(withTitle: L.zoomReset, action: #selector(MainWindowController.zoomReset(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: L.menuFullScreen, action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: view, title: L.menuView)

        let window = NSMenu(title: L.menuWindow)
        window.addItem(withTitle: L.menuMinimize, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L.menuZoom, action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: window, title: L.menuWindow)
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    /**
     * Appends a top-level item that opens `submenu`.
     *
     * Also sets the submenu's title, which AppKit shows for the menu bar entry.
     *
     * @param {NSMenu} submenu - The menu to attach.
     * @param {String} title - Title of the menu bar entry.
     *
     * @example
     * main.addItem(submenu: fileMenu, title: L.menuFile)
     */
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        addItem(item)
    }
}
