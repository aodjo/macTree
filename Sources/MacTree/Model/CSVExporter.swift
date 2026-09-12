import Foundation

/** Writes every folder and file of a scan as CSV, like WizTree's export. */
enum CSVExporter {
    /**
     * Streams the whole tree to a CSV file.
     *
     * Columns: Path, Type (Folder/File), Size, Allocated, Files, Folders,
     * Modified (ISO 8601). The file starts with a UTF-8 byte-order mark so
     * spreadsheet apps pick the right encoding. Paths are always quoted, with
     * embedded quotes doubled. Rows go out depth-first, parents before their
     * children, and each directory's path is built only once.
     *
     * Output is buffered in about 1 MB chunks, and `progress` is called after
     * each flush. The tree is read under `treeLock` for the whole export, so
     * call this off the main thread; main-thread tree mutations wait until it
     * finishes. An existing file at `url` is replaced.
     *
     * @param {Node} root - The scan root (or any subtree) to export.
     * @param {URL} url - Destination file.
     * @param {(Int) -> Void} progress - Called with the number of rows written so far, on the calling thread.
     * @returns {Int} The number of data rows written (header excluded).
     * @throws {CocoaError} If the file cannot be created or written.
     *
     * @example
     * DispatchQueue.global().async {
     *     let rows = try? CSVExporter.export(root: result.root, to: url) { print("\($0) rows") }
     * }
     */
    static func export(root: Node, to url: URL, progress: (Int) -> Void) throws -> Int {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 20)

        /**
         * Writes the buffered bytes to the file and empties the buffer.
         *
         * Keeps the buffer's capacity so the next chunk does not reallocate.
         *
         * @throws {Error} If writing to the file handle fails.
         *
         * @example
         * if buffer.count > limit { try flush() }
         */
        func flush() throws {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        /**
         * Appends raw text to the buffer.
         *
         * The text is copied as UTF-8 without any escaping, so use it only for
         * values that cannot contain commas or quotes.
         *
         * @param {String} s - Text to append.
         *
         * @example
         * append(",File,")
         */
        func append(_ s: String) { buffer.append(contentsOf: s.utf8) }

        /**
         * Appends a CSV-quoted field to the buffer.
         *
         * Wraps the value in double quotes and doubles any quote inside it, so
         * paths containing commas, quotes or newlines stay one field.
         *
         * @param {String} s - Field value, typically a path.
         *
         * @example
         * appendQuoted("/Users/me/we,ird \"name\"") // "/Users/me/we,ird ""name"""
         */
        func appendQuoted(_ s: String) {
            buffer.append(0x22)
            for b in s.utf8 {
                if b == 0x22 { buffer.append(0x22) }
                buffer.append(b)
            }
            buffer.append(0x22)
        }

        let iso = ISO8601DateFormatter()
        buffer.append(contentsOf: [0xEF, 0xBB, 0xBF])
        append("Path,Type,Size,Allocated,Files,Folders,Modified\n")

        treeLock.lock()
        defer { treeLock.unlock() }
        var rows = 0
        var stack: [(Node, String)] = [(root, root.path)]
        while let (node, path) = stack.popLast() {
            appendQuoted(path)
            append(node.isDir ? ",Folder," : ",File,")
            append("\(node.size),\(node.alloc),\(node.fileCount),\(node.dirCount),")
            if let d = node.modificationDate { append(iso.string(from: d)) }
            buffer.append(0x0A)
            rows += 1
            if buffer.count > (1 << 20) - 4096 {
                try flush()
                progress(rows)
            }
            if node.isDir {
                let prefix = path.hasSuffix("/") ? path : path + "/"
                for c in node.children.reversed() { stack.append((c, prefix + c.name)) }
            }
        }
        try flush()
        return rows
    }
}
