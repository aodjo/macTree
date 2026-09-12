import AppKit

/** An sRGB colour with float components in 0…1, cheap to use in the treemap's pixel loop. */
struct RGB {
    /** Red component, 0…1. */
    var r: Float
    /** Green component, 0…1. */
    var g: Float
    /** Blue component, 0…1. */
    var b: Float

    /**
     * Creates a colour from its three components.
     *
     * Values are stored as given; nothing is clamped, so callers that scale
     * a colour (for example to brighten a cushion) clamp later when writing pixels.
     *
     * @param {Float} r - Red component, 0…1.
     * @param {Float} g - Green component, 0…1.
     * @param {Float} b - Blue component, 0…1.
     *
     * @example
     * let grey = RGB(0.5, 0.5, 0.5)
     */
    init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }

    /**
     * Creates a colour from a 24-bit `0xRRGGBB` value.
     *
     * The top byte is ignored, so an alpha channel in the value has no effect.
     *
     * @param {UInt32} hex - The colour as `0xRRGGBB`.
     *
     * @example
     * let blue = RGB(hex: 0x3D7EFF)
     */
    init(hex: UInt32) {
        r = Float((hex >> 16) & 0xFF) / 255
        g = Float((hex >> 8) & 0xFF) / 255
        b = Float(hex & 0xFF) / 255
    }

    /** The same colour as an opaque sRGB `NSColor`, for swatches and bars. */
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }

    /** Neutral grey used for files without an extension. */
    static let gray = RGB(0.62, 0.62, 0.64)
}

/**
 * Colour assignment per file extension, shared by the treemap and the file-type list.
 *
 * The biggest types get distinct palette colours; the long tail gets stable,
 * hash-derived muted colours so an extension keeps its colour across scans.
 */
final class ExtColors {
    /** Vivid colours handed to the largest extensions, biggest first. */
    private static let palette: [UInt32] = [
        0x3D7EFF, 0xF0453A, 0x2FC25B, 0xF7C325, 0xA35CF5, 0x16C2D5,
        0xFF8A1F, 0xF0509B, 0x8CCB1E, 0x1FB39B, 0x6567F2, 0xE9A10C,
        0x5AB0FF, 0xFF6F61, 0x62DE8B, 0xFFE066, 0xC792F9, 0x6DE0EC,
        0xFFB066, 0xF78DC1, 0xB5E061, 0x5FD6C1, 0x9B9DF7, 0xD9C27A,
    ]

    /** Colour per extension id, dense over the ids known when the table was built. */
    private var colors: [RGB]

    /**
     * Builds the colour table for one scan.
     *
     * Every extension known to `ExtensionTable` first gets its hashed colour;
     * id 0 (no extension) becomes grey; then the extensions ranked largest by
     * `mode` take the palette colours in order. Extensions interned after this
     * point fall back to their hashed colour in `color(_:)`.
     *
     * @param {[ExtStat]} stats - Per-extension totals of the scan.
     * @param {SizeMode} mode - The size used to rank extensions.
     *
     * @example
     * let colors = ExtColors(stats: result.extStats, mode: .allocated)
     */
    init(stats: [ExtStat], mode: SizeMode) {
        let count = max(ExtensionTable.shared.count, 1)
        colors = (0..<count).map { ExtColors.hashed(UInt16($0)) }
        colors[0] = RGB.gray
        let ranked = stats.filter { $0.id != 0 }.sorted { $0.metric(mode) > $1.metric(mode) }
        for (i, s) in ranked.prefix(ExtColors.palette.count).enumerated() {
            colors[Int(s.id)] = RGB(hex: ExtColors.palette[i])
        }
    }

    /**
     * Returns the colour for an extension id.
     *
     * Ids outside the table (extensions first seen after it was built, e.g.
     * by a folder rescan) get their stable hashed colour instead of failing.
     *
     * @param {UInt16} ext - Extension id from `ExtensionTable`.
     * @returns {RGB} The colour used to paint files of that type.
     *
     * @example
     * let c = colors.color(node.ext)
     */
    @inline(__always) func color(_ ext: UInt16) -> RGB {
        Int(ext) < colors.count ? colors[Int(ext)] : ExtColors.hashed(ext)
    }

    /**
     * Returns the colour for an extension id as an `NSColor`.
     *
     * Convenience for AppKit drawing such as the swatches in the file-type list.
     *
     * @param {UInt16} ext - Extension id from `ExtensionTable`.
     * @returns {NSColor} The opaque sRGB colour for that type.
     *
     * @example
     * cell.color = colors.nsColor(stat.id)
     */
    func nsColor(_ ext: UInt16) -> NSColor { color(ext).nsColor }

    /**
     * Derives a muted colour from an extension id.
     *
     * Uses a multiplicative hash to spread neighbouring ids around the hue
     * circle, with fixed saturation and brightness so long-tail types stay
     * calmer than palette colours. Deterministic for a given id.
     *
     * @param {UInt16} ext - Extension id.
     * @returns {RGB} The hashed sRGB colour.
     *
     * @example
     * let fallback = ExtColors.hashed(4711)
     */
    private static func hashed(_ ext: UInt16) -> RGB {
        var h = UInt32(ext) &* 2_654_435_761
        h ^= h >> 15
        let hue = CGFloat(h % 360) / 360
        let c = NSColor(hue: hue, saturation: 0.42, brightness: 0.78, alpha: 1).usingColorSpace(.sRGB)!
        return RGB(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }
}
