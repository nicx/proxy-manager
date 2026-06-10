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
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(pending.subdata(in: pending.startIndex..<nl))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}
