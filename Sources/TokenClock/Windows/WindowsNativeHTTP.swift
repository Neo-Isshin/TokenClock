#if os(Windows)
import Foundation
import Win32Shim

struct WindowsNativeHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

enum WindowsNativeHTTPError: Error, CustomStringConvertible {
    case invalidRequest
    case transport(UInt32)

    var description: String {
        switch self {
        case .invalidRequest: return "invalid Windows native HTTP request"
        case .transport(let code): return "WinHTTP error \(code)"
        }
    }
}

/// Synchronous Windows-native request bridge. Callers are responsible for invoking it from a
/// background task/queue; all current users already do so. Redirects, ambient proxy settings,
/// cookie persistence and automatic credentials are disabled in the C implementation.
enum WindowsNativeHTTP {
    static func request(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        connectTimeout: TimeInterval = 10,
        sendTimeout: TimeInterval = 10,
        receiveTimeout: TimeInterval = 30,
        maximumResponseBytes: Int = 2 * 1024 * 1024
    ) throws -> WindowsNativeHTTPResponse {
        guard !url.isEmpty,
              method == "GET" || method == "POST",
              (body?.count ?? 0) <= Int(Int32.max),
              maximumResponseBytes > 0,
              maximumResponseBytes <= 16 * 1024 * 1024 else {
            throw WindowsNativeHTTPError.invalidRequest
        }
        for (name, value) in headers {
            guard !name.isEmpty,
                  !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                throw WindowsNativeHTTPError.invalidRequest
            }
        }

        let headerBlock = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        let connectMilliseconds = timeoutMilliseconds(connectTimeout)
        let sendMilliseconds = timeoutMilliseconds(sendTimeout)
        let receiveMilliseconds = timeoutMilliseconds(receiveTimeout)
        guard connectMilliseconds > 0, sendMilliseconds > 0, receiveMilliseconds > 0 else {
            throw WindowsNativeHTTPError.invalidRequest
        }

        var response = Data(count: maximumResponseBytes)
        var responseLength: Int32 = 0
        var statusCode: Int32 = 0
        var errorCode: UInt32 = 0

        let succeeded: Int32 = url.withCString { urlPointer in
            method.withCString { methodPointer in
                headerBlock.withCString { headerPointer in
                    response.withUnsafeMutableBytes { responseBuffer in
                        let output = responseBuffer.bindMemory(to: UInt8.self).baseAddress
                        if let body {
                            return body.withUnsafeBytes { requestBuffer in
                                win_native_http_request(
                                    urlPointer, methodPointer, headerPointer,
                                    requestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                    Int32(body.count),
                                    connectMilliseconds, sendMilliseconds, receiveMilliseconds,
                                    output, Int32(maximumResponseBytes),
                                    &responseLength, &statusCode, &errorCode
                                )
                            }
                        }
                        return win_native_http_request(
                            urlPointer, methodPointer, headerPointer,
                            nil, 0,
                            connectMilliseconds, sendMilliseconds, receiveMilliseconds,
                            output, Int32(maximumResponseBytes),
                            &responseLength, &statusCode, &errorCode
                        )
                    }
                }
            }
        }
        guard succeeded != 0 else { throw WindowsNativeHTTPError.transport(errorCode) }
        guard responseLength >= 0 && Int(responseLength) <= response.count else {
            throw WindowsNativeHTTPError.invalidRequest
        }
        response.count = Int(responseLength)
        return WindowsNativeHTTPResponse(statusCode: Int(statusCode), body: response)
    }

    private static func timeoutMilliseconds(_ seconds: TimeInterval) -> Int32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int32(clamping: Int64((seconds * 1_000).rounded(.up)))
    }
}
#endif
