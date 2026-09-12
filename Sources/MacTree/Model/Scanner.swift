import Foundation
import Darwin
import Synchronization
import os

/** A folder the scan could not list, with the errno that stopped it. */
struct DeniedFolder {
    /** Absolute path of the folder. */
    let path: String
    /** The errno from `open` or `getattrlistbulk`. */
    let error: Int32

    /**
     * Whether macOS privacy protection (TCC) or SIP refused access.
     *
     * EPERM comes from privacy protection or SIP and may clear with Full Disk
     * Access; EACCES comes from plain Unix permissions, typically root-only
     * system folders.
     */
    var isPrivacyProtected: Bool { error == EPERM }
}

/** Result of a completed (or cancelled) scan. */
final class ScanResult {
    /** Root of the scanned tree, finalised and sorted. */
    let root: Node
    /** The resolved absolute path that was scanned. */
    let rootPath: String
    /** Per-extension totals; kept in step when the tree is edited. */
    var extStats: [ExtStat]
    /** Wall-clock duration of the scan, finalisation included. */
    let elapsed: TimeInterval
    /** Number of folders that could not be read. */
    let deniedCount: Int
    /** Up to `Scanner.maxDeniedRecorded` of the unreadable folders, sorted by path. */
    let denied: [DeniedFolder]
    /** Whether the scan was stopped early, leaving partial results. */
    let cancelled: Bool
    /** Capacity information for the volume holding the root, if available. */
    let volume: VolumeInfo?
    /** Reused when rescanning a subfolder so the same volumes and firmlink rules apply. */
    let policy: TraversalPolicy

    /**
     * Bundles everything a finished scan produced.
     *
     * @param {Node} root - Root of the finalised tree.
     * @param {String} rootPath - Resolved path that was scanned.
     * @param {[ExtStat]} extStats - Per-extension totals.
     * @param {TimeInterval} elapsed - Scan duration in seconds.
     * @param {Int} deniedCount - Number of unreadable folders.
     * @param {[DeniedFolder]} denied - The recorded unreadable folders.
     * @param {Bool} cancelled - Whether the scan was stopped early.
     * @param {VolumeInfo?} volume - Capacity of the containing volume.
     * @param {TraversalPolicy} policy - The traversal rules the scan used.
     *
     * @example
     * let result = ScanResult(root: root, rootPath: "/", extStats: stats, elapsed: 24.7,
     *                         deniedCount: 0, denied: [], cancelled: false, volume: nil, policy: policy)
     */
    init(root: Node, rootPath: String, extStats: [ExtStat], elapsed: TimeInterval,
         deniedCount: Int, denied: [DeniedFolder], cancelled: Bool, volume: VolumeInfo?, policy: TraversalPolicy) {
        self.root = root
        self.rootPath = rootPath
        self.extStats = extStats
        self.elapsed = elapsed
        self.deniedCount = deniedCount
        self.denied = denied
        self.cancelled = cancelled
        self.volume = volume
        self.policy = policy
    }
}

/**
 * Fast parallel directory scanner built on getattrlistbulk(2).
 *
 * Each worker lists one directory per job and pushes its subdirectories back
 * onto a shared stack; aggregation and sorting happen once at the end.
 */
final class Scanner: @unchecked Sendable {
    /** Live counters for the progress display. */
    struct Progress {
        /** Files found so far. */
        var files: Int
        /** Directories listed so far. */
        var dirs: Int
        /** Bytes of the files found so far, in the scan's size mode. */
        var bytes: Int64
        /** A recently listed directory, refreshed every 64 directories per worker. */
        var currentPath: String
    }

    /** The resolved absolute path being scanned. */
    let rootPath: String
    /** Size mode used for the progress byte counter and the final ordering. */
    let sizeMode: SizeMode

    /** Shared stack of directories still to list. */
    private let queue = WorkQueue<Job>()
    /** Which devices may be entered and which paths are skipped. */
    private let policy: TraversalPolicy
    /** Set once `cancel()` is called; workers check it between directories. */
    private let cancelledFlag = Atomic<Bool>(false)
    /** Files found so far. */
    private let filesCounter = Atomic<Int>(0)
    /** Directories listed so far. */
    private let dirsCounter = Atomic<Int>(0)
    /** Bytes of the files found so far. */
    private let bytesCounter = Atomic<Int64>(0)
    /** Directories that could not be read. */
    private let deniedCounter = Atomic<Int>(0)
    /** The first `maxDeniedRecorded` unreadable directories. */
    private let deniedList = OSAllocatedUnfairLock(initialState: [DeniedFolder]())
    /** Cap on recorded unreadable folders, so a pathological disk cannot grow the list without bound. */
    static let maxDeniedRecorded = 5000
    /** Path shown in the progress display. */
    private let currentPath = OSAllocatedUnfairLock(initialState: "")

    /** One directory waiting to be listed. */
    private struct Job {
        /** The directory's node, whose children the job fills in. */
        let node: Node
        /** Absolute path used to open the directory. */
        let path: String
        /** Whether this is the scan root, which may itself be reached through a symlink. */
        let isRoot: Bool
    }

    /**
     * Prepares a scan of `path` without starting it.
     *
     * The path is resolved with realpath(3), so a symlinked root such as /tmp
     * is scanned at its real location; if resolution fails the path is used
     * as given. Without an explicit policy, one is derived from the mount
     * table for this root.
     *
     * @param {String} path - Folder (or single file) to scan.
     * @param {SizeMode} sizeMode - Size used for progress bytes and final ordering.
     * @param {TraversalPolicy?} [policy=nil] - Policy of an enclosing scan, passed when rescanning a
     *   subfolder so the same volumes and firmlink exclusions apply.
     *
     * @example
     * let scanner = Scanner(path: "/", sizeMode: .allocated)
     */
    init(path: String, sizeMode: SizeMode, policy: TraversalPolicy? = nil) {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &resolved) != nil {
            rootPath = String(cString: resolved)
        } else {
            rootPath = path
        }
        self.sizeMode = sizeMode
        self.policy = policy ?? TraversalPolicy.make(root: rootPath)
    }

    /** A snapshot of the live counters; safe to read from any thread while scanning. */
    var progress: Progress {
        Progress(files: filesCounter.load(ordering: .relaxed),
                 dirs: dirsCounter.load(ordering: .relaxed),
                 bytes: bytesCounter.load(ordering: .relaxed),
                 currentPath: currentPath.withLock { $0 })
    }

    /**
     * Stops the scan as soon as possible.
     *
     * Pending directories are dropped and workers stop after the directory
     * they are listing, so `run(threads:)` returns shortly with a partial tree
     * marked as cancelled. Safe to call from any thread, more than once.
     *
     * @example
     * stopButton.action = #selector(stop) // calls scanner.cancel()
     */
    func cancel() {
        cancelledFlag.store(true, ordering: .relaxed)
        queue.stop()
    }

    /** Whether `cancel()` has been called. */
    var isCancelled: Bool { cancelledFlag.load(ordering: .relaxed) }

    /**
     * Scans the tree synchronously and returns the finished result.
     *
     * Blocks until every directory is listed, so call it from a background
     * thread. Starts `threads` worker threads that share a LIFO work stack,
     * then aggregates totals bottom-up, sorts every directory and tallies
     * extensions. If the root is a single file, nothing is traversed and the
     * result holds just that file. iCloud placeholders are never downloaded.
     *
     * @param {Int} [threads=Scanner.defaultThreadCount] - Number of worker threads.
     * @returns {ScanResult} The finalised tree plus statistics; partial if cancelled.
     *
     * @example
     * DispatchQueue.global().async {
     *     let result = Scanner(path: "/Applications", sizeMode: .allocated).run()
     *     print(result.root.fileCount)
     * }
     */
    func run(threads: Int = Scanner.defaultThreadCount) -> ScanResult {
        Scanner.disableDatalessMaterialization()
        let start = Date()

        let root = Node(name: rootPath, isDir: true)
        var st = stat()
        if lstat(rootPath, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR {
            root.flags = []
            root.size = Int64(st.st_size)
            root.alloc = Int64(st.st_blocks) * 512
            root.fileCount = 1
        } else {
            queue.push([Job(node: root, path: rootPath, isRoot: true)])
            let group = DispatchGroup()
            for _ in 0..<max(1, threads) {
                group.enter()
                let t = Thread { [self] in
                    self.workerLoop()
                    group.leave()
                }
                t.stackSize = 1 << 20
                t.qualityOfService = .userInitiated
                t.start()
            }
            group.wait()
        }

        Scanner.finalize(root: root, sizeMode: sizeMode)
        let stats = ExtStats.compute(root: root)
        let volume = VolumeInfo.info(for: URL(fileURLWithPath: rootPath))
        return ScanResult(root: root, rootPath: rootPath, extStats: stats,
                          elapsed: Date().timeIntervalSince(start),
                          deniedCount: deniedCounter.load(ordering: .relaxed),
                          denied: deniedList.withLock { $0 }.sorted { $0.path < $1.path },
                          cancelled: isCancelled, volume: volume, policy: policy)
    }

    /** Worker threads to use: the core count, kept between 4 and 16 (the kernel stops scaling beyond that). */
    static var defaultThreadCount: Int {
        min(16, max(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    /**
     * Aggregates directory totals bottom-up and orders children largest first.
     *
     * Directories are collected parents-first and then recomputed in reverse,
     * so every child is complete before its parent sums it. The walk is
     * iterative, so deep trees cannot overflow the stack.
     *
     * @param {Node} root - Root of a freshly scanned tree.
     * @param {SizeMode} sizeMode - The size to order children by.
     *
     * @example
     * Scanner.finalize(root: root, sizeMode: .allocated)
     */
    static func finalize(root: Node, sizeMode: SizeMode) {
        let dirs = allDirectories(root)
        for n in dirs.reversed() { n.recomputeFromChildren() }
        sort(dirs, by: sizeMode)
    }

    /**
     * Re-orders every directory's children, e.g. after the size mode changed.
     *
     * Mutates the tree in place: hold `treeLock` if background readers may be
     * walking it.
     *
     * @param {Node} root - Root of the tree to re-sort.
     * @param {SizeMode} sizeMode - The size to order children by.
     *
     * @example
     * treeLock.lock(); Scanner.sortAll(root: result.root, by: .logical); treeLock.unlock()
     */
    static func sortAll(root: Node, by sizeMode: SizeMode) {
        sort(allDirectories(root), by: sizeMode)
    }

    /**
     * Collects every directory under `root` in pre-order.
     *
     * Parents come before their children, which lets `finalize` process the
     * list in reverse as a bottom-up pass.
     *
     * @param {Node} root - Where to start; included if it is a directory.
     * @returns {[Node]} All directories, parents before children.
     *
     * @example
     * let dirs = allDirectories(root)
     */
    private static func allDirectories(_ root: Node) -> [Node] {
        var dirs: [Node] = []
        var stack: [Node] = [root]
        while let n = stack.popLast() {
            guard n.isDir else { continue }
            dirs.append(n)
            for c in n.children where c.isDir { stack.append(c) }
        }
        return dirs
    }

    /**
     * Sorts the children of each given directory in parallel.
     *
     * Splits the list into chunks of 2048 directories for concurrentPerform.
     * This is safe because each directory's children array is touched by
     * exactly one iteration.
     *
     * @param {[Node]} dirs - Directories whose children to sort.
     * @param {SizeMode} sizeMode - The size to order by.
     *
     * @example
     * sort(allDirectories(root), by: .allocated)
     */
    private static func sort(_ dirs: [Node], by sizeMode: SizeMode) {
        let chunk = 2048
        let chunks = (dirs.count + chunk - 1) / chunk
        dirs.withUnsafeBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: chunks) { i in
                let lo = i * chunk, hi = min(buf.count, lo + chunk)
                for j in lo..<hi where buf[j].children.count > 1 {
                    buf[j].sortChildren(by: sizeMode)
                }
            }
        }
    }

    // MARK: - Workers

    /**
     * Body of one worker thread: lists directories until the work runs out.
     *
     * Each worker owns a bulk-attribute buffer and an extension-id cache for
     * the scan's duration. Jobs popped after cancellation are discarded
     * unlisted, but still reported finished so the queue can drain.
     *
     * @example
     * Thread { scanner.workerLoop() }.start()
     */
    private func workerLoop() {
        let ctx = WorkerContext()
        defer { ctx.buffer.deallocate() }
        while let job = queue.pop() {
            if !isCancelled { scan(job, ctx) }
            queue.finished()
        }
    }

    /** Per-thread scratch state, so workers never contend on buffers or caches. */
    private final class WorkerContext {
        /** Size of the getattrlistbulk result buffer. */
        let bufferSize = 256 * 1024
        /** Result buffer for getattrlistbulk, reused for every directory. */
        let buffer: UnsafeMutableRawPointer
        /** Extension string to id, so the shared table's lock is taken only for new extensions. */
        var extCache: [String: UInt16] = [:]
        /** Directories listed since this worker last updated the progress path. */
        var dirsSinceReport = 0

        /**
         * Allocates the worker's result buffer.
         *
         * The buffer is freed by `workerLoop()` when the worker finishes.
         *
         * @example
         * let ctx = WorkerContext()
         */
        init() {
            buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        }

        /**
         * Returns the lower-cased extension id for a raw UTF-8 file name.
         *
         * The extension is the text after the last dot, if the dot is not the
         * first character and 1–15 bytes follow it; names with a space in that
         * part count as having no extension. ASCII letters are lower-cased
         * byte-wise before the local cache lookup, and the shared table is
         * consulted only on a cache miss.
         *
         * @param {UnsafeRawPointer} name - Start of the name bytes (not NUL-terminated).
         * @param {Int} len - Number of bytes in the name.
         * @returns {UInt16} The extension id, or 0 for no extension.
         *
         * @example
         * let ext = ctx.extID(namePtr, nameLen) // "Movie.MOV" -> id of "mov"
         */
        @inline(__always)
        func extID(_ name: UnsafeRawPointer, _ len: Int) -> UInt16 {
            var i = len - 1
            while i > 0 && name.load(fromByteOffset: i, as: UInt8.self) != 0x2E { i -= 1 }
            let extLen = len - i - 1
            guard i > 0, extLen >= 1, extLen <= 15 else { return 0 }
            let key = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { tmp -> String? in
                for k in 0..<extLen {
                    var b = name.load(fromByteOffset: i + 1 + k, as: UInt8.self)
                    if b == 0x20 { return nil }
                    if b >= 0x41 && b <= 0x5A { b |= 0x20 }
                    tmp[k] = b
                }
                return String(decoding: UnsafeBufferPointer(rebasing: tmp[0..<extLen]), as: UTF8.self)
            }
            guard let key else { return 0 }
            if let id = extCache[key] { return id }
            let id = ExtensionTable.shared.intern(key.lowercased())
            extCache[key] = id
            return id
        }
    }

    /** attr.h ATTR_CMN_NAME, spelled out so it imports as UInt32. */
    private static let cmnName: UInt32 = 0x0000_0001
    /** attr.h ATTR_CMN_OBJTYPE. */
    private static let cmnObjType: UInt32 = 0x0000_0008
    /** attr.h ATTR_CMN_MODTIME. */
    private static let cmnModTime: UInt32 = 0x0000_0400
    /** attr.h ATTR_CMN_FLAGS (BSD file flags). */
    private static let cmnFlags: UInt32 = 0x0004_0000
    /** attr.h ATTR_CMN_ERROR; per-entry errors are returned right after the returned-attributes set. */
    private static let cmnError: UInt32 = 0x2000_0000
    /** attr.h ATTR_CMN_RETURNED_ATTRS, required by getattrlistbulk; too large to import as Int32. */
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    /** attr.h ATTR_DIR_MOUNTSTATUS. */
    private static let dirMountStatus: UInt32 = 0x0000_0004
    /** attr.h ATTR_FILE_TOTALSIZE (all forks). */
    private static let fileTotalSize: UInt32 = 0x0000_0002
    /** attr.h ATTR_FILE_ALLOCSIZE. */
    private static let fileAllocSize: UInt32 = 0x0000_0004
    /** attr.h DIR_MNTSTATUS_TRIGGER: an automounter trigger directory. */
    private static let mntStatusTrigger: UInt32 = 0x0000_0002
    /** vnode types VDIR and VLNK from sys/vnode.h. */
    private static let vDIR: UInt32 = 2, vLNK: UInt32 = 5
    /** stat.h SF_DATALESS: the file's data lives in iCloud / a File Provider. */
    private static let sfDataless: UInt32 = 0x4000_0000

    /**
     * Lists one directory and queues its subdirectories.
     *
     * Opens the directory (following a symlink only for the scan root), and
     * skips it when it lives on a device outside the policy. Then reads its
     * entries in bulk with getattrlistbulk. Each packed entry starts with its
     * length and an attribute_set_t saying which attributes follow, so fields
     * are parsed only when present, using unaligned loads.
     *
     * Files become child nodes with sizes, flags and extension ids.
     * Directories become child nodes and new jobs, except paths the policy
     * skips (firmlink duplicates) and automounter triggers, which are marked
     * as other volumes because entering them could block on the network.
     *
     * A failure to open or read marks the node denied. The node's children
     * are assigned in one go and only this worker writes them, so no locking
     * is needed. Updates the progress counters and, every 64 directories,
     * the progress path.
     *
     * @param {Job} job - The directory to list.
     * @param {WorkerContext} ctx - This worker's buffer and caches.
     *
     * @example
     * while let job = queue.pop() { scan(job, ctx); queue.finished() }
     */
    private func scan(_ job: Job, _ ctx: WorkerContext) {
        let node = job.node
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (job.isRoot ? 0 : O_NOFOLLOW)
        let fd = open(job.path, flags)
        if fd < 0 {
            recordDenied(node, job.path, errno)
            return
        }
        defer { close(fd) }

        var st = stat()
        if fstat(fd, &st) == 0, !policy.allowedDevices.contains(st.st_dev) {
            node.flags.insert(.otherVolume)
            return
        }

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = Scanner.cmnReturnedAttrs | Scanner.cmnName | Scanner.cmnError
            | Scanner.cmnObjType | Scanner.cmnModTime | Scanner.cmnFlags
        attrs.dirattr = Scanner.dirMountStatus
        attrs.fileattr = Scanner.fileTotalSize | Scanner.fileAllocSize

        let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
        var kids: [Node] = []
        var subdirs: [Job] = []
        var fileCount = 0
        var fileBytes: Int64 = 0

        listing: while true {
            let n = getattrlistbulk(fd, &attrs, ctx.buffer, ctx.bufferSize, 0)
            if n < 0 {
                recordDenied(node, job.path, errno)
                break
            }
            if n == 0 { break }
            if kids.isEmpty { kids.reserveCapacity(Int(n)) }

            var entry = UnsafeRawPointer(ctx.buffer)
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                let next = entry + length
                defer { entry = next }

                var f = entry + 4
                let common = f.loadUnaligned(as: UInt32.self)
                let dirA = f.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                let fileA = f.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                f += 20

                if common & Scanner.cmnError != 0 {
                    let err = f.loadUnaligned(as: UInt32.self)
                    f += 4
                    if err != 0 { continue }
                }
                guard common & Scanner.cmnName != 0 else { continue }
                let nameOffset = Int(f.loadUnaligned(as: Int32.self))
                let nameLength = Int(f.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                let namePtr = f + nameOffset
                let nameLen = max(0, nameLength - 1)
                f += 8

                var type: UInt32 = 0
                if common & Scanner.cmnObjType != 0 { type = f.loadUnaligned(as: UInt32.self); f += 4 }
                var mtime: UInt32 = 0
                if common & Scanner.cmnModTime != 0 {
                    let sec = f.loadUnaligned(as: Int.self)
                    mtime = UInt32(clamping: sec)
                    f += 16
                }
                var bsdFlags: UInt32 = 0
                if common & Scanner.cmnFlags != 0 { bsdFlags = f.loadUnaligned(as: UInt32.self); f += 4 }
                var mountStatus: UInt32 = 0
                if dirA & Scanner.dirMountStatus != 0 { mountStatus = f.loadUnaligned(as: UInt32.self); f += 4 }
                var total: Int64 = 0
                if fileA & Scanner.fileTotalSize != 0 { total = f.loadUnaligned(as: Int64.self); f += 8 }
                var alloc: Int64 = 0
                if fileA & Scanner.fileAllocSize != 0 { alloc = f.loadUnaligned(as: Int64.self); f += 8 }

                let name = String(decoding: UnsafeRawBufferPointer(start: namePtr, count: nameLen), as: UTF8.self)

                if type == Scanner.vDIR {
                    let childPath = prefix + name
                    if policy.skipPaths.contains(childPath) { continue }
                    let child = Node(name: name, isDir: true, mtime: mtime)
                    child.parent = node
                    kids.append(child)
                    if mountStatus & Scanner.mntStatusTrigger != 0 {
                        child.flags.insert(.otherVolume)
                    } else {
                        subdirs.append(Job(node: child, path: childPath, isRoot: false))
                    }
                } else {
                    let ext = ctx.extID(namePtr, nameLen)
                    let child = Node(name: name, isDir: false, size: total, alloc: alloc, mtime: mtime, ext: ext)
                    if type == Scanner.vLNK { child.flags.insert(.symlink) }
                    if bsdFlags & Scanner.sfDataless != 0 { child.flags.insert(.dataless) }
                    child.parent = node
                    kids.append(child)
                    fileCount += 1
                    fileBytes &+= sizeMode == .allocated ? alloc : total
                }
            }
            if isCancelled { break listing }
        }

        node.children = kids
        filesCounter.add(fileCount, ordering: .relaxed)
        dirsCounter.add(1, ordering: .relaxed)
        bytesCounter.add(fileBytes, ordering: .relaxed)

        ctx.dirsSinceReport += 1
        if ctx.dirsSinceReport >= 64 {
            ctx.dirsSinceReport = 0
            currentPath.withLock { $0 = job.path }
        }
        queue.push(subdirs)
    }

    /**
     * Marks a directory as unreadable and records why.
     *
     * Always counts the folder, but keeps its path only while fewer than
     * `maxDeniedRecorded` are stored. Thread-safe.
     *
     * @param {Node} node - The directory that could not be read.
     * @param {String} path - Its absolute path.
     * @param {Int32} error - The errno that stopped it.
     *
     * @example
     * if fd < 0 { recordDenied(node, job.path, errno) }
     */
    private func recordDenied(_ node: Node, _ path: String, _ error: Int32) {
        node.flags.insert(.denied)
        deniedCounter.add(1, ordering: .relaxed)
        deniedList.withLock { list in
            if list.count < Scanner.maxDeniedRecorded { list.append(DeniedFolder(path: path, error: error)) }
        }
    }

    /**
     * Prevents the scan from downloading iCloud / File Provider placeholders.
     *
     * Sets the process-wide I/O policy
     * IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES to
     * IOPOL_MATERIALIZE_DATALESS_FILES_OFF (scope IOPOL_SCOPE_PROCESS), so
     * reading dataless entries never triggers a download. Idempotent.
     *
     * @example
     * Scanner.disableDatalessMaterialization()
     */
    static func disableDatalessMaterialization() {
        _ = setiopolicy_np(3, 0, 1)
    }
}

/**
 * A LIFO work stack shared by scanner threads.
 *
 * `pop` blocks until work is available or every worker is idle, which means
 * the scan is complete. LIFO order keeps the traversal roughly depth-first,
 * so the stack stays small.
 */
final class WorkQueue<T>: @unchecked Sendable {
    /** Pending items; the last one is popped first. */
    private var items: [T] = []
    /** Items popped but not yet reported finished. */
    private var active = 0
    /** Set by `stop()`; no more items are handed out or accepted. */
    private var stopped = false
    /** Guards all state and wakes waiting workers. */
    private let cond = NSCondition()

    /**
     * Adds items and wakes waiting workers.
     *
     * Wakes one waiter for a single item and all of them for several. Items
     * pushed after `stop()` are discarded.
     *
     * @param {[T]} newItems - Items to add; an empty array is a no-op.
     *
     * @example
     * queue.push(subdirectoryJobs)
     */
    func push(_ newItems: [T]) {
        guard !newItems.isEmpty else { return }
        cond.lock()
        if !stopped {
            items.append(contentsOf: newItems)
            if newItems.count == 1 { cond.signal() } else { cond.broadcast() }
        }
        cond.unlock()
    }

    /**
     * Takes the most recently pushed item, waiting if necessary.
     *
     * Returns nil once the queue is stopped, or when it is empty and no
     * worker is still active, since then no more work can appear. Every
     * non-nil result must be followed by `finished()`.
     *
     * @returns {T?} The next item, or nil when the work is done or stopped.
     *
     * @example
     * while let job = queue.pop() { process(job); queue.finished() }
     */
    func pop() -> T? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if stopped { return nil }
            if let item = items.popLast() {
                active += 1
                return item
            }
            if active == 0 {
                cond.broadcast()
                return nil
            }
            cond.wait()
        }
    }

    /**
     * Reports that a popped item has been fully processed.
     *
     * Call it after pushing any follow-up work, so the queue never looks
     * drained while more work is about to arrive. Wakes all waiters when the
     * last active item finishes with nothing pending.
     *
     * @example
     * scan(job, ctx)
     * queue.finished()
     */
    func finished() {
        cond.lock()
        active -= 1
        if active == 0 && items.isEmpty { cond.broadcast() }
        cond.unlock()
    }

    /**
     * Discards pending items and releases all waiting workers.
     *
     * Afterwards `pop()` returns nil and `push(_:)` ignores new items.
     *
     * @example
     * queue.stop()
     */
    func stop() {
        cond.lock()
        stopped = true
        items.removeAll()
        cond.broadcast()
        cond.unlock()
    }
}
