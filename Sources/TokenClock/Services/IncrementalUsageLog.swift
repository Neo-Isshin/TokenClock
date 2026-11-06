import Foundation

/// A per-file read cursor, owned by one usage scanner. Source files are always
/// opened read-only. Callers stage parsed events and commit them only on success.
struct IncrementalUsageLog {
    struct Stamp: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
        let device: UInt64
        init?(_ attributes: [FileAttributeKey: Any]) {
            guard let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.size = size.uint64Value; self.modified = modified
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        }
        static func read(_ path: String) -> Self? {
            (try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)).flatMap(Self.init)
        }
    }
    private(set) var stamp: Stamp?
    private(set) var offset: UInt64 = 0
    private var tail = Data()
    private var head = Data()
    private var boundary = Data()

    struct Read {
        let reset: Bool
        let fromOffset: UInt64
    }

    mutating func read(path: String, matchingAny needles: [Data], onLine: (String) -> Void) -> Read? {
        guard let before = Stamp.read(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        func bytes(at position: UInt64, count: Int) -> Data? {
            do { try handle.seek(toOffset: position); return try handle.read(upToCount: count) ?? Data() }
            catch { return nil }
        }
        let sameIdentity = stamp.map { $0.inode == before.inode && $0.device == before.device } ?? false
        var reset = !sameIdentity || before.size < offset
            || (before.size == offset && stamp?.modified != before.modified)
        if !reset, offset > 0 {
            // Detect rewritten heads and truncate/regrow at the previous EOF,
            // rather than treating every growing file as a safe append.
            guard let prefix = bytes(at: 0, count: head.count),
                  let suffix = bytes(at: offset - UInt64(boundary.count), count: boundary.count) else { return nil }
            reset = prefix != head || suffix != boundary
        }
        if !reset, offset > 0, tail.isEmpty, boundary.last != 0x0A, before.size > offset {
            // A complete JSON value at EOF is already counted. It can only be
            // followed by a new record after a newline; concatenated JSON must
            // retain the cold scanner's rejection of that malformed line.
            guard let next = bytes(at: offset, count: 1) else { return nil }
            if next != Data([0x0A]) { reset = true }
        }
        let start = reset ? 0 : offset
        guard let result = JSONLLineReader.read(path: path, from: start, prefix: reset ? Data() : tail,
                                               matchingAny: needles, onLine: onLine) else { return nil }
        let pending = JSONLLineReader.consumeCompleteTrailingLine(result.trailingData, onLine: onLine)
        guard let after = Stamp.read(path), before.inode == after.inode, before.device == after.device,
              after.size >= result.offset,
              let prefix = bytes(at: 0, count: Int(min(result.offset, 4096))),
              let suffix = bytes(at: result.offset - min(result.offset, 4096), count: Int(min(result.offset, 4096))) else { return nil }
        // If an in-place rewrite races the read, retry the complete file next scan.
        guard reset || prefix.starts(with: head) && bytes(at: offset - UInt64(boundary.count), count: boundary.count) == boundary else { return nil }
        stamp = after; offset = result.offset; tail = pending; head = prefix; boundary = suffix
        return Read(reset: reset, fromOffset: start)
    }
}
