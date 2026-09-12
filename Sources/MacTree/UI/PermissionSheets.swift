import AppKit

/**
 * The app's own icon, draggable into System Settings' Full Disk Access list.
 *
 * Dragging it hands the app bundle's file URL to System Settings, which is
 * the easiest way to add an app that is not listed yet.
 */
final class DraggableAppIconView: NSView, NSDraggingSource {
    /** Shows the application icon. */
    private let iconView = NSImageView()
    /** "Drag into the list" hint under the icon. */
    private let caption = NSTextField(labelWithString: L.fdaDragHint)

    /**
     * Builds the tile: a rounded, bordered box with the app icon and a caption.
     *
     * The tile sizes itself to 110 × 96 points with Auto Layout. The image
     * view stops accepting drops so it cannot be mistaken for a drop target.
     *
     * @param {NSRect} frameRect - Initial frame; usually `.zero`, since constraints size the tile.
     *
     * @example
     * let tile = DraggableAppIconView()
     * stack.addArrangedSubview(tile)
     */
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        toolTip = L.fdaDragHint

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.unregisterDraggedTypes()
        caption.font = .systemFont(ofSize: 10.5)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        for v in [iconView, caption] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 110),
            heightAnchor.constraint(equalToConstant: 96),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            caption.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    /**
     * Not supported; the tile is only created in code.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called: the view is not used in nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Refreshes the layer colours from the current appearance.
     *
     * AppKit calls this when the view needs redisplay, including after a
     * light/dark switch, so the background and border track the system colours.
     *
     * @example
     * tile.needsDisplay = true // AppKit then calls updateLayer()
     */
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /** Draws through `updateLayer()` instead of `draw(_:)`. */
    override var wantsUpdateLayer: Bool { true }

    /**
     * Makes the whole tile the drag handle.
     *
     * Any point inside the bounds returns the tile itself, so the image view
     * and caption never take the click that should start a drag.
     *
     * @param {NSPoint} point - Point in the superview's coordinate system.
     * @returns {NSView?} This view when the point is inside it, otherwise nil.
     *
     * @example
     * let hit = window.contentView?.hitTest(clickPoint) // the tile, not its image view
     */
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    /**
     * Shows an open-hand cursor over the tile to hint that it can be dragged.
     *
     * @example
     * window.invalidateCursorRects(for: tile) // AppKit calls resetCursorRects()
     */
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /**
     * Starts dragging the app bundle.
     *
     * The pasteboard carries `Bundle.main.bundleURL`, which System Settings'
     * Full Disk Access list accepts as a new entry. The drag image is the icon.
     *
     * @param {NSEvent} event - The mouse-down event that starts the drag.
     *
     * @example
     * // Pressing on the tile and moving the mouse starts the drag.
     */
    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(iconView.frame, contents: iconView.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /**
     * Allows the drag only into other applications.
     *
     * Dropping inside MacTree itself would mean nothing, so no operations are
     * offered there.
     *
     * @param {NSDraggingSession} session - The active drag.
     * @param {NSDraggingContext} context - Whether the target is inside or outside this app.
     * @returns {NSDragOperation} Copy/link/generic outside the app, none inside.
     *
     * @example
     * // Called by AppKit while the user drags the tile over System Settings.
     */
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}

/**
 * Numbered circle for the steps list.
 *
 * The digit is centred on its cap height, and the view reports that baseline
 * so a stack view with first-baseline alignment can line it up with text.
 */
final class StepBadge: NSView {
    /** The digit shown in the circle. */
    private let number: String
    /** Font of the digit. */
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    /** Circle diameter in points. */
    private let diameter: CGFloat = 18

    /**
     * Creates an 18-point badge for one step number.
     *
     * The badge refuses to stretch in either direction, so stack views keep
     * it circular.
     *
     * @param {Int} number - The step number to show.
     *
     * @example
     * let row = NSStackView(views: [StepBadge(number: 1), label])
     */
    init(number: Int) {
        self.number = "\(number)"
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    /**
     * Not supported; badges are only created in code.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called: the view is not used in nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /** A fixed square the size of the circle. */
    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    /** Baseline of the digit, measured from the top edge. */
    override var firstBaselineOffsetFromTop: CGFloat { diameter / 2 + font.capHeight / 2 }
    /** Baseline of the digit, measured from the bottom edge. */
    override var lastBaselineOffsetFromBottom: CGFloat { diameter / 2 - font.capHeight / 2 }

    /**
     * Draws the accent-coloured circle and the white digit.
     *
     * `draw(at:)` positions the bottom of the text line, not its baseline, so
     * the origin is lowered by the font's descender to put the baseline where
     * the cap height is centred in the circle.
     *
     * @param {NSRect} dirtyRect - The area to redraw; the whole badge is always drawn.
     *
     * @example
     * badge.needsDisplay = true // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let s = number as NSString
        let width = s.size(withAttributes: attrs).width
        let baseline = bounds.midY - font.capHeight / 2
        s.draw(at: NSPoint(x: bounds.midX - width / 2, y: baseline + font.descender), withAttributes: attrs)
    }
}

/**
 * Explains Full Disk Access, opens System Settings and waits for the grant.
 *
 * The sheet has three states: waiting, "granted but needs a relaunch", and
 * granted. While waiting it polls once a second and whenever the app becomes
 * active again.
 */
final class FullDiskAccessSheet: NSWindowController {
    /** Called once when the sheet closes; `true` if access is now granted. */
    var onFinish: ((Bool) -> Void)?

    /** Spins while waiting for the grant. */
    private let statusSpinner = NSProgressIndicator()
    /** Green check shown once the grant is detected. */
    private let statusIcon = NSImageView()
    /** Current state in words. */
    private let statusLabel = NSTextField(labelWithString: L.fdaWaiting)
    /** "Still waiting? Relaunch" hint with its button. */
    private let relaunchRow = NSStackView()
    /** "Don't ask at launch" checkbox. */
    private let dontAsk = NSButton(checkboxWithTitle: L.fdaDontAsk, target: nil, action: nil)
    /** Closes the sheet without the grant. */
    private let laterButton = NSButton(title: L.fdaLater, target: nil, action: nil)
    /** Primary button: open settings, then relaunch or done depending on the state. */
    private let openButton = NSButton(title: L.fdaOpenSettings, target: nil, action: nil)
    /** Polls for the grant while waiting. */
    private var timer: Timer?
    /** Set once the sheet has closed, so late callbacks do nothing. */
    private var finished = false
    /** Whether a fresh-process probe is still running. */
    private var probing = false
    /** Folder to rescan after a relaunch, if any. */
    private let relaunchPath: String?

    /**
     * Creates the sheet and lays out its content.
     *
     * Nothing is shown until `begin(on:)` attaches it to a window.
     *
     * @param {String?} relaunchPath - Folder to rescan if the user relaunches from here.
     *
     * @example
     * let sheet = FullDiskAccessSheet(relaunchPath: result?.rootPath)
     */
    init(relaunchPath: String?) {
        self.relaunchPath = relaunchPath
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        buildContent()
    }

    /**
     * Not supported; the sheet is only created in code.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called: the controller is not loaded from a nib.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Presents the sheet on `parent` and starts watching for the grant.
     *
     * If access is already granted, it shows the granted state straight away
     * and waits for Done. Otherwise it polls every second and re-checks
     * whenever the app becomes active. The caller must keep the controller
     * alive until `onFinish` runs.
     *
     * @param {NSWindow} parent - Window to attach the sheet to.
     *
     * @example
     * activeSheet = sheet
     * sheet.begin(on: window)
     */
    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        if FullDiskAccess.isGranted {
            showGranted(autoClose: false)
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
            NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                                   name: NSApplication.didBecomeActiveNotification, object: nil)
        }
    }

    /**
     * Builds the sheet's views.
     *
     * Layout: a header with a shield icon, title and explanation; the numbered
     * steps next to the draggable app tile; the status row with its (initially
     * hidden) relaunch hint; and a footer with the checkbox and buttons.
     * Escape maps to Not Now and Return to the primary button. The window is
     * sized to fit the content.
     *
     * @example
     * buildContent() // called once from init
     */
    private func buildContent() {
        guard let window else { return }

        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: L.fdaTitle)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: L.fdaBody)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 420

        let header = NSStackView(views: [icon, NSStackView(views: [title, body], orientation: .vertical, alignment: .leading)])
        header.alignment = .top
        header.spacing = 14

        let steps = NSStackView(views: [
            step(1, L.fdaStep1),
            step(2, L.fdaStep2),
            step(3, L.fdaStep3),
        ], orientation: .vertical, alignment: .leading)
        steps.spacing = 8
        let dragTile = DraggableAppIconView()
        let stepsRow = NSStackView(views: [steps, dragTile])
        stepsRow.alignment = .centerY
        stepsRow.spacing = 16

        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.startAnimation(nil)
        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        statusIcon.contentTintColor = .systemGreen
        statusIcon.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let status = NSStackView(views: [statusSpinner, statusIcon, statusLabel])
        status.spacing = 6

        let hint = NSTextField(labelWithString: L.fdaRelaunchHint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let relaunch = NSButton(title: L.fdaRelaunch, target: self, action: #selector(relaunchApp))
        relaunch.bezelStyle = .inline
        relaunch.controlSize = .small
        relaunchRow.setViews([hint, relaunch], in: .leading)
        relaunchRow.spacing = 6
        relaunchRow.isHidden = true

        dontAsk.target = self
        dontAsk.state = FullDiskAccess.promptSuppressed ? .on : .off
        dontAsk.action = #selector(dontAskChanged)
        laterButton.target = self
        laterButton.action = #selector(later)
        laterButton.keyEquivalent = "\u{1b}"
        openButton.target = self
        openButton.action = #selector(openSettings)
        openButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [dontAsk, spacer, laterButton, openButton])
        footer.spacing = 8

        let statusGroup = NSStackView(views: [status, relaunchRow], orientation: .vertical, alignment: .leading)
        statusGroup.spacing = 6
        let root = NSStackView(views: [header, stepsRow, statusGroup, footer], orientation: .vertical, alignment: .leading)
        root.spacing = 18
        root.setCustomSpacing(22, after: statusGroup)
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 540),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = openButton
    }

    /**
     * Builds one numbered step: a badge followed by wrapping text.
     *
     * The row uses first-baseline alignment, so the digit sits on the same
     * line as the first line of the text even when the text wraps.
     *
     * @param {Int} n - Step number.
     * @param {String} text - Instruction text.
     * @returns {NSView} The row view.
     *
     * @example
     * steps.addArrangedSubview(step(1, L.fdaStep1))
     */
    private func step(_ n: Int, _ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 350
        let badge = StepBadge(number: n)
        let row = NSStackView(views: [badge, label])
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    // MARK: State

    /**
     * Re-checks when the user comes back, typically from System Settings.
     *
     * Also reveals the relaunch hint, because a grant made while the app was
     * running may only apply after a relaunch.
     *
     * @example
     * // Posted by AppKit as NSApplication.didBecomeActiveNotification.
     */
    @objc private func appBecameActive() {
        if !finished && FullDiskAccess.canRelaunch { relaunchRow.isHidden = false }
        check()
    }

    /**
     * Checks whether access has been granted and updates the sheet.
     *
     * First checks this process; if that succeeds, shows the granted state
     * and closes shortly after. Otherwise it asks a freshly started child
     * process, because this process may be refused only because it started
     * before the grant; if the child has access, the sheet switches to the
     * "relaunch to apply" state. Only one probe runs at a time.
     *
     * @example
     * timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.check() }
     */
    private func check() {
        guard !finished, !probing else { return }
        if FullDiskAccess.isGranted {
            showGranted(autoClose: true)
            return
        }
        probing = true
        FullDiskAccess.probeInFreshProcess { [weak self] granted in
            guard let self else { return }
            self.probing = false
            if granted && !self.finished { self.showNeedsRelaunch() }
        }
    }

    /**
     * Switches to the "granted, relaunch to apply" state.
     *
     * macOS applies a new Full Disk Access grant only to processes started
     * after it. Stops polling, turns the primary button into Relaunch and
     * brings the app forward. Does nothing if polling already stopped.
     *
     * @example
     * FullDiskAccess.probeInFreshProcess { if $0 { self.showNeedsRelaunch() } }
     */
    private func showNeedsRelaunch() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        statusSpinner.stopAnimation(nil)
        statusSpinner.isHidden = true
        statusIcon.isHidden = false
        statusLabel.stringValue = L.fdaGrantedNeedsRelaunch
        relaunchRow.isHidden = true
        dontAsk.isHidden = true
        openButton.title = L.fdaRelaunch
        openButton.action = #selector(relaunchApp)
        NSApp.activate()
    }

    /**
     * Switches to the granted state.
     *
     * Stops polling and leaves only a Done button. With `autoClose`, the app
     * comes forward and the sheet closes itself after 1.2 seconds, reporting
     * success.
     *
     * @param {Bool} autoClose - Whether to close automatically (the grant was just detected).
     *
     * @example
     * if FullDiskAccess.isGranted { showGranted(autoClose: true) }
     */
    private func showGranted(autoClose: Bool) {
        timer?.invalidate()
        timer = nil
        statusSpinner.stopAnimation(nil)
        statusSpinner.isHidden = true
        statusIcon.isHidden = false
        statusLabel.stringValue = L.fdaGranted
        relaunchRow.isHidden = true
        laterButton.isHidden = true
        dontAsk.isHidden = true
        openButton.title = L.fdaDone
        openButton.action = #selector(done)
        if autoClose {
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish(granted: true) }
        }
    }

    // MARK: Actions

    /**
     * Opens the Full Disk Access pane in System Settings.
     *
     * The sheet stays open and keeps polling for the grant.
     *
     * @example
     * openButton.action = #selector(openSettings)
     */
    @objc private func openSettings() {
        FullDiskAccess.openSettings()
    }

    /**
     * Closes the sheet without the grant ("Not Now").
     *
     * @example
     * laterButton.action = #selector(later)
     */
    @objc private func later() { finish(granted: false) }

    /**
     * Closes the sheet from the granted state, re-checking access first.
     *
     * @example
     * openButton.action = #selector(done)
     */
    @objc private func done() { finish(granted: FullDiskAccess.isGranted) }

    /**
     * Saves the "Don't ask at launch" checkbox immediately.
     *
     * @example
     * dontAsk.action = #selector(dontAskChanged)
     */
    @objc private func dontAskChanged() {
        FullDiskAccess.promptSuppressed = dontAsk.state == .on
    }

    /**
     * Quits and reopens the app so a new grant takes effect.
     *
     * Rescans `relaunchPath` after the relaunch when one was given.
     *
     * @example
     * openButton.action = #selector(relaunchApp)
     */
    @objc private func relaunchApp() {
        FullDiskAccess.relaunch(scanning: relaunchPath)
    }

    /**
     * Closes the sheet once and reports the outcome.
     *
     * Stops polling, removes the notification observer, ends the sheet and
     * calls `onFinish`. Later calls do nothing.
     *
     * @param {Bool} granted - Whether access is now granted.
     *
     * @example
     * finish(granted: FullDiskAccess.isGranted)
     */
    private func finish(granted: Bool) {
        guard !finished, let window else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        window.sheetParent?.endSheet(window)
        onFinish?(granted)
    }
}

/** Lists folders that stayed unreadable (system-protected or root-only). */
final class DeniedFoldersSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /** Called after the sheet closes, so the owner can release it. */
    var onClose: (() -> Void)?
    /** The recorded unreadable folders. */
    private let folders: [DeniedFolder]
    /** How many folders were unreadable in total (the list may be capped). */
    private let totalCount: Int
    /** Two-column table: path and reason. */
    private let table = NSTableView()

    /**
     * Creates the sheet for a scan's unreadable folders.
     *
     * Nothing is shown until `begin(on:)` attaches it to a window.
     *
     * @param {[DeniedFolder]} folders - The recorded folders to list.
     * @param {Int} totalCount - Total number of unreadable folders, shown in the title.
     *
     * @example
     * let sheet = DeniedFoldersSheet(folders: result.denied, totalCount: result.deniedCount)
     */
    init(folders: [DeniedFolder], totalCount: Int) {
        self.folders = folders
        self.totalCount = totalCount
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        buildContent()
    }

    /**
     * Not supported; the sheet is only created in code.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called: the controller is not loaded from a nib.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Presents the sheet on `parent`.
     *
     * The caller must keep the controller alive until `onClose` runs.
     *
     * @param {NSWindow} parent - Window to attach the sheet to.
     *
     * @example
     * activeSheet = sheet
     * sheet.begin(on: window)
     */
    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
    }

    /**
     * Builds the title, explanation, folder table and buttons.
     *
     * Double-clicking a row, or the Show in Finder button, reveals the
     * folders; Return closes the sheet.
     *
     * @example
     * buildContent() // called once from init
     */
    private func buildContent() {
        guard let window else { return }
        let title = NSTextField(labelWithString: L.deniedTitle(totalCount))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: L.deniedBody)
        body.textColor = .secondaryLabelColor

        let pathCol = NSTableColumn(identifier: .colPath)
        pathCol.title = L.colPath
        pathCol.width = 440
        let reasonCol = NSTableColumn(identifier: .colName)
        reasonCol.title = L.deniedReason
        reasonCol.width = 150
        table.addTableColumn(pathCol)
        table.addTableColumn(reasonCol)
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(reveal)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let revealButton = NSButton(title: L.revealInFinder, target: self, action: #selector(reveal))
        let closeButton = NSButton(title: L.close, target: self, action: #selector(closeSheet(_:)))
        closeButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [revealButton, spacer, closeButton])

        let root = NSStackView(views: [title, body, scroll, footer], orientation: .vertical, alignment: .leading)
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            body.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window.contentView = content
    }

    /**
     * Reports the number of listed folders.
     *
     * @param {NSTableView} tableView - The folder table.
     * @returns {Int} One row per recorded folder.
     *
     * @example
     * table.reloadData() // AppKit calls numberOfRows(in:)
     */
    func numberOfRows(in tableView: NSTableView) -> Int { folders.count }

    /**
     * Provides the cell for a path or reason column.
     *
     * The path cell also shows the full path as a tooltip. The reason reads
     * "Protected by macOS" for EPERM and "Administrator (root) only" otherwise.
     *
     * @param {NSTableView} tableView - The folder table.
     * @param {NSTableColumn?} tableColumn - The column being drawn.
     * @param {Int} row - Row index into `folders`.
     * @returns {NSView?} A text cell, or nil without a column.
     *
     * @example
     * // Called by AppKit for each visible cell.
     */
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = tableView.cell(id) { TextCellView(identifier: id, alignment: .left, hasIcon: false) }
        let f = folders[row]
        if id == .colPath {
            cell.set(f.path)
            cell.toolTip = f.path
        } else {
            cell.set(f.isPrivacyProtected ? L.reasonProtected : L.reasonRootOnly, dimmed: true)
        }
        return cell
    }

    /**
     * Reveals folders in Finder.
     *
     * A double-clicked row outside the selection is revealed on its own;
     * otherwise every selected row is revealed.
     *
     * @example
     * table.doubleAction = #selector(reveal)
     */
    @objc private func reveal() {
        let rows = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        let urls = rows.map { URL(fileURLWithPath: folders[$0].path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /**
     * Ends the sheet and notifies the owner.
     *
     * @param {Any?} sender - The Close button.
     *
     * @example
     * closeButton.action = #selector(closeSheet(_:))
     */
    @objc private func closeSheet(_ sender: Any?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        onClose?()
    }
}

private extension NSStackView {
    /**
     * Creates a stack view with its orientation and alignment in one call.
     *
     * @param {[NSView]} views - Arranged subviews, in order.
     * @param {NSUserInterfaceLayoutOrientation} orientation - Horizontal or vertical stacking.
     * @param {NSLayoutConstraint.Attribute} alignment - Cross-axis alignment of the views.
     *
     * @example
     * let column = NSStackView(views: [title, body], orientation: .vertical, alignment: .leading)
     */
    convenience init(views: [NSView], orientation: NSUserInterfaceLayoutOrientation,
                     alignment: NSLayoutConstraint.Attribute) {
        self.init(views: views)
        self.orientation = orientation
        self.alignment = alignment
    }
}
