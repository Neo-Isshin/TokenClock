import Foundation

/// Reads only known quota-response keys from Claude's own Chromium Simple Cache.
/// No directory crawl, request, browser automation, Cookie or Keychain lookup.
/// Format references: Chromium simple_entry_format.h, simple_util.cc and
/// http_response_info.cc. This implementation does not embed browser code.
enum ClaudeAppResponseCache {
    static let maximumBodyBytes = 1_048_576
    static let maximumAge: TimeInterval = 600
    struct Response {
        let data: Data
        let recordedAt: Date
        let organizationID: String
    }
    static func entryKeys(organizationID: String) -> [Data] {
        guard let id = UUID(uuidString: organizationID)?.uuidString.lowercased() else { return [] }
        let url = "https://claude.ai/api/organizations/" + id + "/usage"
        let prefixes = ["", "1/0/", "1/0/_dk_https://claude.ai https://claude.ai ",
                        "1/0/_dk_https://claude.ai https://claude.ai/ "]
        return prefixes.flatMap { prefix in [Data((prefix + url).utf8), Data((prefix + url + "?cedar_ember=1").utf8)] }
    }
    static func fileName(for key: Data) -> String {
        let hash = Array(CacheHash.sha1(key))
        let value = (0..<8).reduce(UInt64(0)) { $0 | UInt64(hash[$1]) << ($1 * 8) }
        return String(format: "%016llx_0", value)
    }
    static func read(home: String, organizationID: String, now: Date = Date(),
                     decodeBody: ((Data) -> Data?)? = nil) -> Response? {
        let directory = URL(fileURLWithPath: home).appendingPathComponent("Cache/Cache_Data")
        return entryKeys(organizationID: organizationID).compactMap { key in
            readEntry(directory.appendingPathComponent(fileName(for: key)), expectedKey: key,
                      organizationID: organizationID, now: now, decodeBody: decodeBody)
        }.max { $0.recordedAt < $1.recordedAt }
    }
    private static func readEntry(_ url: URL, expectedKey: Data, organizationID: String, now: Date,
                                  decodeBody: ((Data) -> Data?)?) -> Response? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        func read(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, count >= 0, count <= maximumBodyBytes else { return nil }
            do {
                try file.seek(toOffset: UInt64(offset))
                let data = try file.read(upToCount: count) ?? Data()
                return data.count == count ? data : nil
            } catch { return nil }
        }
        guard let length = try? file.seekToEnd(), length <= UInt64(maximumBodyBytes + 70_000), length >= 72,
              let header = read(0, 24), header.u64(0) == 0xfcfb6d1ba7725c30,
              header.u32(8) == 5, header.u32(12) == UInt32(expectedKey.count),
              let key = read(24, expectedKey.count), key == expectedKey,
              let footer = read(Int(length) - 24, 24), footer.u64(0) == 0xf4fa6f45970d41d8,
              let flags = footer.u32(8), flags & 3 == 3, flags & ~UInt32(3) == 0,
              let infoSize = footer.u32(16), infoSize >= 28, infoSize <= 65_536 else { return nil }
        let infoOffset = Int(length) - 24 - 32 - Int(infoSize)
        let bodyOffset = 24 + expectedKey.count
        let bodySize = infoOffset - 24 - bodyOffset
        guard bodySize > 0, bodySize <= maximumBodyBytes,
              let info = read(infoOffset, Int(infoSize)), info.crc32 == footer.u32(12),
              let keySHA = read(Int(length) - 56, 32), keySHA == CacheHash.sha256(key),
              let bodyFooter = read(infoOffset - 24, 24), bodyFooter.u64(0) == 0xf4fa6f45970d41d8,
              let bodyFlags = bodyFooter.u32(8), bodyFlags & 1 == 1,
              let date = responseDate(info), date <= now, now.timeIntervalSince(date) <= maximumAge,
              let encoded = read(bodyOffset, bodySize), encoded.crc32 == bodyFooter.u32(12),
              let body = decodeBody?(encoded) ?? (decodeBody == nil ? QuotaCacheBody.decode(encoded) : nil),
              body.count <= maximumBodyBytes,
              (try? JSONSerialization.jsonObject(with: body)) is [String: Any],
              // Reject replacement or in-progress writes rather than combining
              // the previous entry's body with a new response's timestamp.
              (try? file.seekToEnd()) == length,
              read(0, 24) == header, read(Int(length) - 24, 24) == footer,
              read(infoOffset, Int(infoSize)) == info,
              read(bodyOffset, bodySize) == encoded else { return nil }
        return Response(data: body, recordedAt: date, organizationID: organizationID.lowercased())
    }
    private static func responseDate(_ info: Data) -> Date? {
        guard info.u32(0) == UInt32(info.count - 4), let flags = info.u32(4),
              flags & 255 == 3, flags & (1 << 12) == 0 else { return nil }
        let hasExtra = flags & (1 << 31) != 0
        guard let extra = hasExtra ? info.u32(8) : 0 else { return nil }
        var offset = hasExtra ? 12 : 8
        guard let timestamp = info.u64(offset + 8), timestamp <= UInt64(Int64.max) else { return nil }
        offset += 16 + (extra & 4 != 0 ? 8 : 0)
        guard let size = info.u32(offset), size > 0, size <= 65_536,
              offset + 4 + Int(size) <= info.count else { return nil }
        let bytes = info.subdata(in: offset + 4 ..< offset + 4 + Int(size))
        let headers = String(decoding: bytes, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true)
        let status = headers.first?.split(separator: " ") ?? []
        guard status.count >= 2, status[0].hasPrefix("HTTP/"), status[1] == "200",
              headers.contains(where: { $0.lowercased().hasPrefix("content-type:") && $0.lowercased().contains("application/json") }),
              !headers.contains(where: { $0.lowercased().hasPrefix("cf-mitigated:") && $0.lowercased().contains("challenge") }) else { return nil }
        let seconds = Double(timestamp) / 1_000_000 - 11_644_473_600
        return seconds.isFinite && seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }
}

private extension Data {
    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    func u64(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset <= count - 8 else { return nil }
        return withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
    var crc32: UInt32 {
        var crc = UInt32.max
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
}

/// Uses the already bundled decoder, with a one-MiB output and window bound.
/// Unknown encodings are skipped; no new executable or package is installed.
private final class QuotaCacheBody: @unchecked Sendable {
    static let shared = QuotaCacheBody()
    typealias Create = @convention(c) () -> OpaquePointer?
    typealias Operation = @convention(c) (OpaquePointer?) -> UInt
    typealias Decode = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UInt
    typealias Parameter = @convention(c) (OpaquePointer?, Int32, Int32) -> UInt
    typealias IsError = @convention(c) (UInt) -> UInt32
    struct Buffer { var pointer: UnsafeRawPointer?; var size: Int; var pos: Int }
    private init() {}
    private func symbol<T>(_ name: String, _: T.Type) -> T? { ZstdLibrary.shared.symbol(name,T.self) }
    static func decode(_ data: Data) -> Data? {
        guard data.count <= ClaudeAppResponseCache.maximumBodyBytes else { return nil }
        if let first = data.first(where: { ![9, 10, 13, 32].contains($0) }), first == 123 { return data }
        guard data.prefix(4) == Data([0x28, 0xb5, 0x2f, 0xfd]) else { return nil }
        return shared.zstd(data)
    }
    private func zstd(_ data: Data) -> Data? {
        guard let create = symbol("ZSTD_createDStream", Create.self),
              let initialize = symbol("ZSTD_initDStream", Operation.self),
              let free = symbol("ZSTD_freeDStream", Operation.self),
              let decode = symbol("ZSTD_decompressStream", Decode.self),
              let parameter = symbol("ZSTD_DCtx_setParameter", Parameter.self),
              let error = symbol("ZSTD_isError", IsError.self), let stream = create() else { return nil }
        defer { _ = free(stream) }
        guard error(initialize(stream)) == 0, error(parameter(stream, 100, 20)) == 0 else { return nil }
        var result = Data(), output = [UInt8](repeating: 0, count: 65_536), last: UInt = 1
        let valid = data.withUnsafeBytes { raw -> Bool in
            var input = Buffer(pointer: raw.baseAddress, size: raw.count, pos: 0)
            while input.pos < input.size {
                let previous = input.pos
                var emitted = 0
                let okay = output.withUnsafeMutableBytes { bytes -> Bool in
                    var target = Buffer(pointer: bytes.baseAddress, size: bytes.count, pos: 0)
                    last = decode(stream, &target, &input); emitted = target.pos
                    guard error(last) == 0, result.count + emitted <= ClaudeAppResponseCache.maximumBodyBytes else { return false }
                    result.append(contentsOf: bytes.prefix(emitted)); return true
                }
                guard okay, input.pos > previous || emitted > 0 else { return false }
            }
            return last == 0
        }
        return valid ? result : nil
    }
}
