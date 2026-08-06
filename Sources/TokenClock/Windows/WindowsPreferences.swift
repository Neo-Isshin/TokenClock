import Foundation

/// Durable preferences for Windows.
///
/// swift-corelibs-foundation's `UserDefaults.standard` is process-local on some
/// Windows toolchains.  TokenClock therefore owns a small JSON preference store
/// under `%LOCALAPPDATA%\TokenClock\settings.json` and writes it atomically after
/// every change.  The public surface intentionally mirrors the subset of
/// UserDefaults used by the app.
final class WindowsPreferences: @unchecked Sendable {
    static let shared = WindowsPreferences()

    private let lock = NSLock()
    private let fileURL: URL
    private var values: [String: Any]

    private init() {
        let environment = ProcessInfo.processInfo.environment
        let localAppData = environment["LOCALAPPDATA"]
            ?? environment["USERPROFILE"].map { $0 + "/AppData/Local" }
            ?? NSHomeDirectory() + "/AppData/Local"
        let directory = URL(fileURLWithPath: localAppData, isDirectory: true)
            .appendingPathComponent("TokenClock", isDirectory: true)
        fileURL = directory.appendingPathComponent("settings.json", isDirectory: false)

        if let data = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            values = dictionary
        } else {
            values = [:]
        }
    }

    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        object(forKey: key) as? [String]
    }

    func bool(forKey key: String) -> Bool {
        let value = object(forKey: key)
        if let result = value as? Bool { return result }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    func integer(forKey key: String) -> Int {
        let value = object(forKey: key)
        if let result = value as? Int { return result }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    func double(forKey key: String) -> Double {
        let value = object(forKey: key)
        if let result = value as? Double { return result }
        if let number = value as? NSNumber { return number.doubleValue }
        return 0
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        saveLocked()
        lock.unlock()
    }

    func removeObject(forKey key: String) {
        set(nil, forKey: key)
    }

    private func saveLocked() {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
