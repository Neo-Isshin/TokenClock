#if os(macOS)
import Foundation
import Darwin

/// Only a source path supplied by the log reader can bypass file selection.
/// Session names, project directories, model labels, and IDs are not inputs here.
enum ModelDetectSessionSource {
    static let maxBytes = 64 * 1024 * 1024

    static func usablePath(_ sourcePath: String?) -> String? {
        guard let path = sourcePath, !path.isEmpty, !path.contains("\0"),
              (path as NSString).isAbsolutePath else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= Int64(maxBytes),
              access(path, R_OK) == 0 else { return nil }
        return path
    }
}
#endif
