/**
 * Renders the MacTree app icon into an .iconset directory.
 *
 * Usage: `swift scripts/make-icon.swift <out.iconset>`, then
 * `iconutil -c icns <out.iconset>`. build-app.sh does both.
 */
import AppKit

/** Destination .iconset directory; defaults to "AppIcon.iconset" in the current directory. */
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/** A coloured rectangle of the icon's treemap: its bounds and base colour before the cushion gradient. */
struct Tile { var rect: CGRect; var color: NSColor }

/**
 * Minimal squarified treemap layout for the icon tiles.
 *
 * Same row-building rule as the app's renderer: keep adding items to the
 * current row along the shorter side while the worst aspect ratio improves,
 * then start a new row in the remaining space.
 *
 * @param {[Double]} weights - Tile weights, largest first.
 * @param {CGRect} rect - Area to fill.
 * @returns {[CGRect]} One rectangle per weight, in the same order.
 *
 * @example
 * let rects = squarify([34, 20, 14], in: CGRect(x: 0, y: 0, width: 100, height: 100))
 */
func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
    var result: [CGRect] = []
    var r = rect
    var items = weights
    var total = items.reduce(0, +)
    while !items.isEmpty {
        let vertical = r.width >= r.height
        let side = vertical ? r.height : r.width
        let scale = (r.width * r.height) / total
        var row: [Double] = []
        var worst = Double.infinity
        for w in items {
            let candidate = row + [w]
            let sum = candidate.reduce(0, +) * scale
            let t = sum / side
            let maxA = candidate.max()! * scale, minA = candidate.min()! * scale
            let wr = max(t * t / minA, maxA / (t * t))
            if !row.isEmpty && wr > worst { break }
            row = candidate
            worst = wr
        }
        let rowSum = row.reduce(0, +)
        let t = rowSum * scale / side
        var offset = 0.0
        for w in row {
            let len = w * scale / t
            result.append(vertical ? CGRect(x: r.minX, y: r.minY + offset, width: t, height: len)
                                   : CGRect(x: r.minX + offset, y: r.minY, width: len, height: t))
            offset += len
        }
        if vertical { r = CGRect(x: r.minX + t, y: r.minY, width: r.width - t, height: r.height) }
        else { r = CGRect(x: r.minX, y: r.minY + t, width: r.width, height: r.height - t) }
        items.removeFirst(row.count)
        total -= rowSum
    }
    return result
}

/**
 * Makes an sRGB colour from a `0xRRGGBB` value.
 *
 * @param {UInt32} v - The colour as `0xRRGGBB`.
 * @returns {NSColor} The opaque colour.
 *
 * @example
 * let blue = hex(0x3D7EFF)
 */
func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/**
 * Draws the icon at one pixel size.
 *
 * Follows the standard macOS icon grid (an 824-point rounded body with a
 * 100-point margin on a 1024 canvas, scaled to `size`). It draws a drop
 * shadow and a dark gradient body. Squarified tiles in the app's palette get
 * a radial "cushion" gradient: bright toward the upper left, darker at the
 * rim. A soft gloss covers the upper half.
 *
 * @param {Int} size - Width and height in pixels.
 * @returns {NSBitmapImageRep} The rendered bitmap.
 *
 * @example
 * let png = render(size: 512).representation(using: .png, properties: [:])
 */
func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let s = CGFloat(size) / 1024

    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s,
                 color: NSColor.black.withAlphaComponent(0.35).cgColor)
    hex(0x15171C).setFill()
    shape.fill()
    cg.restoreGState()

    shape.addClip()
    let bg = NSGradient(colors: [hex(0x2A2E38), hex(0x121419)])!
    bg.draw(in: shape, angle: -90)

    let inner = body.insetBy(dx: 70 * s, dy: 70 * s)
    let weights: [Double] = [34, 20, 14, 10, 8, 6, 4, 3, 1]
    let palette: [UInt32] = [0x3D7EFF, 0xF0453A, 0x2FC25B, 0xF7C325, 0xA35CF5, 0x16C2D5, 0xFF8A1F, 0xF0509B, 0x8CCB1E]
    let gap = max(1, 10 * s)
    for (i, r) in squarify(weights, in: inner).enumerated() {
        let tile = r.insetBy(dx: gap / 2, dy: gap / 2)
        let path = NSBezierPath(roundedRect: tile, xRadius: 14 * s, yRadius: 14 * s)
        let base = hex(palette[i % palette.count])
        cg.saveGState()
        path.addClip()
        let light = base.blended(withFraction: 0.55, of: .white)!
        let dark = base.blended(withFraction: 0.45, of: .black)!
        let g = NSGradient(colors: [light, base, dark], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        let center = NSPoint(x: tile.midX - tile.width * 0.18, y: tile.midY + tile.height * 0.18)
        g.draw(fromCenter: center, radius: 0, toCenter: NSPoint(x: tile.midX, y: tile.midY),
               radius: max(tile.width, tile.height) * 0.78, options: [.drawsAfterEndingLocation])
        cg.restoreGState()
    }

    let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    gloss.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/** File names and pixel sizes that iconutil expects in an .iconset. */
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let data = render(size: px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(outDir)")
