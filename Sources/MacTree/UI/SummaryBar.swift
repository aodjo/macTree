import AppKit

/**
 * Horizontal bar showing total / used / free space with the scanned share highlighted.
 *
 * The grey part is the space the volume reports as used; the accent-coloured
 * part is how much of it the scan accounted for.
 */
final class UsageBarView: NSView {
    /** Volume capacity in bytes; 0 hides the bar's contents. */
    var total: Int64 = 0 { didSet { needsDisplay = true } }
    /** Bytes the volume reports as used. */
    var used: Int64 = 0 { didSet { needsDisplay = true } }
    /** Bytes found by the scan so far (in the current size mode). */
    var scanned: Int64 = 0 { didSet { needsDisplay = true } }

    /** Fixed 10 pt height; the width comes from constraints. */
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 10) }

    /**
     * Draws the rounded track, the used share and the scanned share.
     *
     * With no capacity only the empty track is drawn. The scanned share is
     * capped at the used share (or the total when used is unknown), since a
     * logical-size scan can exceed what the disk reports as used.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw (the whole bar is always drawn).
     *
     * @example
     * usageBar.scanned = 400_000_000_000 // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let track = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.3).setFill()
        track.fill()
        guard total > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        let usedW = r.width * CGFloat(Double(min(used, total)) / Double(total))
        let scannedW = r.width * CGFloat(Double(min(scanned, used > 0 ? used : total)) / Double(total))
        NSColor.systemGray.withAlphaComponent(0.55).setFill()
        NSRect(x: r.minX, y: r.minY, width: usedW, height: r.height).fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: r.minX, y: r.minY, width: scannedW, height: r.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/** Top strip: location, space usage, scan statistics and progress. */
final class SummaryBar: NSView {
    /** Volume or folder name. */
    let titleLabel = NSTextField(labelWithString: L.appName)
    /** Full path of the scanned location. */
    let detailLabel = NSTextField(labelWithString: L.ready)
    /** Total / used / scanned bar. */
    let usageBar = UsageBarView()
    /** Numbers under the bar: total, used, free and scanned. */
    let usageLabel = NSTextField(labelWithString: "")
    /** File and folder counts plus scan time, or live progress while scanning. */
    let statsLabel = NSTextField(labelWithString: "")
    /** Spins while a scan runs. */
    let spinner = NSProgressIndicator()
    /** Note about unreadable folders; clicking it calls `onWarningClicked`. */
    let warningButton = NSButton()

    /** Called when the unreadable-folders note is clicked. */
    var onWarningClicked: (() -> Void)?

    /**
     * Builds the strip's labels, bar, spinner and warning button and lays them out.
     *
     * The left third holds the title and path, the middle the usage bar, and
     * the right edge the statistics, spinner and warning. The strip is a fixed
     * 52 pt tall; long texts truncate instead of pushing neighbours.
     *
     * @param {NSRect} frameRect - Initial frame; normally `.zero` with Auto Layout.
     *
     * @example
     * let summary = SummaryBar()
     * summary.translatesAutoresizingMaskIntoConstraints = false
     */
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.lineBreakMode = .byTruncatingTail
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .right
        statsLabel.lineBreakMode = .byTruncatingHead

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        warningButton.bezelStyle = .inline
        warningButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        warningButton.imagePosition = .imageLeading
        warningButton.contentTintColor = .systemOrange
        warningButton.font = .systemFont(ofSize: 11)
        warningButton.target = self
        warningButton.action = #selector(warningClicked)
        warningButton.isHidden = true

        for v in [titleLabel, detailLabel, usageBar, usageLabel, statsLabel, spinner, warningButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let left = NSLayoutGuide()
        addLayoutGuide(left)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            left.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.34),
            titleLabel.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            usageBar.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            usageBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            usageBar.heightAnchor.constraint(equalToConstant: 10),
            usageBar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.30),
            usageLabel.leadingAnchor.constraint(equalTo: usageBar.leadingAnchor),
            usageLabel.trailingAnchor.constraint(equalTo: usageBar.trailingAnchor),
            usageLabel.topAnchor.constraint(equalTo: usageBar.bottomAnchor, constant: 4),

            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            spinner.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            statsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: usageBar.trailingAnchor, constant: 16),
            statsLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),
            statsLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            warningButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            warningButton.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 3),
            warningButton.leadingAnchor.constraint(greaterThanOrEqualTo: usageBar.trailingAnchor, constant: 16),

            heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    /**
     * Unsupported: the strip is built in code only.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called; there are no nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Draws the hairline separator along the bottom edge.
     *
     * The view is not flipped, so y = 0 is the bottom.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw.
     *
     * @example
     * summary.needsDisplay = true // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /**
     * Resets the strip to its "nothing scanned yet" state.
     *
     * Stops the spinner, shows the app name and the getting-started hint, and
     * clears the statistics, usage bar and warning.
     *
     * @example
     * summary.showIdle()
     */
    func showIdle() {
        spinner.stopAnimation(nil)
        titleLabel.stringValue = L.appName
        detailLabel.stringValue = L.ready
        statsLabel.stringValue = ""
        usageLabel.stringValue = ""
        usageBar.total = 0
        warningButton.isHidden = true
    }

    /**
     * Shows the scanned location and its volume's space figures.
     *
     * Without volume information (or a zero capacity) the bar and its label
     * are cleared. The "scanned" figure is appended only when `scanned` is
     * non-nil, which is how callers hide it while a scan is still running.
     *
     * @param {String} title - Volume or folder name shown in large type.
     * @param {String} path - Full path shown under the title.
     * @param {VolumeInfo?} volume - Capacity figures of the containing volume, if known.
     * @param {Int64?} scanned - Bytes found by the scan, or nil to omit that figure.
     *
     * @example
     * summary.showVolume(title: "Macintosh HD", path: "/", volume: VolumeInfo.info(for: url), scanned: nil)
     */
    func showVolume(title: String, path: String, volume: VolumeInfo?, scanned: Int64?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = path
        if let v = volume, v.total > 0 {
            usageBar.total = v.total
            usageBar.used = v.used
            usageBar.scanned = scanned ?? 0
            var parts = ["\(L.total) \(Fmt.bytes(v.total))", "\(L.used) \(Fmt.bytes(v.used))", "\(L.free) \(Fmt.bytes(v.available))"]
            if let scanned { parts.append("\(L.scanned) \(Fmt.bytes(scanned))") }
            usageLabel.stringValue = parts.joined(separator: "  ·  ")
        } else {
            usageBar.total = 0
            usageLabel.stringValue = ""
        }
    }

    /**
     * Shows live scan progress.
     *
     * Starts the spinner, writes the running file / folder / byte counts, hides
     * the warning and grows the bar's scanned share. Called about ten times a
     * second from the progress timer.
     *
     * @param {Scanner.Progress} p - A snapshot of the scanner's counters.
     *
     * @example
     * summary.showProgress(scanner.progress)
     */
    func showProgress(_ p: Scanner.Progress) {
        spinner.startAnimation(nil)
        statsLabel.stringValue = "\(L.scanning)…  \(Fmt.count(p.files)) \(L.files) · \(Fmt.count(p.dirs)) \(L.folders) · \(Fmt.bytes(p.bytes))"
        warningButton.isHidden = true
        usageBar.scanned = p.bytes
    }

    /**
     * Shows the final statistics of a finished or stopped scan.
     *
     * Stops the spinner and writes the file and folder totals and the scan
     * time, noting when results are partial. When folders could not be read,
     * the warning button appears: an orange call to action if a Full Disk
     * Access grant would reveal them, otherwise a quiet grey note about
     * protected system folders.
     *
     * @param {ScanResult} r - The completed scan.
     * @param {Bool} needsAccess - Whether Full Disk Access would make the unreadable folders readable.
     *
     * @example
     * summary.showResult(result, needsAccess: needsFullDiskAccess(for: result))
     */
    func showResult(_ r: ScanResult, needsAccess: Bool) {
        spinner.stopAnimation(nil)
        var s = "\(Fmt.count(Int(r.root.fileCount))) \(L.files) · \(Fmt.count(Int(r.root.dirCount))) \(L.folders) · \(Fmt.seconds(r.elapsed))"
        if r.cancelled { s += "  " + L.cancelledNote }
        statsLabel.stringValue = s
        if r.deniedCount > 0 {
            warningButton.title = " " + (needsAccess ? L.deniedNeedsAccess(r.deniedCount) : L.deniedSystem(r.deniedCount))
            warningButton.image = NSImage(systemSymbolName: needsAccess ? "exclamationmark.triangle.fill" : "info.circle",
                                          accessibilityDescription: nil)
            warningButton.contentTintColor = needsAccess ? .systemOrange : .secondaryLabelColor
            warningButton.isHidden = false
        } else {
            warningButton.isHidden = true
        }
    }

    /**
     * Forwards a click on the warning button to `onWarningClicked`.
     *
     * @example
     * summary.onWarningClicked = { controller.showUnreadableFolders() }
     */
    @objc private func warningClicked() { onWarningClicked?() }
}

/** Bottom status line: hovered or selected item on the left, file counts on the right. */
final class StatusBar: NSView {
    /** Left-aligned text; truncates in the middle so both ends of a path stay visible. */
    let label = NSTextField(labelWithString: "")
    /** Right-aligned text, e.g. the File View match count. */
    let rightLabel = NSTextField(labelWithString: "")

    /**
     * Builds the two labels and lays them out in a fixed 22 pt strip.
     *
     * The right label never compresses; the left one gives way and truncates.
     *
     * @param {NSRect} frameRect - Initial frame; normally `.zero` with Auto Layout.
     *
     * @example
     * let status = StatusBar()
     * status.label.stringValue = "/Applications"
     */
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [label, rightLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .secondaryLabelColor
            addSubview(l)
        }
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightLabel.alignment = .right
        rightLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    /**
     * Unsupported: the status bar is built in code only.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called; there are no nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Draws the hairline separator along the top edge.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw.
     *
     * @example
     * status.needsDisplay = true // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/** Breadcrumb above the treemap with zoom controls. */
final class TreemapHeader: NSView {
    /** Zooms out (whole folder first, then one folder up). */
    let upButton = NSButton()
    /** Returns to the whole scan. */
    let homeButton = NSButton()
    /** Path of what fills the treemap, plus the zoom factor. */
    let pathLabel = NSTextField(labelWithString: "")
    /** Mouse and wheel usage hint on the right. */
    let hintLabel = NSTextField(labelWithString: L.treemapHint)

    /**
     * Builds the zoom buttons, path label and hint and lays them out in a 26 pt strip.
     *
     * The path truncates at its head so the deepest folder stays readable; the
     * hint has the lowest compression priority and disappears first when narrow.
     *
     * @param {NSRect} frameRect - Initial frame; normally `.zero` with Auto Layout.
     *
     * @example
     * let header = TreemapHeader()
     * header.upButton.target = controller
     */
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        upButton.image = NSImage(systemSymbolName: "arrow.up.left", accessibilityDescription: L.zoomOut)
        upButton.toolTip = L.zoomOut
        homeButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: L.zoomReset)
        homeButton.toolTip = L.zoomReset
        for b in [upButton, homeButton] {
            b.bezelStyle = .accessoryBarAction
            b.isBordered = true
            b.controlSize = .small
        }
        pathLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        for v in [upButton, homeButton, pathLabel, hintLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            homeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            homeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            upButton.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 4),
            upButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /**
     * Unsupported: the header is built in code only.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called; there are no nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Fills the window background and draws hairlines along the top and bottom edges.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw.
     *
     * @example
     * header.needsDisplay = true // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
