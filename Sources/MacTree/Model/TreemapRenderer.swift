import AppKit

/**
 * Serialises tree mutations against background readers.
 *
 * The main thread takes it while trashing, rescanning or re-sorting; the
 * treemap layout pass and the file-list builder take it while they walk the tree.
 */
let treeLock = NSLock()

/**
 * Pixel-space layout of a rendered treemap, kept for hit testing and highlighting.
 *
 * Coordinates are view pixels; items reaching past the view are clamped to it (±1).
 * Items form a tree through first-child / next-sibling links in `items`.
 */
final class TreemapLayout {
    /** One laid-out rectangle and its links to the rest of the layout tree. */
    struct Item {
        /** The file or directory this rectangle shows. */
        let node: Node
        /** Clamped pixel bounds: left, top, right and bottom (exclusive). */
        let x0: Int32, y0: Int32, x1: Int32, y1: Int32
        /** Index of the first laid-out child, or -1. */
        var firstChild: Int32 = -1
        /** Index of the next laid-out sibling, or -1. */
        var nextSibling: Int32 = -1
    }

    /** All laid-out items; index 0 is the root. */
    var items: [Item] = []
    /** Width of the rendered picture in pixels. */
    let width: Int
    /** Height of the rendered picture in pixels. */
    let height: Int
    /** Index of the deepest item that covers the whole view: the folder being looked at. */
    private(set) var focusIndex = 0

    /**
     * Creates an empty layout for a picture of the given pixel size.
     *
     * The renderer fills `items` while it lays out the tree.
     *
     * @param {Int} width - Picture width in pixels.
     * @param {Int} height - Picture height in pixels.
     *
     * @example
     * let layout = TreemapLayout(width: 2400, height: 800)
     */
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /**
     * Finds the deepest laid-out item under a pixel.
     *
     * Descends from the root through the child whose rectangle contains the
     * point. Items too small to be laid out resolve to their nearest drawn
     * ancestor.
     *
     * @param {Int} x - Horizontal pixel coordinate.
     * @param {Int} y - Vertical pixel coordinate (top-left origin).
     * @returns {Int?} Index into `items`, or nil if the point is outside the root.
     *
     * @example
     * if let i = layout.hitTest(x: 120, y: 48) { print(layout.items[i].node.path) }
     */
    func hitTest(x: Int, y: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        let x = Int32(x), y = Int32(y)
        var current = 0
        guard contains(items[0], x, y) else { return nil }
        while true {
            var child = items[current].firstChild
            var found: Int32 = -1
            while child >= 0 {
                if contains(items[Int(child)], x, y) { found = child; break }
                child = items[Int(child)].nextSibling
            }
            if found < 0 { return current }
            current = Int(found)
        }
    }

    /**
     * Finds the item that shows a node.
     *
     * Follows the node's ancestor chain down from the layout root. When the
     * node itself was not laid out (too small, culled or merged), the nearest
     * laid-out ancestor is returned instead.
     *
     * @param {Node} node - A node inside the layout's root.
     * @returns {Int?} Index into `items`, or nil when the node is not under the root.
     *
     * @example
     * if let i = layout.find(selectedNode) { highlight(layout.items[i]) }
     */
    func find(_ node: Node) -> Int? {
        guard !items.isEmpty else { return nil }
        let root = items[0].node
        var chain: [Node] = [node]
        var n = node.parent
        while let p = n, chain.last !== root {
            chain.append(p)
            n = p.parent
        }
        guard chain.last === root else { return nil }
        var current = 0
        for target in chain.reversed().dropFirst() {
            var child = items[current].firstChild
            var found: Int32 = -1
            while child >= 0 {
                if items[Int(child)].node === target { found = child; break }
                child = items[Int(child)].nextSibling
            }
            if found < 0 { break }
            current = Int(found)
        }
        return current
    }

    /**
     * Updates `focusIndex` to the deepest item covering the entire view.
     *
     * Called once after layout. At zoom 1 that is the root; when zoomed deep
     * into one folder (or file), it is that folder, which the header shows.
     *
     * @example
     * layout.computeFocus()
     * let focus = layout.items[layout.focusIndex].node
     */
    func computeFocus() {
        guard !items.isEmpty else { return }
        var current = 0
        while true {
            var child = items[current].firstChild
            var next: Int32 = -1
            while child >= 0 {
                let it = items[Int(child)]
                if it.x0 <= 0 && it.y0 <= 0 && Int(it.x1) >= width && Int(it.y1) >= height {
                    next = child
                    break
                }
                child = it.nextSibling
            }
            if next < 0 { break }
            current = Int(next)
        }
        focusIndex = current
    }

    /**
     * Tests whether a pixel lies inside an item's rectangle.
     *
     * Bounds are half-open: the right and bottom edges belong to the neighbour.
     *
     * @param {Item} it - The item to test.
     * @param {Int32} x - Horizontal pixel coordinate.
     * @param {Int32} y - Vertical pixel coordinate.
     * @returns {Bool} True if the pixel is inside.
     *
     * @example
     * contains(items[0], 10, 10)
     */
    @inline(__always) private func contains(_ it: Item, _ x: Int32, _ y: Int32) -> Bool {
        x >= it.x0 && x < it.x1 && y >= it.y0 && y < it.y1
    }
}

/**
 * Squarified treemap with cushion shading (van Wijk & van de Wetering),
 * in the style of WinDirStat / WizTree, with a zoomable viewport.
 */
enum TreemapRenderer {
    /** Everything one render needs besides the tree itself. */
    struct Params {
        /** Output width in pixels (the visible view). */
        var width: Int
        /** Output height in pixels (the visible view). */
        var height: Int
        /** Which size determines each rectangle's area. */
        var sizeMode: SizeMode
        /** Colour per extension. */
        var colors: ExtColors
        /** When set, every other extension is drawn in dimmed grey. */
        var highlightExt: UInt16?
        /** Zoom factor: the whole root spans `width × scale` by `height × scale` pixels… */
        var scale: Double = 1
        /** …of which the view shows the part starting at this horizontal offset (pixels)… */
        var offsetX: Double = 0
        /** …and this vertical offset (pixels). */
        var offsetY: Double = 0
    }

    /** Cushion height added at the root level. */
    private static let initialHeight = 0.40
    /** Factor by which the cushion height shrinks per nesting level. */
    private static let scaleFactor = 0.90
    /** Ambient light share, so cushion edges never go fully black. */
    private static let ambient: Float = 0.18
    /** Overall brightness boost applied to the base colours. */
    private static let brightness: Float = 1.18
    /** Normalised light direction, from the top left and mostly frontal. */
    private static let light: (x: Double, y: Double, z: Double) = {
        let (x, y, z) = (-1.0, -1.0, 10.0)
        let len = (x * x + y * y + z * z).squareRoot()
        return (x / len, y / len, z / len)
    }()

    /** Directories smaller than this (pixels, either side) are drawn as one block. */
    private static let minDirSide = 3.0
    /** Children below this many square pixels are merged into one block. */
    private static let minArea = 2.0
    /** Deepest nesting level laid out; keeps single-child chains from exhausting the stack. */
    private static let maxDepth = 160

    /** One visible cushion to shade: its clamped pixel bounds, surface and colour. */
    private struct Leaf {
        /** Pixel bounds clipped to the view: left, top, right and bottom (exclusive). */
        let x0: Int32, y0: Int32, x1: Int32, y1: Int32
        /** Cushion surface coefficients accumulated from all enclosing rectangles. */
        let s0: Double, s1: Double, s2: Double, s3: Double
        /** Base colour before shading. */
        let color: RGB
    }

    /**
     * Lays out children with the squarified algorithm.
     *
     * Places `kids[0..<n]` (sorted largest first) into the rectangle row by row,
     * adding a child to the current row only while that keeps the row's worst
     * aspect ratio from getting worse. Each row runs along the shorter side of
     * the space left. Once the next child would get less than `minArea` square
     * pixels, all remaining space is handed to `rest` and the loop ends. Used
     * both by the renderer and by the pure geometry in `rect(of:in:width:height:mode:)`.
     *
     * @param {[Node]} kids - Children, sorted largest first.
     * @param {Int} n - How many leading children have a positive size.
     * @param {(Node) -> Double} metric - Size of a child.
     * @param {Double} x - Left edge of the area.
     * @param {Double} y - Top edge of the area.
     * @param {Double} w - Width of the area.
     * @param {Double} h - Height of the area.
     * @param {Double} minArea - Smallest area a child may get before the rest is merged.
     * @param {() -> Bool} [shouldStop={ false }] - Polled per row; returning true stops early.
     * @param {(Int, Double, Double, Double, Double) -> Void} place - Receives a child index and its rectangle.
     * @param {(Int, Double, Double, Double, Double) -> Void} rest - Receives the first merged child index and the leftover rectangle.
     *
     * @example
     * squarify(kids, kids.count, metric: { Double($0.alloc) }, x: 0, y: 0, w: 800, h: 600, minArea: 2,
     *          place: { k, x, y, w, h in print(kids[k].name, x, y, w, h) }, rest: { _, _, _, _, _ in })
     */
    @inline(__always)
    private static func squarify(_ kids: [Node], _ n: Int, metric: (Node) -> Double,
                                 x: Double, y: Double, w: Double, h: Double, minArea: Double,
                                 shouldStop: () -> Bool = { false },
                                 place: (Int, Double, Double, Double, Double) -> Void,
                                 rest: (Int, Double, Double, Double, Double) -> Void) {
        var remaining = 0.0
        for k in 0..<n { remaining += metric(kids[k]) }
        var rx = x, ry = y, rw = w, rh = h
        var i = 0
        while i < n && !shouldStop() {
            if rw <= 0 || rh <= 0 || remaining <= 0 { break }
            let areaScale = (rw * rh) / remaining
            if metric(kids[i]) * areaScale < minArea {
                rest(i, rx, ry, rw, rh)
                break
            }
            let vertical = rw >= rh
            let side = vertical ? rh : rw
            let maxA = metric(kids[i]) * areaScale
            var rowSum = 0.0
            var worst = Double.infinity
            var j = i
            while j < n {
                let s = metric(kids[j])
                let newSum = rowSum + s
                let t = newSum * areaScale / side
                let tt = t * t
                let newWorst = max(tt / (s * areaScale), maxA / tt)
                if j > i && newWorst > worst { break }
                worst = newWorst
                rowSum = newSum
                j += 1
            }
            let t = rowSum * areaScale / side
            var offset = 0.0
            for k in i..<j {
                let len = metric(kids[k]) * areaScale / t
                if vertical {
                    place(k, rx, ry + offset, t, len)
                } else {
                    place(k, rx + offset, ry, len, t)
                }
                offset += len
            }
            if vertical { rx += t; rw -= t } else { ry += t; rh -= t }
            remaining -= rowSum
            i = j
        }
    }

    /** State of one layout pass: the layout being built and the cushions left to shade. */
    private final class Builder {
        /** The render's parameters. */
        let params: Params
        /** The layout being filled in. */
        let layout: TreemapLayout
        /** Visible cushions collected for the shading pass. */
        var leaves: [Leaf] = []
        /** Polled now and then; true abandons the pass. */
        let isCancelled: () -> Bool
        /** Set once cancellation was observed, to unwind the recursion. */
        var cancelled = false
        /** View width in pixels, as a Double for geometry. */
        let viewW: Double
        /** View height in pixels, as a Double for geometry. */
        let viewH: Double

        /**
         * Prepares a layout pass for one render.
         *
         * @param {Params} params - Output size, viewport, colours and size mode.
         * @param {() -> Bool} isCancelled - Checked during layout; true abandons the pass.
         *
         * @example
         * let builder = Builder(params: params) { token.isCancelled }
         */
        init(params: Params, isCancelled: @escaping () -> Bool) {
            self.params = params
            self.layout = TreemapLayout(width: params.width, height: params.height)
            self.isCancelled = isCancelled
            viewW = Double(params.width)
            viewH = Double(params.height)
        }

        /**
         * Returns the size that determines a node's area.
         *
         * @param {Node} n - The node to measure.
         * @returns {Double} Logical or allocated bytes, per `params.sizeMode`.
         *
         * @example
         * let total = kids.reduce(0) { $0 + metric($1) }
         */
        @inline(__always) func metric(_ n: Node) -> Double {
            Double(params.sizeMode == .allocated ? n.alloc : n.size)
        }

        /**
         * Picks the base colour for a leaf.
         *
         * Files use their extension's colour. A directory drawn as a single block
         * (too small to subdivide) uses the colour of its largest file. With an
         * extension highlighted, everything else becomes a dim grey that keeps a
         * hint of the original brightness.
         *
         * @param {Node} node - The file or directory being drawn as one block.
         * @returns {RGB} The colour to shade.
         *
         * @example
         * addLeaf(x0, y0, x1, y1, surface, color(for: node))
         */
        func color(for node: Node) -> RGB {
            let file = node.isDir ? node.dominantFile : node
            let ext = file?.ext ?? 0
            var c = params.colors.color(ext)
            if let hl = params.highlightExt, hl != ext || file == nil {
                let lum = (c.r * 0.3 + c.g * 0.59 + c.b * 0.11) * 0.35 + 0.08
                c = RGB(lum, lum, lum)
            }
            return c
        }

        /**
         * Clamps a horizontal coordinate to just outside the view.
         *
         * Keeps stored rectangles within Int32 range even at high zoom, where
         * layout coordinates can be millions of pixels away.
         *
         * @param {Double} v - Horizontal pixel coordinate.
         * @returns {Int32} The coordinate limited to -1…width+1.
         *
         * @example
         * let x0 = clampX(-12_000.0) // -1
         */
        @inline(__always) func clampX(_ v: Double) -> Int32 { Int32(min(max(v, -1), viewW + 1)) }

        /**
         * Clamps a vertical coordinate to just outside the view.
         *
         * @param {Double} v - Vertical pixel coordinate.
         * @returns {Int32} The coordinate limited to -1…height+1.
         *
         * @example
         * let y1 = clampY(9_999_999.0) // height + 1
         */
        @inline(__always) func clampY(_ v: Double) -> Int32 { Int32(min(max(v, -1), viewH + 1)) }

        /**
         * Adds an item for `node` covering (x, y, w, h) and recurses into it.
         *
         * Coordinates are view pixels and may lie far outside the view when
         * zoomed. Rectangles are snapped to whole pixels; empty ones and ones
         * entirely outside the view are skipped, since there is nothing to draw
         * or hit-test there. The cushion ridge uses the true, unclamped extent so
         * shading stays continuous while zooming. Directories large enough are
         * subdivided; smaller ones, and files, become a single shaded leaf. The
         * depth cap stops pathological single-child chains from exhausting the
         * stack. Checks for cancellation every 1024 items.
         *
         * @param {Node} node - The file or directory to place.
         * @param {Double} x - Left edge in view pixels.
         * @param {Double} y - Top edge in view pixels.
         * @param {Double} w - Width in pixels.
         * @param {Double} h - Height in pixels.
         * @param {Int32} parent - Index of the parent item, or -1 for the root.
         * @param {inout Int32} lastSibling - The parent's last child so far; updated to link the new item.
         * @param {(Double, Double, Double, Double)} surface - Cushion coefficients inherited from the parent.
         * @param {Double} height - Ridge height for this level.
         * @param {Int} depth - Nesting level below the root.
         *
         * @example
         * var last: Int32 = -1
         * builder.place(root, x: 0, y: 0, w: 2400, h: 800, parent: -1, lastSibling: &last,
         *               surface: (0, 0, 0, 0), height: 0.4, depth: 0)
         */
        func place(_ node: Node, x: Double, y: Double, w: Double, h: Double,
                   parent: Int32, lastSibling: inout Int32,
                   surface: (Double, Double, Double, Double), height: Double, depth: Int) {
            let fx0 = x.rounded(), fy0 = y.rounded()
            let fx1 = (x + w).rounded(), fy1 = (y + h).rounded()
            guard fx1 > fx0, fy1 > fy0 else { return }
            guard fx1 > 0, fy1 > 0, fx0 < viewW, fy0 < viewH else { return }

            let index = Int32(layout.items.count)
            layout.items.append(TreemapLayout.Item(node: node, x0: clampX(fx0), y0: clampY(fy0),
                                                   x1: clampX(fx1), y1: clampY(fy1)))
            if parent >= 0 {
                if lastSibling >= 0 {
                    layout.items[Int(lastSibling)].nextSibling = index
                } else {
                    layout.items[Int(parent)].firstChild = index
                }
                lastSibling = index
            }

            var s = surface
            addRidge(fx0, fx1, fy0, fy1, &s, height)

            let pw = fx1 - fx0, ph = fy1 - fy0
            if node.isDir, pw >= TreemapRenderer.minDirSide, ph >= TreemapRenderer.minDirSide,
               !node.children.isEmpty, metric(node) > 0, depth < TreemapRenderer.maxDepth {
                if (index & 0x3FF) == 0 && isCancelled() { cancelled = true; return }
                layoutChildren(of: node, x: fx0, y: fy0, w: pw, h: ph, index: index,
                               surface: s, height: height * TreemapRenderer.scaleFactor, depth: depth + 1)
            } else if node.isDir && metric(node) <= 0 {
                return
            } else {
                addLeaf(fx0, fy0, fx1, fy1, s, color(for: node))
            }
        }

        /**
         * Subdivides a directory's rectangle among its children.
         *
         * Zero-size children at the end of the (sorted) list are ignored. When
         * the remaining children would be sub-pixel, their space is drawn as one
         * block coloured like the first of them.
         *
         * @param {Node} node - The directory being subdivided.
         * @param {Double} x - Left edge in view pixels.
         * @param {Double} y - Top edge in view pixels.
         * @param {Double} w - Width in pixels.
         * @param {Double} h - Height in pixels.
         * @param {Int32} index - The directory's item index, parent of the new items.
         * @param {(Double, Double, Double, Double)} surface - The directory's cushion coefficients.
         * @param {Double} height - Ridge height for the children's level.
         * @param {Int} depth - Nesting level of the children.
         *
         * @example
         * layoutChildren(of: dir, x: 0, y: 0, w: 800, h: 600, index: 0,
         *                surface: s, height: 0.36, depth: 1)
         */
        func layoutChildren(of node: Node, x: Double, y: Double, w: Double, h: Double, index: Int32,
                            surface: (Double, Double, Double, Double), height: Double, depth: Int) {
            let kids = node.children
            var n = kids.count
            while n > 0 && metric(kids[n - 1]) <= 0 { n -= 1 }
            guard n > 0 else { return }
            var lastSibling: Int32 = -1
            TreemapRenderer.squarify(kids, n, metric: metric, x: x, y: y, w: w, h: h,
                                     minArea: TreemapRenderer.minArea, shouldStop: { self.cancelled },
                                     place: { k, cx, cy, cw, ch in
                self.place(kids[k], x: cx, y: cy, w: cw, h: ch, parent: index,
                           lastSibling: &lastSibling, surface: surface, height: height, depth: depth)
            }, rest: { k, rx, ry, rw, rh in
                let fx0 = rx.rounded(), fy0 = ry.rounded(), fx1 = (rx + rw).rounded(), fy1 = (ry + rh).rounded()
                guard fx1 > fx0, fy1 > fy0 else { return }
                var s = surface
                self.addRidge(fx0, fx1, fy0, fy1, &s, height)
                self.addLeaf(fx0, fy0, fx1, fy1, s, self.color(for: kids[k]))
            })
        }

        /**
         * Records the visible part of a cushion for shading.
         *
         * The rectangle is clipped to the view; nothing is recorded when no pixel
         * of it is visible. The surface coefficients still describe the full,
         * unclipped cushion.
         *
         * @param {Double} fx0 - Left edge in view pixels.
         * @param {Double} fy0 - Top edge in view pixels.
         * @param {Double} fx1 - Right edge in view pixels.
         * @param {Double} fy1 - Bottom edge in view pixels.
         * @param {(Double, Double, Double, Double)} s - Cushion surface coefficients.
         * @param {RGB} color - Base colour.
         *
         * @example
         * addLeaf(0, 0, 40, 30, surface, RGB.gray)
         */
        func addLeaf(_ fx0: Double, _ fy0: Double, _ fx1: Double, _ fy1: Double,
                     _ s: (Double, Double, Double, Double), _ color: RGB) {
            let x0 = Int32(max(fx0, 0)), y0 = Int32(max(fy0, 0))
            let x1 = Int32(min(fx1, viewW)), y1 = Int32(min(fy1, viewH))
            guard x1 > x0, y1 > y0 else { return }
            leaves.append(Leaf(x0: x0, y0: y0, x1: x1, y1: y1, s0: s.0, s1: s.1, s2: s.2, s3: s.3, color: color))
        }

        /**
         * Adds one level's parabolic ridge to a cushion surface.
         *
         * Each nesting level contributes a ridge spanning its rectangle in both
         * directions (van Wijk & van de Wetering), which gives nested cushions
         * their layered look.
         *
         * @param {Double} x0 - Left edge.
         * @param {Double} x1 - Right edge.
         * @param {Double} y0 - Top edge.
         * @param {Double} y1 - Bottom edge.
         * @param {inout (Double, Double, Double, Double)} s - Surface coefficients to update.
         * @param {Double} h - Ridge height for this level.
         *
         * @example
         * var s = (0.0, 0.0, 0.0, 0.0)
         * addRidge(0, 800, 0, 600, &s, 0.4)
         */
        @inline(__always)
        func addRidge(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double,
                      _ s: inout (Double, Double, Double, Double), _ h: Double) {
            let h4 = 4 * h
            let wf = h4 / (x1 - x0)
            s.2 += wf * (x1 + x0)
            s.0 -= wf
            let hf = h4 / (y1 - y0)
            s.3 += hf * (y1 + y0)
            s.1 -= hf
        }
    }

    /**
     * Lays out and shades `root` into a picture.
     *
     * Layout reads the tree under `treeLock`; shading then runs in parallel over
     * chunks of leaves, which cover disjoint pixels. Pixels no leaf covers keep
     * the dark background. Safe to call off the main thread.
     *
     * @param {Node} root - The directory to show as the whole treemap.
     * @param {Params} params - Output size, viewport, colours and size mode.
     * @param {() -> Bool} isCancelled - Polled during layout; true abandons the render.
     * @returns {(CGImage?, TreemapLayout)?} The picture and its layout, or nil when cancelled or the size is empty.
     *
     * @example
     * if let (image, layout) = TreemapRenderer.render(root: root, params: params, isCancelled: { false }) {
     *     show(image, layout)
     * }
     */
    static func render(root: Node, params: Params, isCancelled: @escaping () -> Bool) -> (CGImage?, TreemapLayout)? {
        guard params.width > 0, params.height > 0 else { return nil }
        let builder = Builder(params: params, isCancelled: isCancelled)
        treeLock.lock()
        var last: Int32 = -1
        builder.place(root, x: -params.offsetX, y: -params.offsetY,
                      w: Double(params.width) * params.scale, h: Double(params.height) * params.scale,
                      parent: -1, lastSibling: &last, surface: (0, 0, 0, 0), height: initialHeight, depth: 0)
        treeLock.unlock()
        if builder.cancelled || isCancelled() { return nil }
        builder.layout.computeFocus()

        let width = params.width, height = params.height
        let pixelCount = width * height
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
        pixels.initialize(repeating: 0xFF1C1C1E, count: pixelCount)

        let leaves = builder.leaves
        let chunk = 256
        let chunks = (leaves.count + chunk - 1) / chunk
        leaves.withUnsafeBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: max(chunks, 1)) { c in
                let lo = c * chunk, hi = min(buf.count, lo + chunk)
                guard lo < hi else { return }
                for li in lo..<hi { shade(buf[li], pixels, width) }
            }
        }

        let data = Data(bytesNoCopy: pixels, count: pixelCount * 4, deallocator: .custom { p, _ in
            p.deallocate()
        })
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: info, provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)
        return (image, builder.layout)
    }

    /**
     * Computes where a node sits when `root` fills a `width × height` area at zoom 1.
     *
     * Pure geometry in the caller's units, ignoring the minimum-size cut-offs
     * and pixel snapping, so it can locate nodes too small to be drawn. Reads
     * `children` without taking `treeLock`; call it on the main thread, where
     * all tree mutations happen.
     *
     * @param {Node} node - The node to locate.
     * @param {Node} root - The directory filling the area.
     * @param {Double} width - Area width.
     * @param {Double} height - Area height.
     * @param {SizeMode} mode - The size that determines areas.
     * @returns {CGRect?} The node's rectangle, or nil if it is not under `root` or has no area.
     *
     * @example
     * let r = TreemapRenderer.rect(of: file, in: root, width: 800, height: 400, mode: .allocated)
     */
    static func rect(of node: Node, in root: Node, width: Double, height: Double, mode: SizeMode) -> CGRect? {
        var chain: [Node] = []
        var n: Node? = node
        while let c = n, c !== root {
            chain.append(c)
            n = c.parent
        }
        guard n === root else { return nil }
        let metric: (Node) -> Double = { Double(mode == .allocated ? $0.alloc : $0.size) }
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        var parent = root
        for target in chain.reversed() {
            let kids = parent.children
            var count = kids.count
            while count > 0 && metric(kids[count - 1]) <= 0 { count -= 1 }
            var found: CGRect?
            squarify(kids, count, metric: metric, x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                     minArea: 0, shouldStop: { found != nil }, place: { k, x, y, w, h in
                if kids[k] === target { found = CGRect(x: x, y: y, width: w, height: h) }
            }, rest: { _, _, _, _, _ in })
            guard let found else { return nil }
            rect = found
            parent = target
        }
        return rect
    }

    /**
     * Shades one cushion into the pixel buffer.
     *
     * For each pixel, derives the cushion's surface normal from the leaf's
     * coefficients, lights it with ambient plus diffuse light from `light`,
     * and writes the resulting BGRA colour. Leaves never overlap, so several
     * threads can shade different leaves into the same buffer at once.
     *
     * @param {Leaf} leaf - The cushion to shade; bounds already clipped to the buffer.
     * @param {UnsafeMutablePointer<UInt32>} pixels - The picture, one 32-bit pixel per entry.
     * @param {Int} width - Buffer width in pixels (the row stride).
     *
     * @example
     * for leaf in leaves { shade(leaf, pixels, width) }
     */
    @inline(__always)
    private static func shade(_ leaf: Leaf, _ pixels: UnsafeMutablePointer<UInt32>, _ width: Int) {
        let lx = light.x, ly = light.y, lz = light.z
        let isf = 1 - ambient
        let cr = leaf.color.r * brightness, cg = leaf.color.g * brightness, cb = leaf.color.b * brightness
        for iy in Int(leaf.y0)..<Int(leaf.y1) {
            let ny = -(2 * leaf.s1 * (Double(iy) + 0.5) + leaf.s3)
            let nyl = ny * ly + lz
            let ny2 = ny * ny + 1
            let row = pixels + iy * width
            for ix in Int(leaf.x0)..<Int(leaf.x1) {
                let nx = -(2 * leaf.s0 * (Double(ix) + 0.5) + leaf.s2)
                var cosa = (nx * lx + nyl) / (nx * nx + ny2).squareRoot()
                if cosa > 1 { cosa = 1 }
                var p = isf * Float(cosa)
                if p < 0 { p = 0 }
                p += ambient
                let r = min(255, max(0, Int(cr * p * 255)))
                let g = min(255, max(0, Int(cg * p * 255)))
                let b = min(255, max(0, Int(cb * p * 255)))
                row[ix] = 0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            }
        }
    }
}
