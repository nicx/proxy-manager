import Foundation

/// Tracks a read offset into a growing log file and returns newly appended,
/// newline-delimited records. Handles truncation/rotation by restarting.
struct FileTail {
    private var offset: UInt64 = 0
    private var pending = Data()

    mutating func reset() {
        offset = 0
        pending = Data()
    }

    /// Jump to the current end of the file without reading the existing content.
    /// Use once when starting to watch a log so startup cost is independent of the
    /// file size — a public proxy's access log can grow to hundreds of MB, and
    /// reading+splitting all of it on the main thread would hang the app.
    mutating func primeToEnd(from url: URL) {
        if let handle = try? FileHandle(forReadingFrom: url) {
            offset = (try? handle.seekToEnd()) ?? 0
            try? handle.close()
        } else {
            offset = 0
        }
        pending = Data()
    }

    /// Returns complete lines appended since the last call (as raw Data, no newline).
    mutating func newLines(from url: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; pending = Data() }   // file shrank → rotated
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        guard !data.isEmpty else { return [] }

        pending.append(data)
        var lines: [Data] = []
        // Walk a cursor forward instead of repeatedly removing from the front
        // (that was O(n²) and stalled on large appends); trim once at the end.
        var start = pending.startIndex
        while let nl = pending[start...].firstIndex(of: 0x0A) {
            lines.append(pending.subdata(in: start..<nl))
            start = pending.index(after: nl)
        }
        if start > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<start)
        }
        return lines
    }
}
