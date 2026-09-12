import Foundation
import os

/**
 * Interns lowercase file extensions into small integer ids shared by the whole app.
 *
 * Id 0 means "no extension". Scanner threads intern concurrently, so every
 * access goes through an unfair lock.
 */
final class ExtensionTable: @unchecked Sendable {
    /** The app-wide table; ids stay valid for the life of the process. */
    static let shared = ExtensionTable()

    /** Lock-protected storage: id → name and name → id. */
    private struct State {
        /** Extension names indexed by id; index 0 is the empty name. */
        var names: [String] = [""]
        /** Reverse lookup from name to id. */
        var ids: [String: UInt16] = ["": 0]
    }

    /** The table contents, guarded by an unfair lock. */
    private let state = OSAllocatedUnfairLock(initialState: State())

    /**
     * Returns the id for an extension, assigning a new one on first sight.
     *
     * Thread-safe. Once all 65,535 ids are taken, new extensions map to 0
     * ("no extension") instead of failing.
     *
     * @param {String} ext - Lowercase extension without the dot, or "" for none.
     * @returns {UInt16} The extension's id.
     *
     * @example
     * let movID = ExtensionTable.shared.intern("mov")
     */
    func intern(_ ext: String) -> UInt16 {
        state.withLock { s in
            if let id = s.ids[ext] { return id }
            guard s.names.count < Int(UInt16.max) else { return 0 }
            let id = UInt16(s.names.count)
            s.names.append(ext)
            s.ids[ext] = id
            return id
        }
    }

    /**
     * Looks up the extension name for an id.
     *
     * Thread-safe. Unknown ids yield an empty string rather than trapping.
     *
     * @param {UInt16} id - An id previously returned by `intern(_:)`.
     * @returns {String} The lowercase extension without the dot, or "" for id 0 or unknown ids.
     *
     * @example
     * ExtensionTable.shared.name(node.ext) // "mov"
     */
    func name(_ id: UInt16) -> String {
        state.withLock { s in Int(id) < s.names.count ? s.names[Int(id)] : "" }
    }

    /** Number of ids handed out so far, including id 0. */
    var count: Int { state.withLock { $0.names.count } }

    /**
     * Returns a snapshot of every known extension name.
     *
     * The array index is the extension id, so it can size per-extension
     * accumulators. Extensions interned later are not included.
     *
     * @returns {[String]} Names indexed by id; element 0 is "".
     *
     * @example
     * let names = ExtensionTable.shared.allNames()
     * var totals = [Int64](repeating: 0, count: names.count)
     */
    func allNames() -> [String] { state.withLock { $0.names } }
}

/** Aggregated statistics for one extension. */
struct ExtStat {
    /** Extension id from `ExtensionTable`. */
    let id: UInt16
    /** Lowercase extension without the dot; "" for files without one. */
    let name: String
    /** Total logical size of the files with this extension. */
    var size: Int64 = 0
    /** Total allocated size of the files with this extension. */
    var alloc: Int64 = 0
    /** Number of files with this extension. */
    var count: Int = 0

    /** Label for the file-type list: ".ext", or the localised "no extension" text. */
    var displayName: String { name.isEmpty ? L.noExtension : "." + name }

    /**
     * Returns the total for the chosen size mode.
     *
     * @param {SizeMode} mode - Logical or allocated size.
     * @returns {Int64} The matching total in bytes.
     *
     * @example
     * let bytes = stat.metric(.allocated)
     */
    func metric(_ mode: SizeMode) -> Int64 { mode == .allocated ? alloc : size }
}

/** Builds per-extension totals from a scanned tree. */
enum ExtStats {
    /**
     * Walks every file under `root` and tallies per-extension totals.
     *
     * Iterative, so deep trees cannot overflow the stack. If `root` is a file,
     * the result covers just that file. Extensions with no files are left out.
     * Reads `children`, so run it on the main thread or under `treeLock`.
     *
     * @param {Node} root - The directory (or single file) to tally.
     * @returns {[ExtStat]} One entry per extension that has at least one file, in id order.
     *
     * @example
     * let stats = ExtStats.compute(root: result.root)
     * let biggest = stats.max { $0.alloc < $1.alloc }
     */
    static func compute(root: Node) -> [ExtStat] {
        let names = ExtensionTable.shared.allNames()
        var size = [Int64](repeating: 0, count: names.count)
        var alloc = [Int64](repeating: 0, count: names.count)
        var count = [Int](repeating: 0, count: names.count)
        var stack: [Node] = [root]
        if !root.isDir {
            stack = []
            let e = Int(root.ext)
            size[e] += root.size; alloc[e] += root.alloc; count[e] += 1
        }
        while let n = stack.popLast() {
            for c in n.children {
                if c.isDir {
                    stack.append(c)
                } else {
                    let e = Int(c.ext)
                    size[e] &+= c.size
                    alloc[e] &+= c.alloc
                    count[e] &+= 1
                }
            }
        }
        var result: [ExtStat] = []
        for i in 0..<names.count where count[i] > 0 {
            result.append(ExtStat(id: UInt16(i), name: names[i], size: size[i], alloc: alloc[i], count: count[i]))
        }
        return result
    }
}
