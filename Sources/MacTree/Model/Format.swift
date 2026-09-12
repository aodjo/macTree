import Foundation

/**
 * Text formatting for sizes, counts, dates and durations shown in the UI.
 *
 * The cached formatters are not thread-safe; call these from the main thread.
 */
enum Fmt {
    /** Size unit suffixes, one per power of 1000. */
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /**
     * Formats a byte count with decimal (1000-based) units, matching Finder.
     *
     * Values under 1000 are shown as whole bytes. Larger values get one
     * decimal place below 100 of their unit and none from 100 up, so labels
     * stay short in narrow table columns.
     *
     * @param {Int64} value - Size in bytes.
     * @returns {String} A label such as "512 B", "12.3 GB" or "384 GB".
     *
     * @example
     * Fmt.bytes(12_345_678_901) // "12.3 GB"
     */
    static func bytes(_ value: Int64) -> String {
        if value < 1000 { return "\(value) B" }
        var v = Double(value)
        var u = 0
        while v >= 1000 && u < units.count - 1 {
            v /= 1000
            u += 1
        }
        return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[u])
    }

    /** Locale-aware integer formatter with grouping separators. */
    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    /**
     * Formats an item count with the locale's grouping separators.
     *
     * Falls back to the plain number if the formatter fails.
     *
     * @param {Int} n - The count to format.
     * @returns {String} A label such as "1,234,567".
     *
     * @example
     * Fmt.count(1_076_094) // "1,076,094"
     */
    static func count(_ n: Int) -> String {
        countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /** Short date and time formatter in the user's locale. */
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /**
     * Formats a modification date as a short date and time.
     *
     * Unknown dates produce an empty string so table cells stay blank.
     *
     * @param {Date?} d - The date, or nil when unknown.
     * @returns {String} The localised date and time, or "" for nil.
     *
     * @example
     * Fmt.date(node.modificationDate) // "2026. 9. 12. 오전 8:15"
     */
    static func date(_ d: Date?) -> String {
        guard let d else { return "" }
        return dateFormatter.string(from: d)
    }

    /**
     * Formats a fraction as a percentage with one decimal place.
     *
     * Non-finite input (such as 0/0 for an empty parent) yields an empty string.
     *
     * @param {Double} fraction - Value where 1.0 means 100 %.
     * @returns {String} A label such as "35.1 %", or "" when not finite.
     *
     * @example
     * Fmt.percent(0.351) // "35.1 %"
     */
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "" }
        return String(format: "%.1f %%", fraction * 100)
    }

    /**
     * Formats a duration in seconds with two decimal places.
     *
     * @param {TimeInterval} t - Duration in seconds.
     * @returns {String} A label such as "2.84 s".
     *
     * @example
     * Fmt.seconds(result.elapsed) // "24.71 s"
     */
    static func seconds(_ t: TimeInterval) -> String {
        String(format: "%.2f s", t)
    }
}
