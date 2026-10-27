// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <sddl.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define CLIENTS 8
#define MAX_REQUEST (1024 * 1024)
#define MAX_RESPONSE (32 * 1024 * 1024)
#define REQUEST_MESSAGE (WM_APP + 71)
#define CLOSE_MESSAGE (WM_APP + 72)
typedef struct Request {
    LONG refs;
    CRITICAL_SECTION lock;
    HANDLE ready;
    char *line, *response, *timeout_response;
    size_t length, response_length;
    int state, close_window;
} Request;
typedef struct Server Server;
typedef struct Worker {
    Server *server;
    HANDLE pipe, thread;
} Worker;
struct Server {
    HANDLE stop;
    HWND window;
    Worker workers[CLIENTS];
    void *context;
    void (*dispatch)(void *, Request *, const char *, size_t);
    void (*close_window)(void *);
};
void turf_pipe_release(Request *r) {
    if (InterlockedDecrement(&r->refs))
        return;
    CloseHandle(r->ready);
    DeleteCriticalSection(&r->lock);
    free(r->line);
    free(r->response);
    free(r->timeout_response);
    free(r);
}
void turf_pipe_timeout_response(Request *r, const char *data, size_t length) {
    char *copy = malloc(length + 1);
    if (!copy)
        return;
    memcpy(copy, data, length);
    copy[length] = 0;
    EnterCriticalSection(&r->lock);
    free(r->timeout_response);
    r->timeout_response = copy;
    LeaveCriticalSection(&r->lock);
}
int turf_pipe_pending(Request *r) {
    EnterCriticalSection(&r->lock);
    int pending = r->state == 0;
    LeaveCriticalSection(&r->lock);
    return pending;
}
void turf_pipe_reply(Request *r, const char *data, size_t length, int close_window) {
    if (length > MAX_RESPONSE)
        return;
    char *copy = malloc(length + 1);
    if (!copy)
        return;
    memcpy(copy, data, length);
    copy[length] = '\n';
    EnterCriticalSection(&r->lock);
    if (!r->state) {
        r->response = copy;
        r->response_length = length + 1;
        r->close_window = close_window;
        r->state = 1;
        SetEvent(r->ready);
    } else
        free(copy);
    LeaveCriticalSection(&r->lock);
}
static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    Server *s = (Server *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (s && message == REQUEST_MESSAGE) {
        Request *r = (Request *)l;
        if (turf_pipe_pending(r))
            s->dispatch(s->context, r, r->line, r->length);
        else
            turf_pipe_release(r);
        return 0;
    }
    if (s && message == CLOSE_MESSAGE) {
        s->close_window(s->context);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
static BOOL finish_io(Worker *w, OVERLAPPED *io, DWORD *bytes, DWORD timeout) {
    HANDLE events[] = {w->server->stop, io->hEvent};
    DWORD result = WaitForMultipleObjects(2, events, FALSE, timeout);
    if (result != WAIT_OBJECT_0 + 1) {
        CancelIoEx(w->pipe, io);
        GetOverlappedResult(w->pipe, io, bytes, TRUE);
        return FALSE;
    }
    return GetOverlappedResult(w->pipe, io, bytes, FALSE);
}
static BOOL transfer(Worker *w, void *data, DWORD length, DWORD *bytes, BOOL writing) {
    OVERLAPPED io = {0};
    io.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!io.hEvent)
        return FALSE;
    BOOL ok = writing ? WriteFile(w->pipe, data, length, bytes, &io)
                      : ReadFile(w->pipe, data, length, bytes, &io);
    if (!ok && GetLastError() == ERROR_IO_PENDING)
        ok = finish_io(w, &io, bytes, writing ? 30000 : 10000);
    CloseHandle(io.hEvent);
    return ok;
}
static BOOL write_all(Worker *w, const char *data, size_t length) {
    while (length) {
        DWORD count = 0;
        if (!transfer(w, (void *)data, (DWORD)length, &count, TRUE) || !count)
            return FALSE;
        data += count;
        length -= count;
    }
    return TRUE;
}
static VOID CALLBACK cancel_drain(void *data, BOOLEAN fired) {
    (void)fired;
    Worker *w = data;
    CancelSynchronousIo(w->thread);
}
static BOOL drain_reply(Worker *w) {
    if (WaitForSingleObject(w->server->stop, 0) != WAIT_TIMEOUT)
        return FALSE;
    HANDLE timer = NULL;
    if (!CreateTimerQueueTimer(&timer, NULL, cancel_drain, w, 30000, 0, WT_EXECUTEONLYONCE))
        return FALSE;
    // DisconnectNamedPipe discards unread bytes. Let the client consume a final
    // reply before disconnecting; cancellation bounds an unresponsive client.
    BOOL ok = FlushFileBuffers(w->pipe);
    DeleteTimerQueueTimer(NULL, timer, INVALID_HANDLE_VALUE);
    return ok;
}
static BOOL process_line(Worker *w, const char *line, size_t length) {
    Request *r = calloc(1, sizeof(*r));
    if (!r)
        return FALSE;
    r->refs = 2;
    InitializeCriticalSection(&r->lock);
    r->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    r->line = malloc(length + 1);
    r->length = length;
    if (!r->ready || !r->line) {
        turf_pipe_release(r);
        turf_pipe_release(r);
        return FALSE;
    }
    memcpy(r->line, line, length);
    r->line[length] = 0;
    if (!PostMessageW(w->server->window, REQUEST_MESSAGE, 0, (LPARAM)r)) {
        turf_pipe_release(r);
        turf_pipe_release(r);
        return FALSE;
    }
    HANDLE events[] = {w->server->stop, r->ready};
    DWORD result = WaitForMultipleObjects(2, events, FALSE, 30000);
    EnterCriticalSection(&r->lock);
    if (!r->state) {
        r->state = 2;
        const char *fallback = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,"
                               "\"message\":\"Request timed out\"}}";
        const char *json = r->timeout_response ? r->timeout_response : fallback;
        size_t n = strlen(json);
        r->response = malloc(n + 1);
        if (r->response) {
            memcpy(r->response, json, n);
            r->response[n] = '\n';
            r->response_length = n + 1;
        }
    }
    LeaveCriticalSection(&r->lock);
    BOOL ok =
        result != WAIT_OBJECT_0 && r->response && write_all(w, r->response, r->response_length);
    if (ok && r->close_window) {
        if (drain_reply(w))
            PostMessageW(w->server->window, CLOSE_MESSAGE, 0, 0);
        ok = FALSE;
    }
    turf_pipe_release(r);
    return ok;
}
static DWORD WINAPI worker_main(void *data) {
    Worker *w = data;
    char *buffer = malloc(MAX_REQUEST + 1);
    if (!buffer)
        return 0;
    while (WaitForSingleObject(w->server->stop, 0) == WAIT_TIMEOUT) {
        OVERLAPPED io = {0};
        io.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!io.hEvent)
            break;
        DWORD count = 0;
        BOOL connected = ConnectNamedPipe(w->pipe, &io);
        if (!connected) {
            DWORD error = GetLastError();
            if (error == ERROR_PIPE_CONNECTED)
                connected = TRUE;
            else if (error == ERROR_IO_PENDING)
                connected = finish_io(w, &io, &count, INFINITE);
        }
        CloseHandle(io.hEvent);
        if (!connected)
            break;
        size_t used = 0;
        for (;;) {
            char *newline = memchr(buffer, '\n', used);
            if (newline) {
                size_t length = (size_t)(newline - buffer);
                if (!process_line(w, buffer, length))
                    break;
                memmove(buffer, newline + 1, used - length - 1);
                used -= length + 1;
            } else if (used == MAX_REQUEST + 1) {
                const char *error = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,"
                                    "\"message\":\"Request exceeds 1 MiB\"}}\n";
                if (write_all(w, error, strlen(error)))
                    drain_reply(w);
                break;
            } else {
                count = 0;
                DWORD available = (DWORD)(MAX_REQUEST + 1 - used);
                if (available > 8192)
                    available = 8192;
                if (!transfer(w, buffer + used, available, &count, FALSE) || !count)
                    break;
                used += count;
            }
        }
        DisconnectNamedPipe(w->pipe);
    }
    free(buffer);
    return 0;
}
void turf_pipe_stop(Server *s) {
    if (!s)
        return;
    SetEvent(s->stop);
    for (int i = 0; i < CLIENTS; i++)
        if (s->workers[i].thread) {
            while (WaitForSingleObject(s->workers[i].thread, 50) == WAIT_TIMEOUT)
                CancelSynchronousIo(s->workers[i].thread);
            CloseHandle(s->workers[i].thread);
        }
    MSG message;
    if (s->window) {
        while (PeekMessageW(&message, s->window, REQUEST_MESSAGE, REQUEST_MESSAGE, PM_REMOVE))
            turf_pipe_release((Request *)message.lParam);
        DestroyWindow(s->window);
    }
    for (int i = 0; i < CLIENTS; i++)
        if (s->workers[i].pipe && s->workers[i].pipe != INVALID_HANDLE_VALUE)
            CloseHandle(s->workers[i].pipe);
    if (s->stop)
        CloseHandle(s->stop);
    free(s);
}
Server *turf_pipe_start(const wchar_t *name, void *context,
                        void (*dispatch)(void *, Request *, const char *, size_t),
                        void (*close_window)(void *)) {
    const wchar_t *prefix = L"\\\\.\\pipe\\";
    size_t length = wcslen(name);
    if (wcsncmp(name, prefix, 9) || length <= 9 || length > 240)
        return NULL;
    for (size_t i = 9; i < length; i++)
        if (name[i] < 33 || name[i] > 126 || name[i] == L'\\' || name[i] == L'/')
            return NULL;
    HANDLE token = NULL;
    DWORD needed = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
        return NULL;
    GetTokenInformation(token, TokenUser, NULL, 0, &needed);
    TOKEN_USER *user = malloc(needed);
    LPWSTR sid = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    BOOL ok = user && GetTokenInformation(token, TokenUser, user, needed, &needed) &&
              ConvertSidToStringSidW(user->User.Sid, &sid);
    CloseHandle(token);
    free(user);
    if (!ok)
        return NULL;
    wchar_t sddl[256];
    _snwprintf(sddl, 256, L"D:P(A;;GA;;;%ls)", sid);
    LocalFree(sid);
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &descriptor,
                                                              NULL))
        return NULL;
    SECURITY_ATTRIBUTES security = {sizeof(security), descriptor, FALSE};
    Server *s = calloc(1, sizeof(*s));
    if (!s) {
        LocalFree(descriptor);
        return NULL;
    }
    s->context = context;
    s->dispatch = dispatch;
    s->close_window = close_window;
    s->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!s->stop) {
        LocalFree(descriptor);
        free(s);
        return NULL;
    }
    for (int i = 0; i < CLIENTS; i++) {
        s->workers[i].server = s;
        s->workers[i].pipe = CreateNamedPipeW(name,
                                              PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
                                                  (i == 0 ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0),
                                              PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
                                                  PIPE_REJECT_REMOTE_CLIENTS,
                                              CLIENTS, 65536, 65536, 0, &security);
        if (s->workers[i].pipe == INVALID_HANDLE_VALUE) {
            LocalFree(descriptor);
            turf_pipe_stop(s);
            return NULL;
        }
    }
    LocalFree(descriptor);
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = window_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = L"TurfAutomationPipe";
    RegisterClassW(&cls);
    s->window = CreateWindowExW(0, cls.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL,
                                cls.hInstance, NULL);
    if (!s->window) {
        turf_pipe_stop(s);
        return NULL;
    }
    SetWindowLongPtrW(s->window, GWLP_USERDATA, (LONG_PTR)s);
    for (int i = 0; i < CLIENTS; i++) {
        s->workers[i].thread = CreateThread(NULL, 0, worker_main, &s->workers[i], 0, NULL);
        if (!s->workers[i].thread) {
            turf_pipe_stop(s);
            return NULL;
        }
    }
    return s;
}
