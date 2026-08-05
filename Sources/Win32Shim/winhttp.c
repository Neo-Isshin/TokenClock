/* winhttp.c — 轻量 loopback HTTP 服务（Winsock2），保持 /api/usage 与 /api/history 跨平台兼容。
 * 后台线程绑定 127.0.0.1:port；每个 GET 经 responder 回调取得 UTF-8 JSON 体后回送，
 * 非 GET ⇒ 405，responder 返回 -1 ⇒ 404。镜像 LinuxAPIServer（Glibc socket）的语义。 */
#define UNICODE
#define _UNICODE
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <string.h>
#include "winshim.h"

typedef struct {
    HANDLE            thread;
    SOCKET            listen_fd;
    volatile int      running;
    unsigned short    port;
    win_api_responder_t responder;
    void             *ctx;
} api_state;

static void send_all(SOCKET s, const char *data, int len) {
    int off = 0;
    while (off < len) {
        int n = send(s, data + off, len - off, 0);
        if (n <= 0) return;
        off += n;
    }
}

static void send_status(SOCKET s, int status, const char *reason) {
    char hdr[128];
    int n = snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\n"
                     "Content-Length: 0\r\nConnection: close\r\n\r\n", status, reason);
    send_all(s, hdr, n);
}

static void handle_client(SOCKET c, api_state *st) {
    char buf[8192];
    int got = recv(c, buf, (int)sizeof(buf) - 1, 0);
    if (got <= 0) return;
    buf[got] = '\0';

    /* first line: METHOD SP TARGET SP HTTP/... */
    char *eol = strstr(buf, "\r\n");
    if (eol) *eol = '\0';
    char method[16], target[1024];
    method[0] = target[0] = '\0';
    sscanf(buf, "%15s %1023s", method, target);
    if (strcmp(method, "GET") != 0) { send_status(c, 405, "Method Not Allowed"); return; }

    /* split target into path?query */
    char *q = strchr(target, '?');
    char path[1024], query[1024];
    if (q) {
        size_t pl = (size_t)(q - target);
        if (pl >= sizeof(path)) pl = sizeof(path) - 1;
        memcpy(path, target, pl); path[pl] = '\0';
        strncpy(query, q + 1, sizeof(query) - 1); query[sizeof(query) - 1] = '\0';
    } else {
        strncpy(path, target, sizeof(path) - 1); path[sizeof(path) - 1] = '\0';
        query[0] = '\0';
    }

    char body[65536];
    int blen = st->responder(st->ctx, path, query, body, (int)sizeof(body));
    if (blen < 0) { send_status(c, 404, "Not Found"); return; }
    if (blen > (int)sizeof(body) - 1) blen = (int)sizeof(body) - 1;

    char hdr[160];
    int hn = snprintf(hdr, sizeof(hdr),
                      "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
                      "Content-Length: %d\r\nConnection: close\r\n\r\n", blen);
    send_all(c, hdr, hn);
    send_all(c, body, blen);
}

static DWORD WINAPI api_thread(LPVOID arg) {
    api_state *st = (api_state *)arg;

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        printf("[API] WSAStartup failed\n");
        free(st);
        return 1;
    }

    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) { WSACleanup(); free(st); return 1; }

    BOOL reuse = TRUE;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (char *)&reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(st->port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (bind(s, (struct sockaddr *)&addr, (int)sizeof(addr)) == SOCKET_ERROR ||
        listen(s, 16) == SOCKET_ERROR) {
        printf("[API] Unable to bind 127.0.0.1:%d\n", st->port);
        closesocket(s);
        WSACleanup();
        free(st);
        return 1;
    }
    st->listen_fd = s;
    printf("[API] Server ready on 127.0.0.1:%d\n", st->port);

    while (st->running) {
        SOCKET c = accept(s, NULL, NULL);
        if (c == INVALID_SOCKET) {
            if (st->running) continue;
            break;
        }
        handle_client(c, st);
        closesocket(c);
    }

    closesocket(s);
    WSACleanup();
    free(st);
    return 0;
}

void *win_start_api_server(unsigned short port, win_api_responder_t responder, void *ctx) {
    if (!responder) return NULL;
    api_state *st = (api_state *)calloc(1, sizeof(api_state));
    if (!st) return NULL;
    st->port = port;
    st->responder = responder;
    st->ctx = ctx;
    st->running = 1;
    st->listen_fd = INVALID_SOCKET;

    HANDLE t = CreateThread(NULL, 0, api_thread, st, 0, NULL);
    if (!t) { free(st); return NULL; }
    st->thread = t;
    return st;
}

void win_stop_api_server(void *handle) {
    if (!handle) return;
    api_state *st = (api_state *)handle;
    HANDLE t = st->thread;          /* capture before the worker can free `st` */
    st->running = 0;
    if (st->listen_fd != INVALID_SOCKET) {
        /* closesocket reliably unblocks a worker blocked in accept() on Windows */
        closesocket(st->listen_fd);
    }
    if (t) {
        WaitForSingleObject(t, 2000);
        CloseHandle(t);
    }
    /* `st` is freed by api_thread on its exit path — do not free here. If the wait
     * timed out the worker is still alive and still owns `st`. */
}
