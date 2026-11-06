import Foundation
#if os(Windows)
import WinSDK
#elseif os(Linux)
import Glibc
#else
import Darwin
#endif

/// Loads only the decoder shipped with this build, never a DLL from the CWD.
final class ZstdLibrary: @unchecked Sendable {
    static let shared = ZstdLibrary()
    #if os(Windows)
    private let handle: HMODULE?
    #else
    private let handle: UnsafeMutableRawPointer?
    #endif
    private init() {
        #if os(Windows)
        let file = Bundle.module.resourceURL?.appendingPathComponent("DSHDecoder/libzstd.dll")
        handle = file.map { file in file.path.withCString(encodedAs: UTF16.self) { LoadLibraryExW($0,nil,DWORD(LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)) } } ?? nil
        #else
        let name = "DSHDecoder/" + (ProcessInfo.processInfo.operatingSystemVersionString.contains("Darwin") ? "libzstd.1.dylib" : "libzstd.so.1")
        #if os(macOS)
        let file = Bundle.module.resourceURL?.appendingPathComponent("DSHDecoder/libzstd.1.dylib")
        #else
        let file = Bundle.module.resourceURL?.appendingPathComponent(name)
        #endif
        handle = file.flatMap { $0.path.withCString { dlopen($0, RTLD_NOW | RTLD_LOCAL) } }
        #endif
    }
    func symbol<T>(_ name: String, _: T.Type) -> T? {
        guard let handle else { return nil }
        #if os(Windows)
        guard let value = name.withCString({ GetProcAddress(handle,$0) }) else { return nil }
        #else
        guard let value = dlsym(handle,name) else { return nil }
        #endif
        return unsafeBitCast(value,to:T.self)
    }
}
