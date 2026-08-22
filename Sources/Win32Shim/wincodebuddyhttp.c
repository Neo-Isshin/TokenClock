/* Strict CodeBuddy loopback HTTP client.
 *
 * This deliberately uses Winsock rather than FoundationNetworking, WinINet or a system proxy.
 * The peer is hard-coded to IPv4 127.0.0.1 and the caller can select only the two documented
 * CodeBuddy statistics routes. The entire connect/send/receive operation shares one deadline. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "winshim.h"

#define CB_MAX_HEADER 16384
#define CB_MAX_BODY   (1024 * 1024)

typedef struct {
    int http10;
    int has_content_length;
    size_t content_length;
    int connection_close;
    int connection_keep_alive;
} cb_response_meta;

static int cb_remaining_ms(ULONGLONG deadline) {
    ULONGLONG now = GetTickCount64();
    ULONGLONG remaining;
    if (now >= deadline) return 0;
    remaining = deadline - now;
    return remaining > (ULONGLONG)INT_MAX ? INT_MAX : (int)remaining;
}

static int cb_wait_socket(SOCKET socket_fd, int writable, ULONGLONG deadline) {
    fd_set ready;
    fd_set errors;
    struct timeval timeout;
    int milliseconds = cb_remaining_ms(deadline);
    int selected;
    if (milliseconds <= 0) return 0;
    FD_ZERO(&ready);
    FD_ZERO(&errors);
    FD_SET(socket_fd, &ready);
    FD_SET(socket_fd, &errors);
    timeout.tv_sec = milliseconds / 1000;
    timeout.tv_usec = (milliseconds % 1000) * 1000;
    selected = select(0, writable ? NULL : &ready, writable ? &ready : NULL, &errors, &timeout);
    if (selected <= 0) return selected;
    if (FD_ISSET(socket_fd, &errors)) return -1;
    return FD_ISSET(socket_fd, &ready) ? 1 : -1;
}

static int cb_send_all(SOCKET socket_fd, const char *bytes, int length, ULONGLONG deadline) {
    int offset = 0;
    while (offset < length) {
        int sent;
        int wait_result = cb_wait_socket(socket_fd, 1, deadline);
        if (wait_result <= 0) return 0;
        sent = send(socket_fd, bytes + offset, length - offset, 0);
        if (sent > 0) {
            offset += sent;
            continue;
        }
        if (sent == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) continue;
        return 0;
    }
    return 1;
}

static int cb_find_header_end(const unsigned char *bytes, int length) {
    int index;
    for (index = 0; index + 3 < length; index++) {
        if (bytes[index] == '\r' && bytes[index + 1] == '\n' &&
            bytes[index + 2] == '\r' && bytes[index + 3] == '\n') {
            return index + 4;
        }
    }
    return -1;
}

static int cb_header_name_char(unsigned char byte) {
    if (isalnum(byte)) return 1;
    return strchr("!#$%&'*+-.^_`|~", byte) != NULL;
}

static int cb_name_equals(const unsigned char *name, size_t length, const char *expected) {
    size_t expected_length = strlen(expected);
    return length == expected_length && _strnicmp((const char *)name, expected, length) == 0;
}

static int cb_value_has_token(const unsigned char *value, size_t length, const char *token) {
    size_t cursor = 0;
    size_t token_length = strlen(token);
    while (cursor < length) {
        size_t start;
        size_t end;
        while (cursor < length && (value[cursor] == ' ' || value[cursor] == '\t' || value[cursor] == ',')) cursor++;
        start = cursor;
        while (cursor < length && value[cursor] != ',') cursor++;
        end = cursor;
        while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t')) end--;
        if (end - start == token_length && _strnicmp((const char *)value + start, token, token_length) == 0) return 1;
    }
    return 0;
}

static int cb_parse_content_length(const unsigned char *value, size_t length, size_t *out) {
    size_t result = 0;
    size_t index;
    if (length == 0) return 0;
    for (index = 0; index < length; index++) {
        unsigned int digit;
        if (value[index] < '0' || value[index] > '9') return 0;
        digit = (unsigned int)(value[index] - '0');
        if (result > (SIZE_MAX - digit) / 10) return 0;
        result = result * 10 + digit;
    }
    *out = result;
    return 1;
}

static int cb_parse_headers(const unsigned char *bytes, int header_end, cb_response_meta *meta) {
    int separator_start = header_end - 4;
    int status_end = -1;
    int cursor;
    int index;
    int status;
    memset(meta, 0, sizeof(*meta));

    for (index = 0; index + 1 < header_end; index++) {
        if (bytes[index] == 0 || (bytes[index] == '\n' && (index == 0 || bytes[index - 1] != '\r'))) return 0;
        if (bytes[index] == '\r' && bytes[index + 1] == '\n') {
            status_end = index;
            break;
        }
    }
    if (status_end < 12) return 0;
    if (memcmp(bytes, "HTTP/1.0", 8) == 0) meta->http10 = 1;
    else if (memcmp(bytes, "HTTP/1.1", 8) != 0) return 0;
    if (bytes[8] != ' ' || !isdigit(bytes[9]) || !isdigit(bytes[10]) || !isdigit(bytes[11])) return 0;
    if (status_end > 12 && bytes[12] != ' ') return 0;
    status = (bytes[9] - '0') * 100 + (bytes[10] - '0') * 10 + (bytes[11] - '0');
    if (status < 200 || status > 299) return 0;

    cursor = status_end + 2;
    while (cursor < header_end - 2) {
        int line_end = -1;
        int colon = -1;
        int value_start;
        int value_end;
        size_t parsed_length;
        for (index = cursor; index + 1 < header_end; index++) {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n') {
                line_end = index;
                break;
            }
            if (bytes[index] == 0 || bytes[index] == '\n' || bytes[index] == '\r') return 0;
        }
        if (line_end < cursor || line_end > separator_start) return 0;
        if (line_end == cursor || bytes[cursor] == ' ' || bytes[cursor] == '\t') return 0;
        for (index = cursor; index < line_end; index++) {
            if (bytes[index] == ':' && colon < 0) colon = index;
            else if (colon < 0 && !cb_header_name_char(bytes[index])) return 0;
            else if (colon >= 0 && bytes[index] != '\t' && (bytes[index] < 0x20 || bytes[index] > 0x7e)) return 0;
        }
        if (colon <= cursor) return 0;
        value_start = colon + 1;
        while (value_start < line_end && (bytes[value_start] == ' ' || bytes[value_start] == '\t')) value_start++;
        value_end = line_end;
        while (value_end > value_start && (bytes[value_end - 1] == ' ' || bytes[value_end - 1] == '\t')) value_end--;

        if (cb_name_equals(bytes + cursor, (size_t)(colon - cursor), "Content-Length")) {
            if (!cb_parse_content_length(bytes + value_start, (size_t)(value_end - value_start), &parsed_length)) return 0;
            if (parsed_length > CB_MAX_BODY) return 0;
            if (meta->has_content_length && meta->content_length != parsed_length) return 0;
            meta->has_content_length = 1;
            meta->content_length = parsed_length;
        } else if (cb_name_equals(bytes + cursor, (size_t)(colon - cursor), "Transfer-Encoding")) {
            return 0;
        } else if (cb_name_equals(bytes + cursor, (size_t)(colon - cursor), "Connection")) {
            if (cb_value_has_token(bytes + value_start, (size_t)(value_end - value_start), "close")) meta->connection_close = 1;
            if (cb_value_has_token(bytes + value_start, (size_t)(value_end - value_start), "keep-alive")) meta->connection_keep_alive = 1;
        }
        cursor = line_end + 2;
    }
    return cursor == header_end - 2;
}

static int cb_receive_response(SOCKET socket_fd, unsigned char *out, int out_capacity, ULONGLONG deadline) {
    unsigned char header[CB_MAX_HEADER];
    unsigned char chunk[8192];
    int header_size = 0;
    int header_end = -1;
    int body_size = 0;
    cb_response_meta meta;

    while (header_end < 0) {
        int received;
        int wait_result = cb_wait_socket(socket_fd, 0, deadline);
        if (wait_result <= 0) return -1;
        if (header_size >= CB_MAX_HEADER) return -1;
        received = recv(socket_fd, (char *)header + header_size, CB_MAX_HEADER - header_size, 0);
        if (received == 0) return -1;
        if (received == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEWOULDBLOCK) continue;
            return -1;
        }
        header_size += received;
        header_end = cb_find_header_end(header, header_size);
    }

    if (!cb_parse_headers(header, header_end, &meta)) return -1;
    body_size = header_size - header_end;
    if (body_size > out_capacity || body_size > CB_MAX_BODY) return -1;
    if (meta.has_content_length && (size_t)body_size > meta.content_length) return -1;
    if (body_size > 0) memcpy(out, header + header_end, (size_t)body_size);

    if (meta.has_content_length) {
        while ((size_t)body_size < meta.content_length) {
            int received;
            int wait_result = cb_wait_socket(socket_fd, 0, deadline);
            if (wait_result <= 0) return -1;
            received = recv(socket_fd, (char *)chunk, (int)sizeof(chunk), 0);
            if (received == 0) return -1;
            if (received == SOCKET_ERROR) {
                if (WSAGetLastError() == WSAEWOULDBLOCK) continue;
                return -1;
            }
            if ((size_t)received > meta.content_length - (size_t)body_size) return -1;
            if (received > out_capacity - body_size || body_size + received > CB_MAX_BODY) return -1;
            memcpy(out + body_size, chunk, (size_t)received);
            body_size += received;
        }
        return body_size;
    }

    if (!meta.connection_close && !(meta.http10 && !meta.connection_keep_alive)) return -1;
    for (;;) {
        int received;
        int wait_result = cb_wait_socket(socket_fd, 0, deadline);
        if (wait_result <= 0) return -1;
        received = recv(socket_fd, (char *)chunk, (int)sizeof(chunk), 0);
        if (received == 0) return body_size;
        if (received == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEWOULDBLOCK) continue;
            return -1;
        }
        if (received > out_capacity - body_size || body_size + received > CB_MAX_BODY) return -1;
        memcpy(out + body_size, chunk, (size_t)received);
        body_size += received;
    }
}

int win_codebuddy_http_get(unsigned short port, int route, unsigned char *out,
                           int out_capacity, int timeout_ms) {
    static const char *paths[] = { "/api/v1/stats", "/api/v1/stats/session" };
    WSADATA wsa;
    SOCKET socket_fd = INVALID_SOCKET;
    struct sockaddr_in address;
    u_long nonblocking = 1;
    ULONGLONG deadline;
    char request[512];
    int request_length;
    int result = -1;

    if (!out || out_capacity <= 0 || out_capacity > CB_MAX_BODY || port == 0 ||
        timeout_ms <= 0 || timeout_ms > 800 || route < WIN_CODEBUDDY_STATS || route > WIN_CODEBUDDY_SESSION_STATS) {
        return -1;
    }
    deadline = GetTickCount64() + (ULONGLONG)timeout_ms;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return -1;

    socket_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket_fd == INVALID_SOCKET) goto cleanup;
    if (ioctlsocket(socket_fd, FIONBIO, &nonblocking) == SOCKET_ERROR) goto cleanup;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(socket_fd, (struct sockaddr *)&address, (int)sizeof(address)) == SOCKET_ERROR) {
        int connect_error = WSAGetLastError();
        int socket_error = 0;
        int socket_error_size = (int)sizeof(socket_error);
        if (connect_error != WSAEWOULDBLOCK && connect_error != WSAEINPROGRESS && connect_error != WSAEALREADY) goto cleanup;
        if (cb_wait_socket(socket_fd, 1, deadline) <= 0) goto cleanup;
        if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, (char *)&socket_error, &socket_error_size) == SOCKET_ERROR || socket_error != 0) goto cleanup;
    }

    request_length = snprintf(request, sizeof(request),
        "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nX-CodeBuddy-Request: 1\r\n"
        "Accept: application/json\r\nConnection: close\r\n\r\n",
        paths[route], (unsigned int)port);
    if (request_length <= 0 || request_length >= (int)sizeof(request)) goto cleanup;
    if (!cb_send_all(socket_fd, request, request_length, deadline)) goto cleanup;
    result = cb_receive_response(socket_fd, out, out_capacity, deadline);

cleanup:
    if (socket_fd != INVALID_SOCKET) closesocket(socket_fd);
    WSACleanup();
    return result;
}
