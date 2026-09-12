import Foundation

/**
 * One file or directory in the scanned tree.
 *
 * Kept deliberately small because a full-disk scan can produce millions of
 * these. Directories hold aggregate values for their whole subtree once the
 * scanner has finalised the tree.
 */
final class Node {
    /** Per-node state bits, packed into one byte. */
    struct Flags: OptionSet {
        /** The packed bit field. */
        let rawValue: UInt8

        /** The node is a directory. */
        static let dir = Flags(rawValue: 1 << 0)
        /** Directory contents could not be read (permissions or privacy protection). */
        static let denied = Flags(rawValue: 1 << 1)
        /** The node is a symbolic link; it is never followed. */
        static let symlink = Flags(rawValue: 1 << 2)
        /** Mount point of another volume that was not traversed. */
        static let otherVolume = Flags(rawValue: 1 << 3)
        /** iCloud / File Provider placeholder whose data is not on disk. */
        static let dataless = Flags(rawValue: 1 << 4)
        /** A directory whose aggregate values include unreadable content somewhere below. */
        static let partial = Flags(rawValue: 1 << 5)
    }

    /** File name; for the scan root, the full path that was scanned. */
    var name: String
    /** Containing directory, or nil for the scan root. */
    weak var parent: Node?
    /** Entries of a directory, largest first by the current size mode. */
    var children: [Node] = []
    /** Logical size (all forks). For directories: sum of the subtree. */
    var size: Int64
    /** Allocated size on disk. For directories: sum of the subtree. */
    var alloc: Int64
    /** Modification time (seconds since 1970). For directories: newest in the subtree. */
    var mtime: UInt32
    /** Files in the subtree (1 for a file). */
    var fileCount: Int32
    /** Directories in the subtree, not counting self. */
    var dirCount: Int32
    /** Index into `ExtensionTable` (files only). */
    var ext: UInt16
    /** State bits such as directory, denied or symlink. */
    var flags: Flags

    /**
     * Creates a node for one directory entry.
     *
     * A file starts with a file count of 1; a directory starts empty and gets
     * its totals from `recomputeFromChildren()` once its children are known.
     *
     * @param {String} name - Entry name (or full path for a scan root).
     * @param {Bool} isDir - Whether the entry is a directory.
     * @param {Int64} [size=0] - Logical size in bytes.
     * @param {Int64} [alloc=0] - Allocated size in bytes.
     * @param {UInt32} [mtime=0] - Modification time in seconds since 1970, 0 if unknown.
     * @param {UInt16} [ext=0] - Extension id from `ExtensionTable`, 0 for none.
     *
     * @example
     * let file = Node(name: "movie.mov", isDir: false, size: 1_000_000, alloc: 1_003_520, ext: movID)
     * file.fileCount // 1
     */
    init(name: String, isDir: Bool, size: Int64 = 0, alloc: Int64 = 0, mtime: UInt32 = 0, ext: UInt16 = 0) {
        self.name = name
        self.size = size
        self.alloc = alloc
        self.mtime = mtime
        self.fileCount = isDir ? 0 : 1
        self.dirCount = 0
        self.ext = ext
        self.flags = isDir ? .dir : []
    }

    /** Whether the node is a directory. */
    @inline(__always) var isDir: Bool { flags.contains(.dir) }

    /** Files plus directories in the subtree. */
    var itemCount: Int { Int(fileCount) + Int(dirCount) }

    /**
     * Returns the size used for percentages, the treemap and default ordering.
     *
     * Logical size counts sparse files and iCloud placeholders at full length;
     * allocated size is what the node really occupies on disk.
     *
     * @param {SizeMode} mode - Which size to report.
     * @returns {Int64} The logical or allocated size in bytes.
     *
     * @example
     * let bytes = node.metric(.allocated)
     */
    @inline(__always) func metric(_ mode: SizeMode) -> Int64 {
        mode == .allocated ? alloc : size
    }

    /** Absolute path, rebuilt from the parent chain on each access. */
    var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /** File URL for `path`. */
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDir) }

    /** Parents from the immediate one up to the scan root. */
    var ancestors: [Node] {
        var result: [Node] = []
        var n = parent
        while let p = n { result.append(p); n = p.parent }
        return result
    }

    /**
     * Tells whether this node lies inside `other`'s subtree.
     *
     * A node counts as its own descendant. Walks the parent chain, so a node
     * detached from the tree still reports its former ancestors.
     *
     * @param {Node} other - The candidate ancestor.
     * @returns {Bool} True if `other` is this node or one of its ancestors.
     *
     * @example
     * file.isDescendant(of: scanRoot) // true
     */
    func isDescendant(of other: Node) -> Bool {
        var n: Node? = self
        while let c = n {
            if c === other { return true }
            n = c.parent
        }
        return false
    }

    /** `mtime` as a date, or nil when unknown. */
    var modificationDate: Date? {
        mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime))
    }
}

/** Which size drives percentages, ordering and the treemap. */
enum SizeMode: Int {
    /** Logical file length. */
    case logical = 0
    /** Bytes allocated on disk. */
    case allocated = 1
}

extension Node {
    /**
     * Recomputes this directory's aggregate values from its immediate children.
     *
     * Sums sizes and counts, takes the newest modification time, and sets the
     * `partial` flag when anything below could not be read. Children must
     * already be up to date, so callers process directories bottom-up. Does
     * nothing for files.
     *
     * @example
     * for dir in directoriesBottomUp { dir.recomputeFromChildren() }
     */
    func recomputeFromChildren() {
        guard isDir else { return }
        var s: Int64 = 0, a: Int64 = 0, f: Int32 = 0, d: Int32 = 0
        var m: UInt32 = 0
        var partial = flags.contains(.denied)
        for c in children {
            s &+= c.size
            a &+= c.alloc
            f &+= c.fileCount
            if c.isDir { d &+= c.dirCount &+ 1 }
            if c.mtime > m { m = c.mtime }
            if c.flags.contains(.partial) || c.flags.contains(.denied) { partial = true }
        }
        size = s; alloc = a; fileCount = f; dirCount = d
        if m > 0 { mtime = m }
        if partial { flags.insert(.partial) } else { flags.remove(.partial) }
    }

    /**
     * Orders the children largest first.
     *
     * Ties on the chosen size are broken by the other size. Mutates `children`
     * in place, so it must not run while a background reader walks the tree.
     *
     * @param {SizeMode} mode - The size to order by.
     *
     * @example
     * treeLock.lock(); dir.sortChildren(by: .allocated); treeLock.unlock()
     */
    func sortChildren(by mode: SizeMode) {
        if mode == .allocated {
            children.sort { $0.alloc != $1.alloc ? $0.alloc > $1.alloc : $0.size > $1.size }
        } else {
            children.sort { $0.size != $1.size ? $0.size > $1.size : $0.alloc > $1.alloc }
        }
    }

    /** The file reached by following the largest child down; colours directories too small to subdivide. */
    var dominantFile: Node? {
        var n = self
        while n.isDir {
            guard let first = n.children.first else { return nil }
            n = first
        }
        return n
    }
}
