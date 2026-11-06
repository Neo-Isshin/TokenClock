import Foundation
#if os(macOS)
import CoreServices
#endif

/// Cache directory membership, never log contents or file modification stamps.
/// macOS filesystem events invalidate membership on create/remove/rename; file
/// data changes still go through the scanners' ordinary per-file checks.
final class UsageLogDirectoryIndex {
    private let lock = NSLock()
    private var generation = 0
    private var entries: [String: (IncrementalUsageLog.Stamp, Int, [URL])] = [:]
    private var roots: [String] = []
    private var cacheActive = false
    #if os(macOS)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.tokenclock.usage-directory-events", qos: .utility)
    private final class Context {
        weak var index: UsageLogDirectoryIndex?
        init(_ index: UsageLogDirectoryIndex) { self.index = index }
    }
    #endif

    func prepare(roots requested: [String]) {
        let paths = Set(requested.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .filter { FileManager.default.fileExists(atPath: $0) }).sorted()
        guard paths != roots else { return }
        reset()
        roots = paths
        #if os(macOS)
        guard !paths.isEmpty else { return }
        let box = Context(self)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Context>.fromOpaque(pointer).retain().toOpaque())
            }, release: { pointer in
                if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        guard let next = withExtendedLifetime(box, { FSEventStreamCreate(nil, { _, info, count, _, flags, _ in
            guard let info else { return }
            let index = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().index
            let invalidating = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            if (0..<count).contains(where: { flags[$0] & invalidating != 0 }) { index?.invalidate() }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) }) else { return }
        FSEventStreamSetDispatchQueue(next, queue)
        if FSEventStreamStart(next) { stream = next; cacheActive = true }
        else { FSEventStreamInvalidate(next); FSEventStreamRelease(next) }
        #endif
    }

    func children(in path: String) -> [URL] {
        guard let stamp = IncrementalUsageLog.Stamp.read(path) else { return [] }
        let (version, cached) = lock.withLock { (generation, entries[path]) }
        if cacheActive, let cached, cached.0 == stamp, cached.1 == version { return cached.2 }
        guard let children = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return [] }
        if cacheActive {
            lock.withLock { if generation == version { entries[path] = (stamp, version, children) } }
        }
        return children
    }

    func jsonlFiles(recursivelyIn root: URL) -> [URL] {
        var pending = [root], files: [URL] = []
        while let directory = pending.popLast() {
            for url in children(in: directory.path) where !url.lastPathComponent.hasPrefix(".") {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { pending.append(url) }
                else if url.pathExtension == "jsonl" { files.append(url) }
            }
        }
        return files
    }

    private func invalidate() { lock.withLock { generation &+= 1; entries.removeAll() } }
    func reset() {
        #if os(macOS)
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
        #endif
        cacheActive = false; roots = []; invalidate()
    }
    deinit { reset() }
}
