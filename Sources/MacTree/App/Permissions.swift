import AppKit

/**
 * Full Disk Access (TCC "SystemPolicyAllFiles").
 *
 * macOS has no API that shows a Full Disk Access prompt, so the app probes a
 * file that only processes with the grant can open and guides the user to
 * System Settings.
 */
enum FullDiskAccess {
    /** Files readable only with Full Disk Access; opening them never triggers a prompt. */
    private static var probes: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
    }

    /**
     * Whether this process can read files protected by Full Disk Access.
     *
     * Opens each probe file in turn. EPERM means privacy protection refused
     * the read, so access is missing; a missing file or any other error is
     * inconclusive and the next probe is tried. A grant made after launch is
     * not visible here until the app restarts (see `probeInFreshProcess`).
     * Setting `MACTREE_ASSUME_NO_FDA` forces false, which lets the permission
     * UI be tested on a Mac that already has access.
     */
    static var isGranted: Bool {
        if ProcessInfo.processInfo.environment[assumeDeniedVariable] != nil { return false }
        for path in probes {
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM { return false }
        }
        return false
    }

    /**
     * Checks for Full Disk Access from a newly started child process.
     *
     * macOS applies a new grant only to processes started after it, so this
     * detects a grant that the running app cannot use until it is relaunched.
     * Runs this executable with `probeArgument` on a background queue; the
     * child does not inherit `MACTREE_ASSUME_NO_FDA`, so it reports the real
     * state. The completion handler runs on the main queue.
     *
     * @param {(Bool) -> Void} completion - Receives true if the child could read the probe files.
     *
     * @example
     * FullDiskAccess.probeInFreshProcess { granted in
     *     if granted && !FullDiskAccess.isGranted { showRelaunchPrompt() }
     * }
     */
    static func probeInFreshProcess(completion: @escaping (Bool) -> Void) {
        guard let executable = Bundle.main.executableURL else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = executable
            task.arguments = [probeArgument]
            var env = ProcessInfo.processInfo.environment
            env[assumeDeniedVariable] = nil
            task.environment = env
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var granted = false
            if (try? task.run()) != nil {
                task.waitUntilExit()
                granted = task.terminationStatus == 0
            }
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /** Environment variable that makes `isGranted` report false in this process only. */
    private static let assumeDeniedVariable = "MACTREE_ASSUME_NO_FDA"

    /** Command-line flag handled in main.swift; the process exits with status 0 when access is granted. */
    static let probeArgument = "--probe-full-disk-access"

    /**
     * Opens System Settings at Privacy & Security › Full Disk Access.
     *
     * Tries the current settings URL scheme first and falls back to the older
     * System Preferences one; stops at the first URL the system accepts.
     *
     * @example
     * FullDiskAccess.openSettings()
     */
    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /**
     * Quits and reopens the app, optionally rescanning a folder on start.
     *
     * A new Full Disk Access grant only applies to a fresh process. A small
     * shell script waits for this process to exit and then reopens the bundle
     * with `open`, passing `--scan` when a path is given. Outside an .app
     * bundle there is nothing to reopen, so the app just quits. Attached
     * sheets are closed first because AppKit refuses to quit while one is open.
     *
     * @param {String?} path - Folder to scan after the relaunch, or nil to start idle.
     *
     * @example
     * FullDiskAccess.relaunch(scanning: result?.rootPath)
     */
    static func relaunch(scanning path: String?) {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else {
            NSApp.terminateClosingSheets()
            return
        }
        var script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\""
        var args = [bundle]
        if let path {
            script += " --args --scan \"$1\""
            args.append(path)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script] + args
        try? task.run()
        NSApp.terminateClosingSheets()
    }

    /** Whether the app runs from an .app bundle and can therefore reopen itself. */
    static var canRelaunch: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /** User-defaults key for "Don't ask at launch". */
    private static let skipKey = "skipFullDiskAccessPrompt"

    /** Whether the user ticked "Don't ask at launch"; persisted in user defaults. */
    static var promptSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: skipKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipKey) }
    }
}

extension NSApplication {
    /**
     * Quits the app even when a sheet is open.
     *
     * AppKit silently refuses to terminate while a window has a sheet
     * attached, which would break ⌘Q, the relaunch button and System
     * Settings' "Quit & Reopen". Ends every attached sheet first (with a small
     * cap in case a sheet keeps re-presenting itself), then terminates.
     *
     * @example
     * NSApp.terminateClosingSheets()
     */
    func terminateClosingSheets() {
        for window in windows {
            var guardCount = 0
            while let sheet = window.attachedSheet, guardCount < 8 {
                window.endSheet(sheet)
                sheet.orderOut(nil)
                guardCount += 1
            }
        }
        terminate(nil)
    }
}
