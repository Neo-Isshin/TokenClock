#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "include/winshim.h"

/*
 * Small, synchronous WinHTTP client used by the Swift Windows target.
 *
 * Network policy is deliberately explicit: no system proxy, no automatic
 * cookies or credentials, no redirects, and normal WinHTTP certificate/name
 * validation for HTTPS.  Callers run this function on their existing worker
 * queues; the Win32 message thread never blocks here.
 */

static wchar_t *native_http_utf8_to_wide(const char *value) {
    int count;
    wchar_t *wide;
    if (!value) return NULL;
    count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (count <= 0) return NULL;
    wide = (wchar_t *)calloc((size_t)count, sizeof(wchar_t));
    if (!wide) {
        SetLastError(ERROR_OUTOFMEMORY);
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, wide, count) <= 0) {
        free(wide);
        return NULL;
    }
    return wide;
}

static int native_http_fail(unsigned long *out_error, unsigned long error) {
    if (out_error) *out_error = error ? error : ERROR_GEN_FAILURE;
    return 0;
}

int win_native_http_request(const char *url_utf8,
                            const char *method_utf8,
                            const char *headers_utf8,
                            const unsigned char *request_body,
                            int request_body_length,
                            int connect_timeout_ms,
                            int send_timeout_ms,
                            int receive_timeout_ms,
                            unsigned char *response_body,
                            int response_capacity,
                            int *out_response_length,
                            int *out_status_code,
                            unsigned long *out_error) {
    wchar_t *url = NULL;
    wchar_t *method = NULL;
    wchar_t *headers = NULL;
    wchar_t host[256];
    wchar_t path[4096];
    wchar_t extra[4096];
    wchar_t username[2];
    wchar_t password[2];
    wchar_t object_name[8192];
    URL_COMPONENTS parts;
    HINTERNET session = NULL;
    HINTERNET connection = NULL;
    HINTERNET request = NULL;
    DWORD flags = 0;
    DWORD disable_flags;
    DWORD redirect_policy;
    DWORD auto_logon_policy;
    DWORD status_code = 0;
    DWORD status_size = sizeof(status_code);
    DWORD bytes_available = 0;
    DWORD bytes_read = 0;
    int used = 0;
    int ok = 0;
    unsigned long error = ERROR_SUCCESS;

    if (out_response_length) *out_response_length = 0;
    if (out_status_code) *out_status_code = 0;
    if (out_error) *out_error = ERROR_SUCCESS;

    if (!url_utf8 || !method_utf8 || request_body_length < 0 ||
        (request_body_length > 0 && !request_body) ||
        !response_body || response_capacity <= 0 ||
        !out_response_length || !out_status_code) {
        return native_http_fail(out_error, ERROR_INVALID_PARAMETER);
    }
    if (request_body_length > INT_MAX ||
        connect_timeout_ms <= 0 || send_timeout_ms <= 0 || receive_timeout_ms <= 0) {
        return native_http_fail(out_error, ERROR_INVALID_PARAMETER);
    }

    url = native_http_utf8_to_wide(url_utf8);
    method = native_http_utf8_to_wide(method_utf8);
    if (!url || !method) {
        error = GetLastError();
        goto cleanup;
    }
    if (headers_utf8 && headers_utf8[0]) {
        headers = native_http_utf8_to_wide(headers_utf8);
        if (!headers) {
            error = GetLastError();
            goto cleanup;
        }
    }
    if (_wcsicmp(method, L"GET") != 0 && _wcsicmp(method, L"POST") != 0) {
        error = ERROR_INVALID_PARAMETER;
        goto cleanup;
    }

    ZeroMemory(&parts, sizeof(parts));
    ZeroMemory(host, sizeof(host));
    ZeroMemory(path, sizeof(path));
    ZeroMemory(extra, sizeof(extra));
    ZeroMemory(username, sizeof(username));
    ZeroMemory(password, sizeof(password));
    parts.dwStructSize = sizeof(parts);
    parts.lpszHostName = host;
    parts.dwHostNameLength = (DWORD)(sizeof(host) / sizeof(host[0]));
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = (DWORD)(sizeof(path) / sizeof(path[0]));
    parts.lpszExtraInfo = extra;
    parts.dwExtraInfoLength = (DWORD)(sizeof(extra) / sizeof(extra[0]));
    parts.lpszUserName = username;
    parts.dwUserNameLength = (DWORD)(sizeof(username) / sizeof(username[0]));
    parts.lpszPassword = password;
    parts.dwPasswordLength = (DWORD)(sizeof(password) / sizeof(password[0]));
    if (!WinHttpCrackUrl(url, 0, 0, &parts)) {
        error = GetLastError();
        goto cleanup;
    }
    if ((parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS) ||
        parts.dwHostNameLength == 0 || parts.dwUserNameLength != 0 || parts.dwPasswordLength != 0) {
        error = ERROR_INVALID_PARAMETER;
        goto cleanup;
    }
    if (parts.dwUrlPathLength + parts.dwExtraInfoLength + 1 >=
        (DWORD)(sizeof(object_name) / sizeof(object_name[0]))) {
        error = ERROR_INSUFFICIENT_BUFFER;
        goto cleanup;
    }
    object_name[0] = L'\0';
    if (parts.dwUrlPathLength == 0) {
        wcscpy_s(object_name, sizeof(object_name) / sizeof(object_name[0]), L"/");
    } else {
        wcscpy_s(object_name, sizeof(object_name) / sizeof(object_name[0]), path);
    }
    if (parts.dwExtraInfoLength > 0) {
        wcscat_s(object_name, sizeof(object_name) / sizeof(object_name[0]), extra);
    }

    session = WinHttpOpen(L"TokenClock/1.4 Windows",
                          WINHTTP_ACCESS_TYPE_NO_PROXY,
                          WINHTTP_NO_PROXY_NAME,
                          WINHTTP_NO_PROXY_BYPASS,
                          0);
    if (!session) {
        error = GetLastError();
        goto cleanup;
    }
    if (!WinHttpSetTimeouts(session, connect_timeout_ms, connect_timeout_ms,
                            send_timeout_ms, receive_timeout_ms)) {
        error = GetLastError();
        goto cleanup;
    }

    connection = WinHttpConnect(session, host, parts.nPort, 0);
    if (!connection) {
        error = GetLastError();
        goto cleanup;
    }
    if (parts.nScheme == INTERNET_SCHEME_HTTPS) flags |= WINHTTP_FLAG_SECURE;
    request = WinHttpOpenRequest(connection, method, object_name, NULL,
                                 WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        error = GetLastError();
        goto cleanup;
    }

    /* Antigravity exposes its authenticated quota RPC over a self-signed HTTPS
       loopback endpoint. Relax certificate checks only for localhost; public
       HTTPS requests retain normal WinHTTP validation. */
    if (parts.nScheme == INTERNET_SCHEME_HTTPS &&
        (_wcsicmp(host, L"127.0.0.1") == 0 || _wcsicmp(host, L"localhost") == 0 ||
         _wcsicmp(host, L"::1") == 0)) {
        DWORD security_flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA |
                               SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                               SECURITY_FLAG_IGNORE_CERT_DATE_INVALID |
                               SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
        if (!WinHttpSetOption(request, WINHTTP_OPTION_SECURITY_FLAGS,
                              &security_flags, sizeof(security_flags))) {
            error = GetLastError();
            goto cleanup;
        }
    }

    disable_flags = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS |
                    WINHTTP_DISABLE_AUTHENTICATION;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE,
                          &disable_flags, sizeof(disable_flags))) {
        error = GetLastError();
        goto cleanup;
    }
    redirect_policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_REDIRECT_POLICY,
                          &redirect_policy, sizeof(redirect_policy))) {
        error = GetLastError();
        goto cleanup;
    }
    auto_logon_policy = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_AUTOLOGON_POLICY,
                          &auto_logon_policy, sizeof(auto_logon_policy))) {
        error = GetLastError();
        goto cleanup;
    }
    if (headers && !WinHttpAddRequestHeaders(request, headers, (DWORD)-1L,
                                              WINHTTP_ADDREQ_FLAG_ADD |
                                              WINHTTP_ADDREQ_FLAG_REPLACE)) {
        error = GetLastError();
        goto cleanup;
    }

    if (!WinHttpSendRequest(request,
                            WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            request_body_length > 0 ? (LPVOID)request_body : WINHTTP_NO_REQUEST_DATA,
                            (DWORD)request_body_length,
                            (DWORD)request_body_length,
                            0)) {
        error = GetLastError();
        goto cleanup;
    }
    if (!WinHttpReceiveResponse(request, NULL)) {
        error = GetLastError();
        goto cleanup;
    }
    if (!WinHttpQueryHeaders(request,
                             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX,
                             &status_code, &status_size, WINHTTP_NO_HEADER_INDEX)) {
        error = GetLastError();
        goto cleanup;
    }

    for (;;) {
        if (!WinHttpQueryDataAvailable(request, &bytes_available)) {
            error = GetLastError();
            goto cleanup;
        }
        if (bytes_available == 0) break;
        if (bytes_available > (DWORD)(response_capacity - used)) {
            error = ERROR_INSUFFICIENT_BUFFER;
            goto cleanup;
        }
        bytes_read = 0;
        if (!WinHttpReadData(request, response_body + used, bytes_available, &bytes_read)) {
            error = GetLastError();
            goto cleanup;
        }
        if (bytes_read == 0) break;
        used += (int)bytes_read;
    }

    *out_response_length = used;
    *out_status_code = (int)status_code;
    ok = 1;

cleanup:
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    if (session) WinHttpCloseHandle(session);
    free(headers);
    free(method);
    free(url);
    if (!ok) return native_http_fail(out_error, error ? error : GetLastError());
    return 1;
}
