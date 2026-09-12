import AppKit
import UniformTypeIdentifiers

/** Text cell with an optional icon, used for every column except the bar columns. */
final class TextCellView: NSTableCellView {
    /** The cell's text. */
    let label = NSTextField(labelWithString: "")
    /** 16 pt icon shown before the text when the cell was created with one. */
    private let icon = NSImageView()
    /** Leading constraint of the label: after the icon, or at the cell edge. */
    private var labelLeading: NSLayoutConstraint!

    /**
     * Creates a reusable text cell.
     *
     * Right-aligned cells are treated as numeric columns: they use monospaced
     * digits and clip instead of truncating, so figures line up. Left-aligned
     * cells truncate in the middle, keeping both ends of long names visible.
     *
     * @param {NSUserInterfaceItemIdentifier} identifier - Reuse identifier, normally the column id.
     * @param {NSTextAlignment} alignment - Text alignment; `.right` selects the numeric style.
     * @param {Bool} hasIcon - Whether to reserve room for a 16 pt icon before the text.
     *
     * @example
     * let cell = TextCellView(identifier: .colSize, alignment: .right, hasIcon: false)
     */
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment, hasIcon: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = alignment == .right ? .byClipping : .byTruncatingMiddle
        label.alignment = alignment
        label.font = alignment == .right
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label

        if hasIcon {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
            ])
            labelLeading = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        } else {
            labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        }
        NSLayoutConstraint.activate([
            labelLeading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /**
     * Unsupported: cells are built in code only.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called; there are no nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Fills the cell for a row.
     *
     * Always resets the icon and colour too, since cells are reused across rows.
     *
     * @param {String} text - Text to show.
     * @param {NSImage?} [image=nil] - Icon to show; nil clears it.
     * @param {Bool} [dimmed=false] - Draw the text in the secondary colour (unreadable or secondary items).
     *
     * @example
     * cell.set(node.name, icon: Icons.icon(for: node), dimmed: node.flags.contains(.denied))
     */
    func set(_ text: String, icon image: NSImage? = nil, dimmed: Bool = false) {
        label.stringValue = text
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.image = image
    }
}

/** "% of parent" style cell: a proportional bar with the percentage on top. */
final class BarCellView: NSTableCellView {
    /** Filled share of the bar, 0…1 (values above 1 are drawn full). */
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    /** Colour of the filled part. */
    var barColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    /** Label drawn right-aligned over the bar, e.g. "35.1 %". */
    var text: String = "" { didSet { needsDisplay = true } }

    /**
     * Creates a reusable bar cell.
     *
     * @param {NSUserInterfaceItemIdentifier} identifier - Reuse identifier, normally the column id.
     *
     * @example
     * let cell = outlineView.cell(.colPercent) { BarCellView(identifier: .colPercent) }
     */
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    /**
     * Unsupported: cells are built in code only.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called; there are no nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Draws the track, the filled share and the percentage text.
     *
     * Any non-zero fraction gets at least a 1.5 pt sliver so tiny shares stay
     * visible.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw.
     *
     * @example
     * cell.fraction = 0.35 // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 3, dy: 3)
        let track = NSBezierPath(roundedRect: inset, xRadius: 2.5, yRadius: 2.5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        track.fill()
        if fraction > 0 {
            var fill = inset
            fill.size.width = max(1.5, inset.width * CGFloat(min(1, fraction)))
            let bar = NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5)
            barColor.withAlphaComponent(0.85).setFill()
            bar.fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: inset.maxX - size.width - 3, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

/** Small colour square plus extension name for the file-type list. */
final class SwatchCellView: NSTableCellView {
    /** Extension name, e.g. ".mov". */
    let label = NSTextField(labelWithString: "")
    /** Treemap colour of the extension, drawn as the swatch. */
    var color: NSColor = .gray { didSet { needsDisplay = true } }

    /**
     * Creates a reusable swatch cell with room for the 12 pt square before the label.
     *
     * @param {NSUserInterfaceItemIdentifier} identifier - Reuse identifier, normally the column id.
     *
     * @example
     * let cell = tableView.cell(.colExt) { SwatchCellView(identifier: .colExt) }
     */
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /**
     * Unsupported: cells are built in code only.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Never called; there are no nibs or storyboards.
     */
    required init?(coder: NSCoder) { fatalError() }

    /**
     * Draws the rounded colour square with a faint outline so light colours stay visible.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw.
     *
     * @example
     * cell.color = colors.nsColor(stat.id) // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 4, y: bounds.midY - 6, width: 12, height: 12)
        let p = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
        color.setFill()
        p.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        p.lineWidth = 0.5
        p.stroke()
    }
}

/**
 * 16 pt icons for tree and file rows.
 *
 * Main-thread only: the caches are plain static storage.
 */
enum Icons {
    /** Icon per extension id, filled on first use. */
    private static var byExt: [UInt16: NSImage] = [:]
    /** Generic folder icon. */
    static let folder: NSImage = sized(NSWorkspace.shared.icon(for: .folder))
    /** Volume icon, used for the scan root. */
    static let volume: NSImage = sized(NSWorkspace.shared.icon(for: .volume))
    /** Symbolic link icon. */
    static let symlink: NSImage = sized(NSWorkspace.shared.icon(for: .symbolicLink))
    /** Plain document icon for unknown types. */
    static let generic: NSImage = sized(NSWorkspace.shared.icon(for: .data))
    /** Padlock shown for folders that could not be read. */
    static let locked: NSImage = {
        let img = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? folder
        return img
    }()

    /** Real icons of `.app` bundles, keyed by path; evictable under memory pressure. */
    private static let bundleIcons = NSCache<NSString, NSImage>()

    /**
     * Picks the icon for a tree or file-list row.
     *
     * The scan root shows a volume icon, unreadable folders a padlock, app
     * bundles their own icon (looked up by path and cached), other folders the
     * folder icon. Files get the system icon for their extension's type,
     * cached per extension; unknown types fall back to a generic document.
     *
     * @param {Node} node - The row's node.
     * @returns {NSImage} A 16×16 icon.
     *
     * @example
     * cell.set(node.name, icon: Icons.icon(for: node))
     */
    static func icon(for node: Node) -> NSImage {
        if node.isDir {
            if node.parent == nil { return volume }
            if node.flags.contains(.denied) { return locked }
            if node.name.hasSuffix(".app") {
                let path = node.path as NSString
                if let img = bundleIcons.object(forKey: path) { return img }
                let img = sized(NSWorkspace.shared.icon(forFile: path as String))
                bundleIcons.setObject(img, forKey: path)
                return img
            }
            return folder
        }
        if node.flags.contains(.symlink) { return symlink }
        if let img = byExt[node.ext] { return img }
        let ext = ExtensionTable.shared.name(node.ext)
        let img: NSImage
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            img = sized(NSWorkspace.shared.icon(for: type))
        } else {
            img = generic
        }
        byExt[node.ext] = img
        return img
    }

    /**
     * Sets an image's display size to 16×16 points.
     *
     * Mutates and returns the same image; NSWorkspace hands out a fresh image
     * per call, so no shared icon is affected.
     *
     * @param {NSImage} image - Image to resize.
     * @returns {NSImage} The same image, now 16×16 points.
     *
     * @example
     * let icon = sized(NSWorkspace.shared.icon(for: .folder))
     */
    private static func sized(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

extension NSUserInterfaceItemIdentifier {
    /** Name column (tree, file list). */
    static let colName = NSUserInterfaceItemIdentifier("name")
    /** Percentage bar column. */
    static let colPercent = NSUserInterfaceItemIdentifier("percent")
    /** Logical size column. */
    static let colSize = NSUserInterfaceItemIdentifier("size")
    /** Allocated size column. */
    static let colAlloc = NSUserInterfaceItemIdentifier("alloc")
    /** Files plus folders column. */
    static let colItems = NSUserInterfaceItemIdentifier("items")
    /** File count column. */
    static let colFiles = NSUserInterfaceItemIdentifier("files")
    /** Folder count column. */
    static let colFolders = NSUserInterfaceItemIdentifier("folders")
    /** Modification date column. */
    static let colModified = NSUserInterfaceItemIdentifier("modified")
    /** Containing folder column (file list, unreadable-folders sheet). */
    static let colPath = NSUserInterfaceItemIdentifier("path")
    /** Extension column of the file-type list. */
    static let colExt = NSUserInterfaceItemIdentifier("ext")
    /** File count column of the file-type list. */
    static let colCount = NSUserInterfaceItemIdentifier("count")
}

extension NSTableView {
    /**
     * Adds a sortable column.
     *
     * The column's sort descriptor is keyed by the identifier's raw value, so
     * `sortDescriptorsDidChange` handlers can switch on the column id.
     *
     * @param {NSUserInterfaceItemIdentifier} id - Column identifier, also the sort key.
     * @param {String} title - Header title.
     * @param {CGFloat} width - Initial width in points.
     * @param {CGFloat} [minWidth=40] - Minimum width in points.
     * @param {NSTextAlignment} [alignment=.left] - Header alignment.
     * @param {Bool} [ascendingFirst=false] - Whether the first click sorts ascending (names) rather than descending (sizes).
     * @returns {NSTableColumn} The added column.
     *
     * @example
     * table.addColumn(.colSize, title: L.colSize, width: 80, alignment: .right)
     */
    @discardableResult
    func addColumn(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat = 40,
                   alignment: NSTextAlignment = .left, ascendingFirst: Bool = false) -> NSTableColumn {
        let col = NSTableColumn(identifier: id)
        col.title = title
        col.width = width
        col.minWidth = minWidth
        col.headerCell.alignment = alignment
        col.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: ascendingFirst)
        addTableColumn(col)
        return col
    }

    /**
     * Returns a recycled cell view for `id`, or makes a new one.
     *
     * @param {NSUserInterfaceItemIdentifier} id - Reuse identifier.
     * @param {() -> T} make - Builds a new cell when none can be reused.
     * @returns {T} A cell of the requested type.
     *
     * @example
     * let cell = tableView.cell(.colName) { TextCellView(identifier: .colName, alignment: .left, hasIcon: true) }
     */
    func cell<T: NSView>(_ id: NSUserInterfaceItemIdentifier, make: () -> T) -> T {
        if let v = makeView(withIdentifier: id, owner: nil) as? T { return v }
        return make()
    }
}
