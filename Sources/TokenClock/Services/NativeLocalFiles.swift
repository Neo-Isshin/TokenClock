#if !os(macOS)
import Foundation
#if os(Windows)
import WinSDK
#else
import CGtk
#endif

enum NativeLocalFiles {
    static func identity(_ url:URL)->String? {
        guard let raw=tc_gtk_file_identity(url.path) else{return nil}
        defer{g_free(raw)};return String(cString:raw)
    }
    static func recycle(_ url: URL) throws {
        #if os(Windows)
        let path = Array(url.path.utf16) + [0,0]
        let code: Int32 = path.withUnsafeBufferPointer { buffer in
            var operation = SHFILEOPSTRUCTW()
            operation.wFunc = UINT(FO_DELETE)
            operation.pFrom = buffer.baseAddress
            operation.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI)
            let result = SHFileOperationW(&operation)
            return operation.fAnyOperationsAborted ? -1 : result
        }
        guard code == 0 else { throw NSError(domain:NSCocoaErrorDomain,code:Int(code),userInfo:[NSLocalizedDescriptionKey:toolboxText("文件未移入回收站。", "The file was not moved to the Recycle Bin.")]) }
        #else
        guard let file = g_file_new_for_path(url.path) else { throw CocoaError(.fileNoSuchFile) }
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        var error: UnsafeMutablePointer<GError>?
        let success = g_file_trash(file,nil,&error)
        defer { if let error { g_error_free(error) } }
        guard success != 0 else { throw NSError(domain:NSCocoaErrorDomain,code:512,userInfo:[NSLocalizedDescriptionKey:error.map{String(cString:$0.pointee.message)} ?? toolboxText("文件未移入回收站。", "The file was not moved to Trash.")]) }
        #endif
    }
}
#endif
