import AppKit
import Synchronization

/** Receives the treemap's user interactions and viewport changes. */
protocol TreemapViewDelegate: AnyObject {
    /**
     * Called when the user clicks an item (or right-clicks it before its menu opens).
     *
     * @param {TreemapView} view - The treemap that was clicked.
     * @param {Node} node - The deepest laid-out node under the click.
     *
     * @example
     * func treemap(_ view: TreemapView, didSelect node: Node) { tree.reveal(node) }
     */
    func treemap(_ view: TreemapView, didSelect node: Node)

    /**
     * Called when the node under the pointer changes.
     *
     * @param {TreemapView} view - The treemap being hovered.
     * @param {Node?} node - The node now under the pointer, or nil when it left the treemap.
     *
     * @example
     * func treemap(_ view: TreemapView, didHover node: Node?) { updateStatus(for: node) }
     */
    func treemap(_ view: TreemapView, didHover node: Node?)

    /**
     * Called on double-click to show a folder on its own.
     *
     * The folder is the child of the currently framed folder along the clicked path.
     *
     * @param {TreemapView} view - The treemap that was double-clicked.
     * @param {Node} node - The folder to make the whole treemap.
     *
     * @example
     * func treemap(_ view: TreemapView, didZoomTo node: Node) { view.showFolder(node) }
     */
    func treemap(_ view: TreemapView, didZoomTo node: Node)

    /**
     * Called when the user keeps zooming out while the whole folder is already shown.
     *
     * The delegate typically moves up a folder level.
     *
     * @param {TreemapView} view - The treemap asking to zoom out.
     *
     * @example
     * func treemapDidRequestZoomOut(_ view: TreemapView) { zoomOut(nil) }
     */
    func treemapDidRequestZoomOut(_ view: TreemapView)

    /**
     * Asks for the context menu of an item.
     *
     * @param {TreemapView} view - The treemap that was right-clicked.
     * @param {Node} node - The node under the pointer.
     * @returns {NSMenu?} The menu to show, or nil for none.
     *
     * @example
     * func treemap(_ view: TreemapView, menuFor node: Node) -> NSMenu? { contextMenu(for: [node]) }
     */
    func treemap(_ view: TreemapView, menuFor node: Node) -> NSMenu?

    /**
     * Called when the zoom factor or the folder filling the view changed.
     *
     * @param {TreemapView} view - The treemap whose viewport changed.
     *
     * @example
     * func treemapViewportDidChange(_ view: TreemapView) { updateTreemapHeader() }
     */
    func treemapViewportDidChange(_ view: TreemapView)

    /**
     * Called when Delete is pressed while the treemap has focus.
     *
     * The delegate marks the current selection for permanent deletion, or
     * unmarks it when it is already marked.
     *
     * @param {TreemapView} view - The treemap that received the key.
     *
     * @example
     * func treemapDidRequestToggleMark(_ view: TreemapView) { toggleDeletionMark() }
     */
    func treemapDidRequestToggleMark(_ view: TreemapView)
}

/** Displays the cushion treemap with continuous zoom; rendering happens off the main thread. */
final class TreemapView: NSView {
    /** Receives selection, hover, zoom and menu requests. */
    weak var delegate: TreemapViewDelegate?

    /**
     * The directory laid out as the whole treemap.
     *
     * Changing it resets the zoom (or applies the viewport prepared by
     * `show(_:framing:)`), drops the stale layout and starts a new render.
     */
    var root: Node? {
        didSet {
            guard root !== oldValue else { return }
            let vp = pendingViewport
            pendingViewport = nil
            zoomScale = vp?.scale ?? 1
            zoomOffset = vp?.offset ?? .zero
            clampViewport()
            layout = nil
            hovered = nil
            focusNode = root
            setNeedsRender()
            delegate?.treemapViewportDidChange(self)
        }
    }
    /** Which size determines each rectangle's area; changing it re-renders. */
    var sizeMode: SizeMode = .allocated { didSet { if sizeMode != oldValue { setNeedsRender() } } }
    /** Colour per extension; setting it re-renders. */
    var colors: ExtColors? { didSet { setNeedsRender() } }
    /** Extension drawn in colour while everything else is dimmed, or nil for none. */
    var highlightExt: UInt16? { didSet { if highlightExt != oldValue { setNeedsRender() } } }
    /** Node outlined as the current selection. */
    var selected: Node? { didSet { if selected !== oldValue { needsDisplay = true } } }
    /** Text shown while there is nothing to draw. */
    var placeholder: String = L.ready { didSet { needsDisplay = true } }
    /** Nodes marked for permanent deletion, outlined in red. */
    var marked: [Node] = [] { didSet { needsDisplay = true } }

    /**
     * Continuous zoom inside `root`: 1 shows the whole folder. The layout is drawn
     * `zoomScale` times the view size and the view shows it from `zoomOffset`.
     */
    private(set) var zoomScale: CGFloat = 1
    /** Top-left corner of the view inside the zoomed layout, in points. */
    private(set) var zoomOffset: CGPoint = .zero
    /** Largest zoom factor; deep enough to see single small files on a full disk. */
    static let maxZoom: CGFloat = 10_000
    /** The deepest folder (or file) that fills the view. */
    private(set) var focusNode: Node?
    /** Viewport to apply when `root` changes next, set by `show(_:framing:)`. */
    private var pendingViewport: (scale: CGFloat, offset: CGPoint)?

    /** Node under the pointer; changes redraw and notify the delegate. */
    private(set) var hovered: Node? {
        didSet {
            if hovered !== oldValue {
                needsDisplay = true
                delegate?.treemap(self, didHover: hovered)
            }
        }
    }

    /** The last rendered picture. */
    private var image: CGImage?
    /** The layout matching `image`, used for hit testing and outlines. */
    private var layout: TreemapLayout?
    /** Zoom factor `image` was rendered at. */
    private var imageScale: CGFloat = 1
    /** Viewport offset `image` was rendered at. */
    private var imageOffset: CGPoint = .zero
    /** View size `image` was rendered for, in points. */
    private var imageSize: CGSize = .zero
    /** While switching folders, where the previous picture is drawn until the new one lands. */
    private var transitionFrame: CGRect?

    /** Bumped whenever a render is requested; results from older generations are discarded. */
    private var generation = 0
    /** Whether a render is running on `renderQueue`. */
    private var renderInFlight = false
    /** Whether another render was requested while one was running. */
    private var renderPending = false
    /** Serial queue that runs layout and shading. */
    private let renderQueue = DispatchQueue(label: "treemap.render", qos: .userInitiated)
    /** Tracking area for hover and exit events. */
    private var trackingArea: NSTrackingArea?

    /** Top-left origin, matching the renderer's pixel coordinates. */
    override var isFlipped: Bool { true }
    /** Accepts first responder so clicks take focus from the lists. */
    override var acceptsFirstResponder: Bool { true }
    /** The view paints every pixel, so AppKit need not draw behind it. */
    override var isOpaque: Bool { true }

    /**
     * Creates the treemap view.
     *
     * Layer-backed and redrawn only on `needsDisplay`, since the picture comes
     * from the background renderer.
     *
     * @param {NSRect} frameRect - Initial frame; usually `.zero` with Auto Layout.
     *
     * @example
     * let treemap = TreemapView(frame: .zero)
     */
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /**
     * Unsupported: the view is only built in code.
     *
     * @param {NSCoder} coder - Unused.
     *
     * @example
     * // Not used; the view is created with init(frame:).
     */
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rendering

    /**
     * Prepares for a tree mutation or replacement.
     *
     * Cancels in-flight renders and drops the layout, which references nodes.
     * The old picture stays on screen until the next render lands, to avoid
     * flashing. Call before changing the tree, then `setNeedsRender()` after.
     *
     * @example
     * treemap.invalidate()
     * treeLock.lock(); parent.children.remove(at: i); treeLock.unlock()
     * treemap.setNeedsRender()
     */
    func invalidate() {
        generation += 1
        for t in inFlight { t.cancel() }
        layout = nil
        hovered = nil
        needsDisplay = true
    }

    /**
     * Requests a new render with the current root, size, viewport and colours.
     *
     * Requests are coalesced: at most one render runs at a time and at most one
     * more is queued behind it, always with the latest state.
     *
     * @example
     * treemap.highlightExt = movID
     * treemap.setNeedsRender()
     */
    func setNeedsRender() {
        generation += 1
        if renderInFlight {
            renderPending = true
        } else {
            startRender()
        }
    }

    /**
     * Starts a render on the background queue.
     *
     * Captures the current viewport and view size so the result can be mapped
     * correctly even if the viewport changed while rendering. Results from an
     * outdated generation are dropped; a queued request starts the next render.
     * With no root or colours, the picture is cleared instead.
     *
     * @example
     * startRender()
     */
    private func startRender() {
        guard let root, let colors, bounds.width >= 1, bounds.height >= 1 else {
            image = nil
            layout = nil
            transitionFrame = nil
            needsDisplay = true
            return
        }
        let backing = window?.backingScaleFactor ?? 2
        let scale = zoomScale, offset = zoomOffset, size = bounds.size
        let params = TreemapRenderer.Params(
            width: Int((size.width * backing).rounded()),
            height: Int((size.height * backing).rounded()),
            sizeMode: sizeMode, colors: colors, highlightExt: highlightExt,
            scale: Double(scale), offsetX: Double(offset.x * backing), offsetY: Double(offset.y * backing))
        let gen = generation
        renderInFlight = true
        renderPending = false
        let token = CancelToken()
        inFlight.append(token)
        renderQueue.async { [weak self] in
            let result = TreemapRenderer.render(root: root, params: params) { token.isCancelled }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.removeAll { $0 === token }
                self.renderInFlight = false
                if let result, gen == self.generation {
                    self.image = result.0
                    self.layout = result.1
                    self.imageScale = scale
                    self.imageOffset = offset
                    self.imageSize = size
                    self.transitionFrame = nil
                    let focus = result.1.items.isEmpty ? root : result.1.items[result.1.focusIndex].node
                    if focus !== self.focusNode {
                        self.focusNode = focus
                        self.delegate?.treemapViewportDidChange(self)
                    }
                    self.needsDisplay = true
                    self.refreshHover()
                }
                if self.renderPending || gen != self.generation {
                    self.startRender()
                }
            }
        }
    }

    /** Thread-safe cancellation flag shared between the view and one render. */
    private final class CancelToken: @unchecked Sendable {
        /** Set once the render is no longer wanted. */
        private let flag = Atomic<Bool>(false)
        /** Whether `cancel()` has been called. */
        var isCancelled: Bool { flag.load(ordering: .relaxed) }

        /**
         * Marks the render as unwanted.
         *
         * The renderer polls the flag during layout and gives up early.
         *
         * @example
         * token.cancel()
         */
        func cancel() { flag.store(true, ordering: .relaxed) }
    }
    /** Tokens of renders still running, cancelled by `invalidate()`. */
    private var inFlight: [CancelToken] = []

    /**
     * Resizes the view and keeps looking at the same part of the layout.
     *
     * The zoom offset is scaled with the size change and clamped, then a new
     * render is requested. Until it lands, the old picture is stretched.
     *
     * @param {NSSize} newSize - The new frame size.
     *
     * @example
     * // Called by AppKit during window or split-view resizing.
     * treemap.setFrameSize(NSSize(width: 1200, height: 400))
     */
    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard newSize != old else { return }
        if old.width > 0, old.height > 0 {
            zoomOffset.x *= newSize.width / old.width
            zoomOffset.y *= newSize.height / old.height
            clampViewport()
        }
        setNeedsRender()
    }

    /**
     * Re-renders when the backing scale changes, e.g. after moving to another display.
     *
     * @example
     * // Called by AppKit when the window moves between Retina and non-Retina screens.
     */
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setNeedsRender()
    }

    // MARK: Picture ↔ view mapping

    /**
     * Maps a point of the rendered picture into the view under the current viewport.
     *
     * This lets zoom and pan respond instantly while the next render is on its
     * way. When the view was resized since the render, the picture is simply
     * stretched to the new size.
     *
     * @param {CGPoint} p - Point in picture coordinates (points).
     * @returns {CGPoint} The same spot in current view coordinates.
     *
     * @example
     * let origin = pictureToView(.zero)
     */
    private func pictureToView(_ p: CGPoint) -> CGPoint {
        if imageSize != bounds.size, imageSize.width > 0, imageSize.height > 0 {
            return CGPoint(x: p.x * bounds.width / imageSize.width, y: p.y * bounds.height / imageSize.height)
        }
        let k = zoomScale / imageScale
        return CGPoint(x: (p.x + imageOffset.x) * k - zoomOffset.x, y: (p.y + imageOffset.y) * k - zoomOffset.y)
    }

    /**
     * Maps a view point back into the rendered picture.
     *
     * Inverse of `pictureToView(_:)`, used for hit testing against the layout
     * that belongs to the current picture.
     *
     * @param {CGPoint} v - Point in view coordinates.
     * @returns {CGPoint} The same spot in picture coordinates (points).
     *
     * @example
     * let p = viewToPicture(convert(event.locationInWindow, from: nil))
     */
    private func viewToPicture(_ v: CGPoint) -> CGPoint {
        if imageSize != bounds.size, bounds.width > 0, bounds.height > 0 {
            return CGPoint(x: v.x * imageSize.width / bounds.width, y: v.y * imageSize.height / bounds.height)
        }
        let k = zoomScale / imageScale
        return CGPoint(x: (v.x + zoomOffset.x) / k - imageOffset.x, y: (v.y + zoomOffset.y) / k - imageOffset.y)
    }

    /**
     * Draws the picture, then the hover and selection outlines.
     *
     * The picture is placed through the current viewport (or the transition
     * frame while switching folders). Outlines come from the picture's layout,
     * so they are skipped while a zoom or pan preview is showing. A selection
     * outline around the entire view says nothing and is skipped as well.
     * Nodes marked for deletion get a red border and tint on top, drawn only
     * when the node itself is laid out (not a merged or culled ancestor).
     * Without a picture, the placeholder text is drawn when there is no root.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw.
     *
     * @example
     * treemap.needsDisplay = true // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
        ctx.fill(bounds)
        guard let image else {
            if root == nil { drawPlaceholder() }
            return
        }
        let frame: CGRect
        if let transitionFrame {
            frame = transitionFrame
        } else {
            let origin = pictureToView(.zero)
            let end = pictureToView(CGPoint(x: imageSize.width, y: imageSize.height))
            frame = CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
        }
        ctx.saveGState()
        ctx.interpolationQuality = .low
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height))
        ctx.restoreGState()

        guard transitionFrame == nil, imageScale == zoomScale, imageOffset == zoomOffset else { return }
        if let hovered, hovered !== selected, let r = rect(for: hovered) {
            NSColor.white.withAlphaComponent(0.55).setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
        if let selected, let r = rect(for: selected),
           !(r.minX <= 0 && r.minY <= 0 && r.maxX >= bounds.width && r.maxY >= bounds.height) {
            let outer = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            outer.lineWidth = 2
            NSColor.white.setStroke()
            outer.stroke()
            let inner = NSBezierPath(rect: r.insetBy(dx: 2.5, dy: 2.5))
            inner.lineWidth = 1
            NSColor.black.withAlphaComponent(0.7).setStroke()
            if r.width > 6 && r.height > 6 { inner.stroke() }
        }
        for node in marked {
            guard let r = exactRect(for: node) else { continue }
            NSColor.systemRed.withAlphaComponent(0.22).setFill()
            r.fill(using: .sourceOver)
            let border = NSBezierPath(rect: r.insetBy(dx: 1.25, dy: 1.25))
            border.lineWidth = 2.5
            NSColor.systemRed.setStroke()
            border.stroke()
        }
    }

    /**
     * View rect of a node that is laid out itself.
     *
     * Unlike `rect(for:)`, this does not fall back to an ancestor, so a node
     * that is too small to draw or outside the view yields nil.
     *
     * @param {Node} node - The node to locate.
     * @returns {NSRect?} Its rect in view points, or nil if it is not drawn.
     *
     * @example
     * if let r = exactRect(for: markedNode) { NSBezierPath(rect: r).stroke() }
     */
    private func exactRect(for node: Node) -> NSRect? {
        guard let layout, let i = layout.find(node), layout.items[i].node === node else { return nil }
        return viewRect(ofItem: i)
    }

    /**
     * Draws `placeholder` centred in the view.
     *
     * @example
     * if root == nil { drawPlaceholder() }
     */
    private func drawPlaceholder() {
        let text = placeholder as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45),
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    /**
     * Returns the view rectangle of a laid-out item.
     *
     * Converts the item's pixel bounds to picture points, then through the
     * current viewport.
     *
     * @param {Int} i - Index into the layout's items.
     * @returns {NSRect?} The rectangle in view points, or nil without a layout.
     *
     * @example
     * if let r = viewRect(ofItem: 0) { NSBezierPath(rect: r).stroke() }
     */
    private func viewRect(ofItem i: Int) -> NSRect? {
        guard let layout, layout.width > 0, layout.height > 0, imageSize.width > 0 else { return nil }
        let it = layout.items[i]
        let sx = imageSize.width / CGFloat(layout.width), sy = imageSize.height / CGFloat(layout.height)
        let a = pictureToView(CGPoint(x: CGFloat(it.x0) * sx, y: CGFloat(it.y0) * sy))
        let b = pictureToView(CGPoint(x: CGFloat(it.x1) * sx, y: CGFloat(it.y1) * sy))
        return NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /**
     * Returns the view rectangle for a node, or for its nearest drawn ancestor.
     *
     * @param {Node} node - The node to locate.
     * @returns {NSRect?} The rectangle in view points, or nil when the node is not in the layout.
     *
     * @example
     * if let r = rect(for: selected) { outline(r) }
     */
    private func rect(for node: Node) -> NSRect? {
        guard let layout, let i = layout.find(node) else { return nil }
        return viewRect(ofItem: i)
    }

    /**
     * Returns the node under a view point.
     *
     * Hit-tests the layout of the current picture; returns nil while a folder
     * transition is showing, since the old picture no longer matches the root.
     *
     * @param {NSPoint} point - Point in view coordinates.
     * @returns {Node?} The deepest laid-out node there, or nil.
     *
     * @example
     * let n = treemap.node(at: convert(event.locationInWindow, from: nil))
     */
    func node(at point: NSPoint) -> Node? {
        guard transitionFrame == nil, let layout, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let p = viewToPicture(point)
        let x = Int(p.x * CGFloat(layout.width) / imageSize.width)
        let y = Int(p.y * CGFloat(layout.height) / imageSize.height)
        guard let i = layout.hitTest(x: x, y: y) else { return nil }
        return layout.items[i].node
    }

    // MARK: Viewport

    /**
     * Keeps the zoom within 1…`maxZoom` and the view inside the zoomed layout.
     *
     * @example
     * zoomOffset.x -= 50
     * clampViewport()
     */
    private func clampViewport() {
        zoomScale = min(TreemapView.maxZoom, max(1, zoomScale))
        let maxX = max(0, bounds.width * zoomScale - bounds.width)
        let maxY = max(0, bounds.height * zoomScale - bounds.height)
        zoomOffset.x = min(maxX, max(0, zoomOffset.x))
        zoomOffset.y = min(maxY, max(0, zoomOffset.y))
    }

    /**
     * Sets the zoom factor and offset.
     *
     * Values are clamped. The current picture is shown transformed right away
     * and a sharp render is requested. The delegate hears about it when the
     * zoom factor actually changed.
     *
     * @param {CGFloat} scale - Zoom factor, 1 for the whole folder.
     * @param {CGPoint} offset - Top-left of the view inside the zoomed layout, in points.
     *
     * @example
     * treemap.setViewport(scale: 4, offset: CGPoint(x: 600, y: 200))
     */
    func setViewport(scale: CGFloat, offset: CGPoint) {
        let oldScale = zoomScale
        zoomScale = scale
        zoomOffset = offset
        clampViewport()
        needsDisplay = true
        setNeedsRender()
        if zoomScale != oldScale { delegate?.treemapViewportDidChange(self) }
    }

    /**
     * Zooms by `factor`, keeping the layout point under `anchor` in place.
     *
     * Like zooming a map around the pointer. When the zoom is already at its
     * limit, zooming out further counts towards moving up a folder level.
     *
     * @param {CGFloat} factor - Multiplier for the zoom; above 1 zooms in, below 1 zooms out.
     * @param {NSPoint} anchor - Point in view coordinates that stays fixed.
     *
     * @example
     * treemap.zoom(by: 2, at: NSPoint(x: 300, y: 120))
     */
    func zoom(by factor: CGFloat, at anchor: NSPoint) {
        guard root != nil, factor > 0 else { return }
        let target = min(TreemapView.maxZoom, max(1, zoomScale * factor))
        if target == zoomScale {
            if factor < 1 { pushOutward(factor) }
            return
        }
        outwardPressure = 0
        let k = target / zoomScale
        setViewport(scale: target, offset: CGPoint(x: (anchor.x + zoomOffset.x) * k - anchor.x,
                                                   y: (anchor.y + zoomOffset.y) * k - anchor.y))
    }

    /**
     * Returns to the whole folder at zoom 1.
     *
     * @example
     * treemap.resetZoom()
     */
    func resetZoom() {
        setViewport(scale: 1, offset: .zero)
    }

    /** Accumulated log zoom-out while already at zoom 1. */
    private var outwardPressure: CGFloat = 0
    /** Time of the last zoom-out attempt at zoom 1, to reset stale pressure. */
    private var lastOutward = Date.distantPast

    /**
     * Collects zoom-out gestures made while the whole folder is already shown.
     *
     * After about 30% more outward zoom within a short burst, asks the delegate
     * to go up a level, so a single stray wheel notch does not jump folders.
     * Pressure older than 0.4 s is forgotten.
     *
     * @param {CGFloat} factor - The zoom-out factor (below 1) that could not be applied.
     *
     * @example
     * if target == zoomScale, factor < 1 { pushOutward(factor) }
     */
    private func pushOutward(_ factor: CGFloat) {
        if Date().timeIntervalSince(lastOutward) > 0.4 { outwardPressure = 0 }
        lastOutward = Date()
        outwardPressure += log(factor)
        if outwardPressure < log(0.7) {
            outwardPressure = 0
            delegate?.treemapDidRequestZoomOut(self)
        }
    }

    /**
     * Shows `node` as the whole treemap, optionally keeping `child` framed.
     *
     * With `child`, the view starts zoomed so that `child` still fills it, which
     * makes going up a level feel continuous: further zooming out reveals its
     * neighbours. Until the new render lands, the old picture keeps showing in
     * the spot where that folder now sits. If `node` is already the root, only
     * the viewport changes.
     *
     * @param {Node} node - The folder to lay out as the whole treemap.
     * @param {Node?} child - A descendant to keep framed, or nil to start unzoomed.
     *
     * @example
     * if let parent = current.parent { treemap.show(parent, framing: current) }
     */
    func show(_ node: Node, framing child: Node?) {
        var viewport: (scale: CGFloat, offset: CGPoint)?
        var frame: CGRect?
        let w = bounds.width, h = bounds.height
        if let child, w > 0, h > 0,
           let r = TreemapRenderer.rect(of: child, in: node, width: Double(w), height: Double(h), mode: sizeMode),
           r.width > 0, r.height > 0 {
            let s = min(TreemapView.maxZoom, max(1, min(w / r.width, h / r.height)))
            let off = CGPoint(x: r.midX * s - w / 2, y: r.midY * s - h / 2)
            viewport = (s, off)
            if image != nil, zoomScale == 1 {
                frame = CGRect(x: r.minX * s - off.x, y: r.minY * s - off.y, width: r.width * s, height: r.height * s)
            }
        }
        if node === root {
            if let viewport { setViewport(scale: viewport.scale, offset: viewport.offset) }
            return
        }
        pendingViewport = viewport
        root = node
        transitionFrame = frame
        needsDisplay = true
    }

    /**
     * Makes `node` the whole treemap (double-click or "Zoom Here").
     *
     * When the folder is visible in the current picture, that part of the
     * picture is stretched to fill the view until the new render lands, so the
     * folder appears to grow into place.
     *
     * @param {Node} node - The folder to show on its own.
     *
     * @example
     * treemap.showFolder(downloadsNode)
     */
    func showFolder(_ node: Node) {
        var frame: CGRect?
        if image != nil, let i = layout?.find(node), layout?.items[i].node === node, let r = viewRect(ofItem: i),
           r.width > 1, r.height > 1 {
            let kx = bounds.width / r.width, ky = bounds.height / r.height
            frame = CGRect(x: -r.minX * kx, y: -r.minY * ky, width: bounds.width * kx, height: bounds.height * ky)
        }
        root = node
        transitionFrame = frame
        needsDisplay = true
    }

    /**
     * Pans, zooming out if needed, so that `node` is on screen.
     *
     * Does nothing at zoom 1 (everything is visible) or when the node is
     * already fully in view. If the node is larger than 90% of the view at the
     * current zoom, the zoom is reduced to fit it; the node is then centred.
     *
     * @param {Node} node - The node chosen in the tree or file list.
     *
     * @example
     * treemap.selected = node
     * treemap.reveal(node)
     */
    func reveal(_ node: Node) {
        guard let root, zoomScale > 1, bounds.width > 0, bounds.height > 0,
              let r = TreemapRenderer.rect(of: node, in: root, width: Double(bounds.width),
                                           height: Double(bounds.height), mode: sizeMode) else { return }
        var s = zoomScale
        let visible = CGRect(x: r.minX * s - zoomOffset.x, y: r.minY * s - zoomOffset.y,
                             width: r.width * s, height: r.height * s)
        if bounds.contains(visible) { return }
        if visible.width > bounds.width * 0.9 || visible.height > bounds.height * 0.9 {
            s = max(1, min(s, 0.9 * min(bounds.width / r.width, bounds.height / r.height)))
        }
        setViewport(scale: s, offset: CGPoint(x: r.midX * s - bounds.width / 2, y: r.midY * s - bounds.height / 2))
    }

    // MARK: Mouse

    /**
     * Replaces the tracking area so hover events cover the current bounds.
     *
     * Hover is tracked only while the window is key.
     *
     * @example
     * // Called by AppKit whenever the view's geometry changes.
     */
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /** Last pointer position inside the view, to refresh hover after a render. */
    private var lastMouse: NSPoint?
    /** Where the current mouse press started, or nil when no press is being tracked. */
    private var dragStart: NSPoint?
    /** Zoom offset when the press started, the base for panning. */
    private var dragStartOffset: CGPoint = .zero
    /** Whether the current drag has turned into a pan. */
    private var isPanning = false

    /**
     * Updates the hovered node as the pointer moves.
     *
     * @param {NSEvent} event - The mouse-moved event.
     *
     * @example
     * // Called by AppKit through the tracking area.
     */
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastMouse = p
        hovered = node(at: p)
    }

    /**
     * Clears the hover when the pointer leaves the view.
     *
     * @param {NSEvent} event - The mouse-exited event.
     *
     * @example
     * // Called by AppKit through the tracking area.
     */
    override func mouseExited(with event: NSEvent) {
        lastMouse = nil
        hovered = nil
    }

    /**
     * Recomputes the hovered node at the last pointer position.
     *
     * Needed after a render, because the same pointer position may now lie
     * over a different node.
     *
     * @example
     * refreshHover()
     */
    private func refreshHover() {
        if let p = lastMouse { hovered = node(at: p) }
    }

    /**
     * Starts tracking a click or drag; a double-click zooms into a folder.
     *
     * The first click is only resolved on mouse-up, so a drag can become a pan
     * instead of a selection. On the second click of a double-click, the delegate
     * is asked to show the folder one level below the framed one.
     *
     * @param {NSEvent} event - The mouse-down event.
     *
     * @example
     * // Called by AppKit when the user presses the mouse button over the treemap.
     */
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        dragStartOffset = zoomOffset
        isPanning = false
        if event.clickCount == 2 {
            dragStart = nil
            if let n = node(at: p), let target = zoomTarget(for: n) { delegate?.treemap(self, didZoomTo: target) }
        }
    }

    /**
     * Pans the zoomed treemap while dragging.
     *
     * Only when zoomed in; the drag must move more than 3 points before it
     * counts as a pan, so small jitters during a click still select.
     *
     * @param {NSEvent} event - The mouse-dragged event.
     *
     * @example
     * // Called by AppKit while the user drags over the treemap.
     */
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, zoomScale > 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !isPanning && hypot(p.x - start.x, p.y - start.y) > 3 {
            isPanning = true
            NSCursor.closedHand.push()
        }
        if isPanning {
            setViewport(scale: zoomScale, offset: CGPoint(x: dragStartOffset.x - (p.x - start.x),
                                                          y: dragStartOffset.y - (p.y - start.y)))
        }
    }

    /**
     * Ends a pan, or selects the node under a plain click.
     *
     * The second click of a double-click is ignored here because mouse-down
     * already zoomed.
     *
     * @param {NSEvent} event - The mouse-up event.
     *
     * @example
     * // Called by AppKit when the user releases the mouse button.
     */
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if isPanning {
            isPanning = false
            NSCursor.pop()
            return
        }
        guard let start = dragStart, event.clickCount == 1, let n = node(at: start) else { return }
        delegate?.treemap(self, didSelect: n)
    }

    /**
     * Finds the folder one level below the one filling the view, along the clicked path.
     *
     * When a single file fills the view, counting starts from its folder.
     * Returns nil when the clicked node is not below that folder or the target
     * is a file or an empty folder.
     *
     * @param {Node} n - The node that was double-clicked.
     * @returns {Node?} The folder to zoom into, or nil.
     *
     * @example
     * if let target = zoomTarget(for: clicked) { delegate?.treemap(self, didZoomTo: target) }
     */
    private func zoomTarget(for n: Node) -> Node? {
        guard let base = (focusNode?.isDir == false ? focusNode?.parent : focusNode) ?? root else { return nil }
        var child: Node? = n
        while let c = child, c.parent !== base {
            child = c.parent
        }
        guard let c = child, c.parent === base else { return nil }
        return c.isDir && !c.children.isEmpty ? c : nil
    }

    /**
     * Selects the node under the pointer and returns its context menu.
     *
     * @param {NSEvent} event - The right-click (or control-click) event.
     * @returns {NSMenu?} The delegate's menu, or nil when nothing is under the pointer.
     *
     * @example
     * // Called by AppKit on right-click.
     */
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let n = node(at: p) else { return nil }
        delegate?.treemap(self, didSelect: n)
        return delegate?.treemap(self, menuFor: n)
    }

    /**
     * Sends Delete (without modifiers) to the delegate as a deletion-mark toggle.
     *
     * Other keys keep the default behaviour.
     *
     * @param {NSEvent} event - The key-down event.
     *
     * @example
     * // Click a rectangle, then press Delete to mark it.
     */
    override func keyDown(with event: NSEvent) {
        if event.isPlainDeleteKey {
            delegate?.treemapDidRequestToggleMark(self)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Wheel / pinch zoom

    /**
     * Zooms around the pointer with the scroll wheel or two-finger scroll.
     *
     * Wheel forward (or two fingers up) zooms in, back zooms out, regardless of
     * the natural-scrolling setting. Momentum events are ignored so the inertia
     * after a trackpad flick does not keep zooming. Trackpads and Magic Mouse
     * zoom in proportion to the scroll distance; notched wheels zoom 30% per
     * notch, capped at four notches per event.
     *
     * @param {NSEvent} event - The scroll event.
     *
     * @example
     * // Called by AppKit when the user scrolls over the treemap.
     */
    override func scrollWheel(with event: NSEvent) {
        guard root != nil else { return }
        if !event.momentumPhase.isEmpty { return }
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        guard dy != 0 else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas
            ? exp(dy * 0.012)
            : pow(1.3, max(-4, min(4, dy)))
        zoom(by: factor, at: convert(event.locationInWindow, from: nil))
    }

    /**
     * Zooms around the pointer with a trackpad pinch.
     *
     * @param {NSEvent} event - The magnify event; its magnification is the relative change.
     *
     * @example
     * // Called by AppKit during a pinch gesture over the treemap.
     */
    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }
}
