#if os(Linux)
  import Foundation

  actor NewsLogoCache {
    static let shared = NewsLogoCache()
    private var pending: [String: Task<URL?, Never>] = [:]
    func file(for url: URL) async -> URL? {
      guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host,
        !["localhost", "127.0.0.1", "::1"].contains(host)
      else { return nil }
      let name = CacheHash.sha256(Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }
        .joined()
      let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] ?? NSHomeDirectory()
          + "/.cache"
      ).appendingPathComponent("tokenclock/news-logos")
      let path = root.appendingPathComponent(name + ".image")
      if let date = try? path.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
        Date().timeIntervalSince(date) < 7 * 86400
      {
        return path
      }
      if let task = pending[name] { return await task.value }
      let task = Task<URL?, Never> {
        let fetcher = NetworkDiagnosticFetcher(
          maximumBodyBytes: 262144, userAgent: "TokenClock-NewsLogo/1")
        let reply = await fetcher.fetch(url)
        fetcher.cancel()
        guard reply.status == 200, !reply.limited, !reply.data.isEmpty, reply.data.count <= 262144
        else { return nil }
        do {
          try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          try reply.data.write(to: path, options: .atomic)
          return path
        } catch { return nil }
      }
      pending[name] = task
      let result = await task.value
      pending[name] = nil
      return result
    }
  }
#endif
