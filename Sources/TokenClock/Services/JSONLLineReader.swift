import Foundation

/// Chunked JSONL reader that compacts its buffer once per chunk instead of once
/// per line. The previous scanners copied the unconsumed suffix for every line,
/// which became quadratic for large rollout files.
enum JSONLLineReader {
    struct Result {
        let offset: UInt64
        let trailingData: Data
    }

    static func read(
        path: String,
        from offset: UInt64 = 0,
        prefix: Data = Data(),
        matchingAny needles: [Data] = [],
        onLine: (String) -> Void
    ) -> Result? {
        // Cold scans are dominated by large historical files. A read-only mmap
        // lets us inspect line slices without allocating/copying each enormous
        // tool-output record. EOF appends still use the streaming path below.
        if offset == 0, prefix.isEmpty,
           let mapped = try? Data(
               contentsOf: URL(fileURLWithPath: path),
               options: [.mappedIfSafe, .uncached]
           ) {
            return readMapped(mapped, matchingAny: needles, onLine: onLine)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        var buffer = prefix
        // `prefix` is the already-searched, newline-free tail from a previous
        // read. Start the next search at newly appended bytes so very large
        // single JSON records stay linear instead of being rescanned per chunk.
        var searchedByteCount = prefix.count
        var readOffset = offset
        let chunkSize = max(AppConfig.Scan.jsonlBufferSize, 4_096)

        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { break }

            readOffset += UInt64(chunk.count)
            buffer.append(chunk)

            var lineStart = buffer.startIndex
            var searchStart = buffer.index(buffer.startIndex, offsetBy: searchedByteCount)
            while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
                let lineData = buffer[lineStart..<newline]
                if lineStart < newline,
                   (needles.isEmpty || needles.contains(where: { lineData.range(of: $0) != nil })),
                   let line = String(data: lineData, encoding: .utf8) {
                    withAutoreleasePool { onLine(line) }
                }
                lineStart = buffer.index(after: newline)
                if lineStart == buffer.endIndex { break }
                searchStart = lineStart
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
            searchedByteCount = buffer.count
        }

        return Result(offset: readOffset, trailingData: buffer)
    }

    private static func readMapped(
        _ data: Data,
        matchingAny needles: [Data],
        onLine: (String) -> Void
    ) -> Result {
        var lineStart = data.startIndex
        while lineStart < data.endIndex,
              let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let lineData = data[lineStart..<newline]
            if !lineData.isEmpty,
               (needles.isEmpty || needles.contains(where: { lineData.range(of: $0) != nil })),
               let line = String(data: lineData, encoding: .utf8) {
                withAutoreleasePool { onLine(line) }
            }
            lineStart = data.index(after: newline)
        }
        return Result(
            offset: UInt64(data.count),
            trailingData: lineStart < data.endIndex ? Data(data[lineStart...]) : Data()
        )
    }

    /// A valid final JSON value is a complete JSONL record even without a final
    /// newline. Invalid data is retained so an append can finish the record.
    static func consumeCompleteTrailingLine(
        _ data: Data,
        onLine: (String) -> Void
    ) -> Data {
        guard !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) != nil,
              let line = String(data: data, encoding: .utf8) else {
            return data
        }
        withAutoreleasePool { onLine(line) }
        return Data()
    }

    /// Apple Foundation can accumulate temporary Objective-C objects while a large JSONL file
    /// is scanned. Windows/Linux have no Objective-C runtime, so this compiles to a direct call.
    @inline(__always)
    private static func withAutoreleasePool(_ body: () -> Void) {
#if canImport(ObjectiveC)
        autoreleasepool(invoking: body)
#else
        body()
#endif
    }
}
