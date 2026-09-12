import AppKit

/** Command-line arguments, checked for the headless modes before the UI starts. */
let arguments = CommandLine.arguments

/**
 * Child-process permission probe, run by `FullDiskAccess.probeInFreshProcess`.
 *
 * Exits with status 0 when Full Disk Access is granted and 1 otherwise,
 * before any UI is created, so the parent can detect a grant that only
 * applies to newly started processes.
 */
if arguments.contains(FullDiskAccess.probeArgument) {
    exit(FullDiskAccess.isGranted ? 0 : 1)
}

/**
 * Headless benchmark: `MacTree --bench /path [threads]`.
 *
 * Scans the path, then prints timing, totals, the largest top-level entries
 * and the largest extensions. `MT_TIMELINE` prints scan progress every second;
 * `MT_DENIED` lists every unreadable folder with its errno class.
 */
if let i = arguments.firstIndex(of: "--bench"), i + 1 < arguments.count {
    let threads = i + 2 < arguments.count ? Int(arguments[i + 2]) ?? Scanner.defaultThreadCount : Scanner.defaultThreadCount
    let scanner = Scanner(path: arguments[i + 1], sizeMode: .allocated)
    if ProcessInfo.processInfo.environment["MT_TIMELINE"] != nil {
        Thread.detachNewThread {
            var last = 0
            var t = 0
            while true {
                Thread.sleep(forTimeInterval: 1)
                t += 1
                let p = scanner.progress
                print("t=\(t)s files=\(p.files) (+\(p.files - last)) dirs=\(p.dirs) cur=\(p.currentPath)")
                last = p.files
            }
        }
    }
    let result = scanner.run(threads: threads)
    let r = result.root
    print("root:", result.rootPath)
    print("threads:", threads, "time:", Fmt.seconds(result.elapsed))
    print("files:", r.fileCount, "dirs:", r.dirCount, "denied:", result.deniedCount)
    print("size:", r.size, Fmt.bytes(r.size), "alloc:", r.alloc, Fmt.bytes(r.alloc))
    for c in r.children.prefix(15) {
        print(String(format: "  %-40@ %12@ %12@ %9d", c.name as NSString, Fmt.bytes(c.alloc) as NSString,
                     Fmt.bytes(c.size) as NSString, c.fileCount))
    }
    if ProcessInfo.processInfo.environment["MT_DENIED"] != nil {
        for d in result.denied { print("  denied", d.isPrivacyProtected ? "EPERM " : "EACCES", d.path) }
    }
    let top = result.extStats.sorted { $0.alloc > $1.alloc }.prefix(10)
    for e in top { print("  ext", e.displayName, Fmt.bytes(e.alloc), e.count) }
    exit(0)
}

/**
 * Headless CSV export, like WizTree's /export: `MacTree --export /path out.csv`.
 *
 * Scans the path and writes every folder and file to the CSV. Exits with
 * status 1 and a message on stderr if the file cannot be written.
 */
if let i = arguments.firstIndex(of: "--export"), i + 2 < arguments.count {
    let result = Scanner(path: arguments[i + 1], sizeMode: .allocated).run()
    do {
        let rows = try CSVExporter.export(root: result.root, to: URL(fileURLWithPath: arguments[i + 2])) { _ in }
        print("exported \(rows) rows in \(Fmt.seconds(result.elapsed)) scan")
        exit(0)
    } catch {
        FileHandle.standardError.write("export failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

/**
 * Headless treemap render: `MacTree --treemap /path out.png`.
 *
 * Scans the path and writes a 1600×800 cushion treemap as PNG, printing the
 * render time and the number of laid-out items.
 */
if let i = arguments.firstIndex(of: "--treemap"), i + 2 < arguments.count {
    let result = Scanner(path: arguments[i + 1], sizeMode: .allocated).run()
    let colors = ExtColors(stats: result.extStats, mode: .allocated)
    let params = TreemapRenderer.Params(width: 1600, height: 800, sizeMode: .allocated, colors: colors, highlightExt: nil)
    let t0 = Date()
    guard let (image, layout) = TreemapRenderer.render(root: result.root, params: params, isCancelled: { false }),
          let image else { exit(1) }
    print("render:", Fmt.seconds(Date().timeIntervalSince(t0)), "items:", layout.items.count)
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[i + 2]))
    exit(0)
}

/** The shared application instance that runs the GUI. */
let app = NSApplication.shared
/** Builds the menus and the main window once the app has launched. */
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
