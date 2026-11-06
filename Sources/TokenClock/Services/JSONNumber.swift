import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
/// Keep JSON booleans distinct from numeric 0/1 on all Foundation runtimes.
enum JSONNumber {
    static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
        #endif
    }
}
