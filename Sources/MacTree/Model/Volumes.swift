import Foundation
import Darwin

/** A mounted file system, as reported by getmntinfo(3). */
struct MountEntry {
    /** Where the file system is mounted, e.g. "/System/Volumes/Data". */
    let mountPoint: String
    /** Mounted device, e.g. "/dev/disk3s5", or a pseudo name such as "map auto_home". */
    let device: String
    /** File system type, e.g. "apfs", "devfs" or "autofs". */
    let fsType: String

    /** Whole-disk name ("disk3" for "/dev/disk3s5"), or nil for network, devfs and other non-disk mounts. */
    var wholeDisk: String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let rest = device.dropFirst("/dev/".count)
        var end = rest.index(rest.startIndex, offsetBy: 4)
        while end < rest.endIndex, rest[end].isNumber { end = rest.index(after: end) }
        return String(rest[..<end])
    }

    /**
     * Lists every mounted file system.
     *
     * Uses the kernel's cached mount table (MNT_NOWAIT), so it never blocks on
     * unresponsive network volumes. Returns an empty list if the table cannot
     * be read.
     *
     * @returns {[MountEntry]} One entry per mount.
     *
     * @example
     * let apfs = MountEntry.all().filter { $0.fsType == "apfs" }
     */
    static func all() -> [MountEntry] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        return (0..<Int(n)).map { i in
            var s = buf[i]
            return MountEntry(
                mountPoint: cString(&s.f_mntonname),
                device: cString(&s.f_mntfromname),
                fsType: cString(&s.f_fstypename)
            )
        }
    }

    /**
     * Finds the mount that holds a path.
     *
     * @param {String} path - Any existing path.
     * @returns {MountEntry?} The containing mount, or nil if the path cannot be examined.
     *
     * @example
     * MountEntry.containing("/Users")?.mountPoint // "/System/Volumes/Data"
     */
    static func containing(_ path: String) -> MountEntry? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return MountEntry(
            mountPoint: cString(&s.f_mntonname),
            device: cString(&s.f_mntfromname),
            fsType: cString(&s.f_fstypename)
        )
    }

    /**
     * Converts a fixed-size C character array from `statfs` into a String.
     *
     * Reads up to the first NUL byte.
     *
     * @param {T} tuple - A C char array imported as a Swift tuple, e.g. `f_mntonname`.
     * @returns {String} The decoded text.
     *
     * @example
     * var s = statfs(); statfs("/", &s)
     * let point = cString(&s.f_mntonname) // "/"
     */
    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { p in
            p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}

/**
 * Decides which directories a scan may enter so that each byte is counted once.
 *
 * The scan stays within the APFS container (or physical disk) of the root. On
 * the boot volume it also skips the Data-volume paths that are reachable
 * through firmlinks as well.
 */
struct TraversalPolicy {
    /** Devices (st_dev) the scan may enter. */
    let allowedDevices: Set<dev_t>
    /** Absolute directory paths never entered. */
    let skipPaths: Set<String>

    /**
     * Builds the policy for scanning `root`.
     *
     * Allowed devices are the root's own device plus every other volume in
     * the same container, so scanning "/" also covers the Data, VM and
     * Preboot volumes. devfs, autofs, nullfs and fdesc mounts, other disks,
     * and disk images such as simulator runtimes stay excluded.
     *
     * When the Data volume is mounted inside the scan root, each firmlink
     * listed in /usr/share/firmlinks (lines of "<system path>\t<path relative
     * to the Data volume>") whose system-side path is also inside the root
     * adds its Data-volume path to the skip list. Otherwise the same folders
     * would be counted twice, once through the firmlink and once under
     * /System/Volumes/Data. Scanning "/" additionally skips the magic
     * resolver directories /.vol, /.nofollow and /.resolve.
     *
     * @param {String} root - The resolved absolute path being scanned.
     * @returns {TraversalPolicy} The devices and paths the scanner should respect.
     *
     * @example
     * let policy = TraversalPolicy.make(root: "/")
     * policy.skipPaths.contains("/System/Volumes/Data/Users") // true
     */
    static func make(root: String) -> TraversalPolicy {
        let mounts = MountEntry.all()
        let rootMount = MountEntry.containing(root)
        var devices = Set<dev_t>()
        if let d = deviceID(root) { devices.insert(d) }

        let excludedTypes: Set<String> = ["devfs", "autofs", "nullfs", "fdesc"]
        if let container = rootMount?.wholeDisk {
            for m in mounts where m.wholeDisk == container && !excludedTypes.contains(m.fsType) {
                if let d = deviceID(m.mountPoint) { devices.insert(d) }
            }
        }

        var skip = Set<String>()
        let dataMount = "/System/Volumes/Data"
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        if mounts.contains(where: { $0.mountPoint == dataMount }), dataMount.hasPrefix(rootWithSlash) {
            if let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let source = String(parts[0])
                    if source == root || source.hasPrefix(rootWithSlash) {
                        skip.insert(dataMount + "/" + parts[1])
                    }
                }
            }
        }
        if root == "/" {
            skip.formUnion(["/.vol", "/.nofollow", "/.resolve"])
        }
        return TraversalPolicy(allowedDevices: devices, skipPaths: skip)
    }

    /**
     * Returns the device a path lives on.
     *
     * Follows symlinks, so firmlinked and mounted directories report the
     * volume they resolve to.
     *
     * @param {String} path - Path to examine.
     * @returns {dev_t?} The st_dev value, or nil if the path cannot be examined.
     *
     * @example
     * let dataDevice = deviceID("/System/Volumes/Data")
     */
    private static func deviceID(_ path: String) -> dev_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : nil
    }
}

/** A user-visible volume for the location picker and the space summary. */
struct VolumeInfo {
    /** Root URL of the volume. */
    let url: URL
    /** Display name, e.g. "Macintosh HD". */
    let name: String
    /** Capacity in bytes. */
    let total: Int64
    /** Free bytes as Finder reports them (purgeable space counts as free). */
    let available: Int64

    /** Bytes in use: capacity minus available. */
    var used: Int64 { max(0, total - available) }

    /**
     * Lists the volumes a user would see in Finder.
     *
     * Hidden system volumes (Preboot, VM, …) are left out. Volumes whose
     * resource values cannot be read are skipped.
     *
     * @returns {[VolumeInfo]} The browsable mounted volumes.
     *
     * @example
     * for v in VolumeInfo.mounted() { print(v.name, Fmt.bytes(v.available)) }
     */
    static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { info(for: $0) }
    }

    /**
     * Describes the volume that contains a URL.
     *
     * Free space prefers "available for important usage", which counts
     * purgeable space as free the way Finder does. It falls back to the plain
     * available capacity when the former is zero or unsupported (e.g. on
     * some network volumes).
     *
     * @param {URL} url - Any file URL on the volume.
     * @returns {VolumeInfo?} The volume's name and space, or nil if it cannot be queried.
     *
     * @example
     * let home = VolumeInfo.info(for: FileManager.default.homeDirectoryForCurrentUser)
     */
    static func info(for url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                         .volumeURLKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        var avail = v.volumeAvailableCapacityForImportantUsage ?? 0
        if avail == 0 { avail = Int64(v.volumeAvailableCapacity ?? 0) }
        return VolumeInfo(url: v.volume ?? url, name: v.volumeName ?? url.lastPathComponent,
                          total: total, available: avail)
    }
}
