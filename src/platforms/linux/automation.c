// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
#define _GNU_SOURCE
#include "automation.h"
#include <X11/XKBlib.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <dlfcn.h>
#include <errno.h>
#include <gdk/x11/gdkx.h>
#include <gio/gunixsocketaddress.h>
#include <gtk/gtk.h>
#include <jsc/jsc.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <webkit/webkit.h>

#define MAX_REQUEST (1024 * 1024)
#define MAX_RESPONSE (32 * 1024 * 1024)
typedef struct Server Server;
typedef struct Client Client;
typedef struct Request Request;
struct Server {
    int refs;
    gboolean stopped, background;
    WebKitWebView *view;
    GtkWindow *window;
    JSCContext *json;
    GSocketService *service;
    GList *clients;
    char *path;
    ino_t inode;
    dev_t device;
    Request *navigation;
    gulong load_handler, fail_handler;
};
struct Client {
    int refs;
    Server *server;
    GSocketConnection *connection;
    GCancellable *cancel;
    GByteArray *input;
    char *output;
    gboolean busy, closed, close_window, close_after_write;
    Request *request;
    guint deadline;
};
struct Request {
    int refs;
    Client *client;
    JSCValue *id;
    gboolean done;
    guint timeout;
};
static Server *server;
static void client_close(Client *c);
static void client_next(Client *c);
static void reply(Request *r, JSCValue *value, int code, const char *message);

static Server *server_ref(Server *s) {
    s->refs++;
    return s;
}
static void server_unref(Server *s) {
    if (--s->refs)
        return;
    g_clear_object(&s->service);
    g_clear_object(&s->view);
    g_clear_object(&s->window);
    g_object_unref(s->json);
    g_free(s->path);
    g_free(s);
}
static Client *client_ref(Client *c) {
    c->refs++;
    return c;
}
static void client_unref(gpointer data) {
    Client *c = data;
    if (--c->refs)
        return;
    g_object_unref(c->connection);
    g_object_unref(c->cancel);
    g_byte_array_unref(c->input);
    g_free(c->output);
    server_unref(c->server);
    g_free(c);
}
static Request *request_ref(Request *r) {
    r->refs++;
    return r;
}
static void request_unref(gpointer data) {
    Request *r = data;
    if (--r->refs)
        return;
    g_clear_object(&r->id);
    client_unref(r->client);
    g_free(r);
}
static void clear_timer(guint *timer) {
    if (*timer) {
        g_source_remove(*timer);
        *timer = 0;
    }
}
static gboolean idle_timeout(gpointer data) {
    Client *c = data;
    c->deadline = 0;
    client_close(c);
    return G_SOURCE_REMOVE;
}
static void deadline(Client *c, guint seconds) {
    clear_timer(&c->deadline);
    c->deadline = g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, seconds, idle_timeout,
                                             client_ref(c), client_unref);
}
static void client_close(Client *c) {
    if (c->closed)
        return;
    c->closed = TRUE;
    if (c->request) {
        Request *r = request_ref(c->request);
        c->request = NULL;
        r->done = TRUE;
        clear_timer(&r->timeout);
        if (c->server->navigation == r) {
            c->server->navigation = NULL;
            request_unref(r);
        }
        request_unref(r);
    }
    clear_timer(&c->deadline);
    g_cancellable_cancel(c->cancel);
    g_io_stream_close(G_IO_STREAM(c->connection), NULL, NULL);
    c->server->clients = g_list_remove(c->server->clients, c);
    client_unref(c); // server's list ownership
}
static JSCValue *object(Server *s) { return jsc_value_new_object(s->json, NULL, NULL); }
static void put(JSCValue *o, const char *name, JSCValue *v) {
    jsc_value_object_set_property(o, name, v);
    g_object_unref(v);
}
static void string(JSCValue *o, const char *name, const char *v) {
    put(o, name, jsc_value_new_string(jsc_value_get_context(o), v ? v : ""));
}
static void number(JSCValue *o, const char *name, double v) {
    put(o, name, jsc_value_new_number(jsc_value_get_context(o), v));
}
static void boolean(JSCValue *o, const char *name, gboolean v) {
    put(o, name, jsc_value_new_boolean(jsc_value_get_context(o), v));
}
static char *get_string(JSCValue *o, const char *name) {
    JSCValue *v = jsc_value_object_get_property(o, name);
    char *result = NULL;
    if (jsc_value_is_string(v)) {
        GBytes *bytes = jsc_value_to_string_as_bytes(v);
        gsize length = 0;
        const char *data = g_bytes_get_data(bytes, &length);
        // C/WebKit string APIs cannot represent embedded NUL characters.
        if (!length || !memchr(data, 0, length))
            result = g_strndup(data ? data : "", length);
        g_bytes_unref(bytes);
    }
    g_object_unref(v);
    return result;
}
static gboolean get_number(JSCValue *o, const char *name, double *out) {
    JSCValue *v = jsc_value_object_get_property(o, name);
    gboolean valid = jsc_value_is_number(v);
    if (valid) {
        *out = jsc_value_to_double(v);
        valid = isfinite(*out);
    }
    g_object_unref(v);
    return valid;
}
static void written(GObject *source, GAsyncResult *result, gpointer data) {
    Client *c = data;
    GError *error = NULL;
    gboolean ok = g_output_stream_write_all_finish(G_OUTPUT_STREAM(source), result, NULL, &error);
    g_clear_error(&error);
    g_clear_pointer(&c->output, g_free);
    if (!c->closed) {
        if (!ok || c->close_after_write)
            client_close(c);
        else if (c->close_window) {
            GtkWindow *window = g_object_ref(c->server->window);
            turf_linux_automation_stop();
            gtk_window_close(window);
            g_object_unref(window);
        } else {
            c->busy = FALSE;
            deadline(c, 10);
            client_next(c);
        }
    }
    client_unref(c);
}
// The caller retains value. A timed-out request cannot reply to a later request.
static void reply(Request *r, JSCValue *value, int code, const char *message) {
    if (r->done)
        return;
    r->done = TRUE;
    r->client->request = NULL;
    clear_timer(&r->timeout);
    Client *c = r->client;
    Server *s = c->server;
    if (c->closed || s->stopped)
        return;
    JSCValue *response = object(s);
    string(response, "jsonrpc", "2.0");
    put(response, "id", r->id ? g_object_ref(r->id) : jsc_value_new_null(s->json));
    if (code) {
        JSCValue *error = object(s);
        number(error, "code", code);
        string(error, "message", message);
        put(response, "error", error);
    } else
        put(response, "result", value ? g_object_ref(value) : jsc_value_new_null(s->json));
    char *json = jsc_value_to_json(response, 0);
    g_object_unref(response);
    if (!json || strlen(json) > MAX_RESPONSE) {
        g_free(json);
        r->done = FALSE;
        reply(r, NULL, -32003, "Result cannot be serialized or exceeds 32 MiB");
        return;
    }
    c->output = g_strconcat(json, "\n", NULL);
    g_free(json);
    deadline(c, 30);
    g_output_stream_write_all_async(g_io_stream_get_output_stream(G_IO_STREAM(c->connection)),
                                    c->output, strlen(c->output), G_PRIORITY_DEFAULT, c->cancel,
                                    written, client_ref(c));
}
static gboolean request_timeout(gpointer data) {
    Request *r = data;
    r->timeout = 0;
    if (r->client->server->navigation == r) {
        r->client->server->navigation = NULL;
        request_unref(r); // navigation ownership; timeout still owns r
    }
    reply(r, NULL, -32001, "Request timed out; execution may still finish");
    return G_SOURCE_REMOVE;
}
static JSCValue *viewport(Server *s) {
    JSCValue *o = object(s);
    int width = gtk_widget_get_width(GTK_WIDGET(s->view)),
        height = gtk_widget_get_height(GTK_WIDGET(s->view));
    if (!gtk_widget_get_visible(GTK_WIDGET(s->window)))
        gtk_window_get_default_size(s->window, &width, &height);
    number(o, "width", width);
    number(o, "height", height);
    return o;
}
static void evaluated(GObject *source, GAsyncResult *result, gpointer data) {
    Request *r = data;
    GError *error = NULL;
    JSCValue *v = webkit_web_view_call_async_javascript_function_finish(WEBKIT_WEB_VIEW(source),
                                                                        result, &error);
    if (!r->done) {
        if (error)
            reply(r, NULL, -32002, error->message);
        else {
            char *json = v && jsc_value_is_string(v) ? jsc_value_to_string(v) : NULL;
            JSCValue *value = json ? jsc_value_new_from_json(r->client->server->json, json) : NULL;
            if (value)
                reply(r, value, 0, NULL);
            else
                reply(r, NULL, -32003, "JavaScript result cannot be serialized");
            g_clear_object(&value);
            g_free(json);
        }
    }
    g_clear_error(&error);
    g_clear_object(&v);
    request_unref(r);
}
static void snapshot(GObject *source, GAsyncResult *result, gpointer data) {
    Request *r = data;
    GError *error = NULL;
    GdkTexture *texture =
        webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(source), result, &error);
    if (!r->done) {
        if (!texture)
            reply(r, NULL, -32002, error ? error->message : "Snapshot failed");
        else {
            GBytes *png = gdk_texture_save_to_png_bytes(texture);
            gsize length;
            const void *bytes = g_bytes_get_data(png, &length);
            if (length > MAX_RESPONSE * 3 / 4 - 1024)
                reply(r, NULL, -32003, "Screenshot exceeds response limit");
            else {
                char *base64 = g_base64_encode(bytes, length);
                JSCValue *o = object(r->client->server);
                string(o, "format", "png");
                string(o, "data", base64);
                number(o, "width", gdk_texture_get_width(texture));
                number(o, "height", gdk_texture_get_height(texture));
                reply(r, o, 0, NULL);
                g_object_unref(o);
                g_free(base64);
            }
            g_bytes_unref(png);
        }
    }
    g_clear_object(&texture);
    g_clear_error(&error);
    request_unref(r);
}
static void load_changed(WebKitWebView *view, WebKitLoadEvent event, gpointer data) {
    Server *s = data;
    if (event != WEBKIT_LOAD_FINISHED || !s->navigation)
        return;
    Request *r = s->navigation;
    s->navigation = NULL;
    JSCValue *o = object(s);
    string(o, "url", webkit_web_view_get_uri(view));
    reply(r, o, 0, NULL);
    g_object_unref(o);
    request_unref(r);
}
static gboolean load_failed(WebKitWebView *view, WebKitLoadEvent event, const char *uri,
                            GError *error, gpointer data) {
    (void)view;
    (void)event;
    (void)uri;
    Server *s = data;
    if (s->navigation) {
        Request *r = s->navigation;
        s->navigation = NULL;
        reply(r, NULL, -32002, error->message);
        request_unref(r);
    }
    return FALSE;
}
static gboolean modifiers(JSCValue *params, unsigned int *state) {
    *state = 0;
    JSCValue *list = jsc_value_object_get_property(params, "modifiers");
    if (jsc_value_is_undefined(list)) {
        g_object_unref(list);
        return TRUE;
    }
    if (!jsc_value_is_array(list)) {
        g_object_unref(list);
        return FALSE;
    }
    JSCValue *length = jsc_value_object_get_property(list, "length");
    guint count = jsc_value_to_int32(length);
    g_object_unref(length);
    gboolean valid = count <= 16;
    for (guint i = 0; valid && i < count; i++) {
        JSCValue *v = jsc_value_object_get_property_at_index(list, i);
        char *name = jsc_value_is_string(v) ? jsc_value_to_string(v) : NULL;
        if (!name)
            valid = FALSE;
        else if (!strcmp(name, "shift"))
            *state |= ShiftMask;
        else if (!strcmp(name, "control"))
            *state |= ControlMask;
        else if (!strcmp(name, "alt"))
            *state |= Mod1Mask;
        else if (!strcmp(name, "meta"))
            *state |= Mod4Mask;
        else
            valid = FALSE;
        g_free(name);
        g_object_unref(v);
    }
    g_object_unref(list);
    return valid;
}
static void *xtest_library;
static int (*fake_motion)(Display *, int, int, int, unsigned long);
static int (*fake_button)(Display *, unsigned int, Bool, unsigned long);
static int (*fake_key)(Display *, unsigned int, Bool, unsigned long);
static gboolean xtest_available(Server *s) {
    if (!GDK_IS_X11_DISPLAY(gtk_widget_get_display(GTK_WIDGET(s->view))))
        return FALSE;
    if (!xtest_library) {
        xtest_library = dlopen("libXtst.so.6", RTLD_LAZY | RTLD_LOCAL);
        if (xtest_library) {
            fake_motion = dlsym(xtest_library, "XTestFakeMotionEvent");
            fake_button = dlsym(xtest_library, "XTestFakeButtonEvent");
            fake_key = dlsym(xtest_library, "XTestFakeKeyEvent");
        }
    }
    int opcode, event, error;
    Display *d = gdk_x11_display_get_xdisplay(gtk_widget_get_display(GTK_WIDGET(s->view)));
    return fake_motion && fake_button && fake_key &&
           XQueryExtension(d, "XTEST", &opcode, &event, &error);
}
static unsigned int press_modifiers(Display *d, unsigned int state, KeyCode pressed[4]) {
    const unsigned int masks[] = {ShiftMask, ControlMask, Mod1Mask, Mod4Mask};
    const KeySym symbols[] = {XK_Shift_L, XK_Control_L, XK_Alt_L, XK_Super_L};
    char down[32];
    XQueryKeymap(d, down);
    unsigned int count = 0;
    for (unsigned int i = 0; i < 4; i++) {
        KeyCode code = XKeysymToKeycode(d, symbols[i]);
        if ((state & masks[i]) && code && !(down[code / 8] & (1 << (code % 8)))) {
            fake_key(d, code, True, 0);
            pressed[count++] = code;
        }
    }
    return count;
}
static void release_modifiers(Display *d, KeyCode pressed[4], unsigned int count) {
    while (count)
        fake_key(d, pressed[--count], False, 0);
}
static gboolean native_surface(Request *r, Display **display, Window *window) {
    Server *s = r->client->server;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(s->window));
    if (s->background) {
        reply(r, NULL, -32004,
              "Native click/key requires foreground mode on Linux; restart without --no-focus");
        return FALSE;
    }
    if (!surface || !GDK_IS_X11_SURFACE(surface) || !xtest_available(s)) {
        reply(r, NULL, -32004, "Native input requires X11 and the XTest extension/library");
        return FALSE;
    }
    *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
    *window = gdk_x11_surface_get_xid(surface);
    gtk_window_present(s->window);
    XRaiseWindow(*display, *window);
    XSetInputFocus(*display, *window, RevertToParent, CurrentTime);
    gtk_widget_grab_focus(GTK_WIDGET(s->view));
    return TRUE;
}
static void dispatched(Request *r) {
    JSCValue *o = object(r->client->server);
    boolean(o, "dispatched", TRUE);
    reply(r, o, 0, NULL);
    g_object_unref(o);
}
static void click(Request *r, JSCValue *params) {
    Server *s = r->client->server;
    double x, y;
    unsigned int state;
    if (!get_number(params, "x", &x) || !get_number(params, "y", &y) ||
        !modifiers(params, &state) || x < 0 || y < 0 ||
        x >= gtk_widget_get_width(GTK_WIDGET(s->view)) ||
        y >= gtk_widget_get_height(GTK_WIDGET(s->view))) {
        reply(r, NULL, -32602, "click requires x/y inside the viewport and valid modifiers");
        return;
    }
    Display *display;
    Window window;
    if (!native_surface(r, &display, &window))
        return;
    graphene_point_t origin = GRAPHENE_POINT_INIT(x, y), point;
    if (!gtk_widget_compute_point(GTK_WIDGET(s->view), GTK_WIDGET(s->window), &origin, &point)) {
        reply(r, NULL, -32004, "Cannot map webview coordinates");
        return;
    }
    int scale = gtk_widget_get_scale_factor(GTK_WIDGET(s->view));
    double surface_x, surface_y;
    gtk_native_get_surface_transform(GTK_NATIVE(s->window), &surface_x, &surface_y);
    int root_x, root_y;
    Window child;
    // GtkWindow widget coordinates exclude native surface margins, such as CSD shadows.
    XTranslateCoordinates(display, window, DefaultRootWindow(display),
                          (int)((point.x - surface_x) * scale),
                          (int)((point.y - surface_y) * scale), &root_x, &root_y, &child);
    KeyCode pressed[4];
    unsigned int count = press_modifiers(display, state, pressed);
    fake_motion(display, -1, root_x, root_y, 0);
    fake_button(display, 1, True, 0);
    fake_button(display, 1, False, 0);
    release_modifiers(display, pressed, count);
    XSync(display, False);
    dispatched(r);
}
static void key(Request *r, JSCValue *params) {
    char *name = get_string(params, "key");
    unsigned int state;
    JSCValue *repeat = jsc_value_object_get_property(params, "repeat");
    gboolean repeat_valid = jsc_value_is_undefined(repeat) || jsc_value_is_boolean(repeat);
    gboolean repeating = jsc_value_is_boolean(repeat) && jsc_value_to_boolean(repeat);
    g_object_unref(repeat);
    KeySym symbol = NoSymbol;
    const struct {
        const char *name;
        KeySym symbol;
    } names[] = {{"ArrowLeft", XK_Left},      {"ArrowRight", XK_Right},   {"ArrowUp", XK_Up},
                 {"ArrowDown", XK_Down},      {"Home", XK_Home},          {"End", XK_End},
                 {"PageUp", XK_Page_Up},      {"PageDown", XK_Page_Down}, {"Delete", XK_Delete},
                 {"Backspace", XK_BackSpace}, {"Enter", XK_Return},       {"Tab", XK_Tab},
                 {"Escape", XK_Escape},       {"Space", XK_space}};
    if (name) {
        if (strlen(name) == 1 && name[0] >= 32 && name[0] <= 126)
            symbol = (unsigned char)name[0];
        for (guint i = 0; i < G_N_ELEMENTS(names); i++)
            if (!strcmp(name, names[i].name))
                symbol = names[i].symbol;
    }
    g_free(name);
    if (symbol == NoSymbol || !repeat_valid || !modifiers(params, &state)) {
        reply(r, NULL, -32602, "Unsupported key or modifiers; use typeText for Unicode text");
        return;
    }
    if (repeating) {
        reply(r, NULL, -32004, "Synthetic key repeat is not supported on X11");
        return;
    }
    Display *display;
    Window window;
    if (!native_surface(r, &display, &window))
        return;
    KeyCode code = XKeysymToKeycode(display, symbol);
    if (!code) {
        reply(r, NULL, -32004, "Key is unavailable in the current X keyboard map");
        return;
    }
    if (XkbKeycodeToKeysym(display, code, 0, 1) == symbol &&
        XkbKeycodeToKeysym(display, code, 0, 0) != symbol)
        state |= ShiftMask;
    KeyCode pressed[4];
    unsigned int count = press_modifiers(display, state, pressed);
    fake_key(display, code, True, 0);
    fake_key(display, code, False, 0);
    release_modifiers(display, pressed, count);
    XFlush(display);
    dispatched(r);
}
typedef struct {
    Request *request;
    char *text;
} TextRequest;
static void text_allowed(GObject *source, GAsyncResult *result, gpointer data) {
    TextRequest *t = data;
    Request *r = t->request;
    GError *error = NULL;
    gboolean allowed =
        webkit_web_view_can_execute_editing_command_finish(WEBKIT_WEB_VIEW(source), result, &error);
    if (!r->done && !r->client->closed) {
        if (error || !allowed)
            reply(r, NULL, -32004, "Focus an editable field in the webview first");
        else {
            webkit_web_view_execute_editing_command_with_argument(WEBKIT_WEB_VIEW(source),
                                                                  "InsertText", t->text);
            dispatched(r);
        }
    }
    g_clear_error(&error);
    request_unref(r);
    g_free(t->text);
    g_free(t);
}
static void type_text(Request *r, JSCValue *params) {
    char *text = get_string(params, "text");
    glong length = 0;
    gunichar2 *utf16 = text ? g_utf8_to_utf16(text, -1, NULL, &length, NULL) : NULL;
    if (!utf16 || length > 16384) {
        g_free(text);
        g_free(utf16);
        reply(r, NULL, -32602, "text must be a string of at most 16384 UTF-16 code units");
        return;
    }
    g_free(utf16);
    TextRequest *t = g_new0(TextRequest, 1);
    t->request = request_ref(r);
    t->text = text;
    webkit_web_view_can_execute_editing_command(r->client->server->view, "InsertText",
                                                r->client->cancel, text_allowed, t);
}
typedef struct {
    Request *request;
    int width, height;
} TurfResizeRequest;
static void resize_free(gpointer data) {
    TurfResizeRequest *resize = data;
    request_unref(resize->request);
    g_free(resize);
}
static gboolean resized(gpointer data) {
    TurfResizeRequest *resize = data;
    Request *r = resize->request;
    Server *s = r->client->server;
    if (r->done || r->client->closed)
        return G_SOURCE_REMOVE;
    if (gtk_widget_get_width(GTK_WIDGET(s->view)) != resize->width ||
        gtk_widget_get_height(GTK_WIDGET(s->view)) != resize->height)
        return G_SOURCE_CONTINUE;
    JSCValue *o = viewport(s);
    reply(r, o, 0, NULL);
    g_object_unref(o);
    return G_SOURCE_REMOVE;
}
// X11 desktop positions are in device pixels; GDK monitor rectangles are logical.
// Convert at the Xlib boundary using the surface scale factor.
typedef struct {
    int x, y;
    gboolean positioned;
} Placement;
static Placement *placement(GtkWidget *window) {
    Placement *p = g_object_get_data(G_OBJECT(window), "turf-placement");
    if (!p) {
        p = g_new0(Placement, 1);
        g_object_set_data_full(G_OBJECT(window), "turf-placement", p, g_free);
    }
    return p;
}
static gboolean position_supported(GtkWindow *window) {
    return GDK_IS_X11_DISPLAY(gtk_widget_get_display(GTK_WIDGET(window)));
}
int turf_linux_set_position(void *window, int x, int y) {
    GtkWidget *widget = GTK_WIDGET(window);
    if (!position_supported(GTK_WINDOW(window)))
        return ENOTSUP;
    gtk_widget_realize(widget);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(widget));
    Display *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
    Window xid = gdk_x11_surface_get_xid(surface);
    int scale = gdk_surface_get_scale_factor(surface);
    if ((int64_t)x * scale < INT_MIN || (int64_t)x * scale > INT_MAX ||
        (int64_t)y * scale < INT_MIN || (int64_t)y * scale > INT_MAX)
        return EINVAL;
    Placement *p = placement(widget);
    p->x = x;
    p->y = y;
    p->positioned = TRUE;
    XSizeHints hints = {0};
    long supplied = 0;
    XGetWMNormalHints(display, xid, &hints, &supplied);
    hints.flags |= USPosition | PPosition | PWinGravity;
    hints.win_gravity = NorthWestGravity;
    hints.x = x * scale;
    hints.y = y * scale;
    XSetWMNormalHints(display, xid, &hints);
    if (gtk_widget_get_mapped(widget)) {
        XEvent e = {0};
        e.xclient.type = ClientMessage;
        e.xclient.window = xid;
        e.xclient.message_type = XInternAtom(display, "_NET_MOVERESIZE_WINDOW", False);
        e.xclient.format = 32;
        e.xclient.data.l[0] = NorthWestGravity | (1 << 8) | (1 << 9) | (1 << 12);
        e.xclient.data.l[1] = x * scale;
        e.xclient.data.l[2] = y * scale;
        // A bare Xvfb has no WM. XMoveWindow is needed in that case.
        Atom wm = XInternAtom(display, "_NET_SUPPORTING_WM_CHECK", False), actual;
        int format;
        unsigned long count, after;
        unsigned char *data = NULL;
        XGetWindowProperty(display, DefaultRootWindow(display), wm, 0, 1, False, XA_WINDOW, &actual,
                           &format, &count, &after, &data);
        gboolean has_wm = count > 0;
        if (data)
            XFree(data);
        if (has_wm)
            XSendEvent(display, DefaultRootWindow(display), False,
                       SubstructureRedirectMask | SubstructureNotifyMask, &e);
        else
            XMoveWindow(display, xid, x * scale, y * scale);
    } else
        XMoveWindow(display, xid, x * scale, y * scale);
    XSync(display, False);
    return 0;
}
// EWMH lets an unmapped client ask the WM for its future decoration sizes.
// Query before calculating an anchored first position, without ever mapping.
static void frame_extents(GdkSurface *surface, int edges[4]) {
    memset(edges, 0, 4 * sizeof(int));
    if (!GDK_IS_X11_SURFACE(surface))
        return;
    Display *d = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
    Window xid = gdk_x11_surface_get_xid(surface);
    Atom property = XInternAtom(d, "_NET_FRAME_EXTENTS", False), actual;
    int format;
    unsigned long count, after;
    unsigned char *data = NULL;
    gboolean requested = FALSE;
    for (int attempt = 0; attempt < 51; attempt++) {
        XGetWindowProperty(d, xid, property, 0, 4, False, XA_CARDINAL, &actual, &format, &count,
                           &after, &data);
        if (actual == XA_CARDINAL && format == 32 && count == 4) {
            unsigned long *v = (unsigned long *)data;
            for (int i = 0; i < 4; i++)
                edges[i] = (int)MIN(v[i], 8192UL);
            XFree(data);
            return;
        }
        if (data) {
            XFree(data);
            data = NULL;
        }
        if (!requested) {
            Atom wm = XInternAtom(d, "_NET_SUPPORTING_WM_CHECK", False);
            XGetWindowProperty(d, DefaultRootWindow(d), wm, 0, 1, False, XA_WINDOW, &actual,
                               &format, &count, &after, &data);
            gboolean has_wm = count > 0;
            if (data) {
                XFree(data);
                data = NULL;
            }
            if (!has_wm)
                return;
            XEvent e = {0};
            e.xclient.type = ClientMessage;
            e.xclient.window = xid;
            e.xclient.message_type = XInternAtom(d, "_NET_REQUEST_FRAME_EXTENTS", False);
            e.xclient.format = 32;
            XSendEvent(d, DefaultRootWindow(d), False,
                       SubstructureRedirectMask | SubstructureNotifyMask, &e);
            XFlush(d);
            requested = TRUE;
        }
        g_usleep(1000);
    }
}
static char *monitor_id(GdkMonitor *m, guint index) {
    const char *connector = gdk_monitor_get_connector(m);
    return connector ? g_strdup(connector) : g_strdup_printf("monitor-%u", index);
}
static void work_area(GdkMonitor *m, GdkRectangle *rect) {
    if (GDK_IS_X11_MONITOR(m))
        gdk_x11_monitor_get_workarea(m, rect);
    else
        gdk_monitor_get_geometry(m, rect);
}
static JSCValue *rectangle(Server *s, GdkRectangle r) {
    JSCValue *o = object(s);
    number(o, "x", r.x);
    number(o, "y", r.y);
    number(o, "width", r.width);
    number(o, "height", r.height);
    return o;
}
static JSCValue *screen_list(Server *s) {
    GdkDisplay *display = gtk_widget_get_display(GTK_WIDGET(s->window));
    GListModel *monitors = gdk_display_get_monitors(display);
    JSCValue *array = jsc_value_new_array(s->json, G_TYPE_NONE);
    for (guint i = 0; i < g_list_model_get_n_items(monitors); i++) {
        GdkMonitor *m = g_list_model_get_item(monitors, i);
        char *id = monitor_id(m, i);
        JSCValue *item = object(s);
        GdkRectangle frame, work;
        gdk_monitor_get_geometry(m, &frame);
        work_area(m, &work);
        string(item, "id", id);
        string(item, "name", gdk_monitor_get_model(m) ?: id);
        put(item, "isPrimary", jsc_value_new_null(s->json));
        boolean(item, "isBuiltIn", g_str_has_prefix(id, "eDP") || g_str_has_prefix(id, "LVDS"));
        number(item, "scaleFactor", gdk_monitor_get_scale_factor(m));
        put(item, "frame", rectangle(s, frame));
        put(item, "workArea", rectangle(s, work));
        jsc_value_object_set_property_at_index(array, i, item);
        g_object_unref(item);
        g_object_unref(m);
        g_free(id);
    }
    return array;
}
static JSCValue *window_info(Server *s) {
    GtkWidget *widget = GTK_WIDGET(s->window);
    gtk_widget_realize(widget);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(widget));
    GdkDisplay *gd = gtk_widget_get_display(widget);
    GdkRectangle rect = {0};
    gtk_window_get_default_size(s->window, &rect.width, &rect.height);
    Placement *p = placement(widget);
    rect.x = p->x;
    rect.y = p->y;
    if (GDK_IS_X11_SURFACE(surface) && gtk_widget_get_mapped(widget)) {
        Display *d = gdk_x11_display_get_xdisplay(gd);
        Window child;
        XWindowAttributes attr;
        Window xid = gdk_x11_surface_get_xid(surface);
        XGetWindowAttributes(d, xid, &attr);
        XTranslateCoordinates(d, xid, DefaultRootWindow(d), 0, 0, &rect.x, &rect.y, &child);
        int scale = gdk_surface_get_scale_factor(surface);
        rect.x /= scale;
        rect.y /= scale;
        rect.width = attr.width / scale;
        rect.height = attr.height / scale;
    }
    int edges[4];
    frame_extents(surface, edges);
    int scale = gdk_surface_get_scale_factor(surface);
    if (gtk_widget_get_mapped(widget)) {
        rect.x -= edges[0] / scale;
        rect.y -= edges[2] / scale;
    }
    rect.width += (edges[0] + edges[1]) / scale;
    rect.height += (edges[2] + edges[3]) / scale;
    GListModel *monitors = gdk_display_get_monitors(gd);
    char *id = g_strdup("");
    GdkRectangle work = {0};
    for (guint i = 0; i < g_list_model_get_n_items(monitors); i++) {
        GdkMonitor *m = g_list_model_get_item(monitors, i);
        GdkRectangle mr;
        gdk_monitor_get_geometry(m, &mr);
        if (i == 0 ||
            (rect.x + rect.width / 2 >= mr.x && rect.x + rect.width / 2 < mr.x + mr.width &&
             rect.y + rect.height / 2 >= mr.y && rect.y + rect.height / 2 < mr.y + mr.height)) {
            g_free(id);
            id = monitor_id(m, i);
            work_area(m, &work);
        }
        g_object_unref(m);
    }
    JSCValue *o = object(s);
    string(o, "screen", id);
    g_free(id);
    if (position_supported(s->window)) {
        put(o, "frame", rectangle(s, rect));
        number(o, "x", rect.x - work.x);
        number(o, "y", rect.y - work.y);
    } else {
        put(o, "frame", jsc_value_new_null(s->json));
        put(o, "x", jsc_value_new_null(s->json));
        put(o, "y", jsc_value_new_null(s->json));
    }
    boolean(o, "visible", gtk_widget_get_visible(widget));
    boolean(o, "focused", gtk_window_is_active(s->window));
    return o;
}
typedef struct {
    Request *request;
    int x, y;
    gint64 deadline;
} MoveRequest;
static void move_free(gpointer data) {
    MoveRequest *m = data;
    request_unref(m->request);
    g_free(m);
}
static gboolean moved(gpointer data) {
    MoveRequest *m = data;
    Request *r = m->request;
    if (r->done || r->client->closed)
        return G_SOURCE_REMOVE;
    JSCValue *o = window_info(r->client->server);
    JSCValue *f = jsc_value_object_get_property(o, "frame");
    double x = 0, y = 0;
    get_number(f, "x", &x);
    get_number(f, "y", &y);
    g_object_unref(f);
    // Window-manager requests are asynchronous and may be constrained by policy.
    gboolean settled =
        (fabs(x - m->x) <= 1 && fabs(y - m->y) <= 1) || g_get_monotonic_time() >= m->deadline;
    if (settled)
        reply(r, o, 0, NULL);
    g_object_unref(o);
    return settled ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
}
static void move_window(Request *r, JSCValue *params) {
    Server *s = r->client->server;
    if (!position_supported(s->window)) {
        reply(r, NULL, -32004, "Window positioning requires X11");
        return;
    }
    char *id = get_string(params, "screen"), *anchor = get_string(params, "anchor");
    if (!jsc_value_object_has_property(params, "anchor"))
        anchor = g_strdup("top-left");
    double x = 0, y = 0;
    gboolean valid = id && anchor &&
                     (!strcmp(anchor, "top-left") || !strcmp(anchor, "top-right") ||
                      !strcmp(anchor, "bottom-left") || !strcmp(anchor, "bottom-right"));
    if (jsc_value_object_has_property(params, "x"))
        valid &= get_number(params, "x", &x);
    if (jsc_value_object_has_property(params, "y"))
        valid &= get_number(params, "y", &y);
    if (!valid || x < 0 || y < 0) {
        reply(r, NULL, -32602,
              "move requires a screen ID, nonnegative offsets and a corner anchor");
        goto done;
    }
    if (gtk_window_is_fullscreen(s->window) || gtk_window_is_maximized(s->window)) {
        reply(r, NULL, -32004, "Restore the window before moving");
        goto done;
    }
    GListModel *monitors = gdk_display_get_monitors(gtk_widget_get_display(GTK_WIDGET(s->window)));
    for (guint i = 0; i < g_list_model_get_n_items(monitors); i++) {
        GdkMonitor *m = g_list_model_get_item(monitors, i);
        char *candidate = monitor_id(m, i);
        gboolean match = !strcmp(candidate, id);
        g_free(candidate);
        if (!match) {
            g_object_unref(m);
            continue;
        }
        GdkRectangle work;
        work_area(m, &work);
        g_object_unref(m);
        int width, height;
        gtk_window_get_default_size(s->window, &width, &height);
        if (gtk_widget_get_mapped(GTK_WIDGET(s->window))) {
            GdkSurface *sf = gtk_native_get_surface(GTK_NATIVE(s->window));
            width = gdk_surface_get_width(sf);
            height = gdk_surface_get_height(sf);
        }
        gtk_widget_realize(GTK_WIDGET(s->window));
        GdkSurface *sf = gtk_native_get_surface(GTK_NATIVE(s->window));
        int edges[4];
        frame_extents(sf, edges);
        int scale = gdk_surface_get_scale_factor(sf);
        width += (edges[0] + edges[1]) / scale;
        height += (edges[2] + edges[3]) / scale;
        double max_x = MAX(0, work.width - width), max_y = MAX(0, work.height - height);
        double left = g_str_has_suffix(anchor, "right") ? max_x - x : x;
        double top = g_str_has_prefix(anchor, "bottom") ? max_y - y : y;
        int target_x = work.x + (int)CLAMP(left, 0, max_x),
            target_y = work.y + (int)CLAMP(top, 0, max_y);
        if (turf_linux_set_position(s->window, target_x, target_y)) {
            reply(r, NULL, -32002, "Window move failed");
            goto done;
        }
        if (gtk_widget_get_mapped(GTK_WIDGET(s->window))) {
            MoveRequest *m = g_new0(MoveRequest, 1);
            m->request = request_ref(r);
            m->x = target_x;
            m->y = target_y;
            m->deadline = g_get_monotonic_time() + 2000000;
            g_timeout_add_full(G_PRIORITY_DEFAULT, 16, moved, m, move_free);
        } else {
            JSCValue *o = window_info(s);
            reply(r, o, 0, NULL);
            g_object_unref(o);
        }
        goto done;
    }
    reply(r, NULL, -32602, "Unknown screen; call screens again");
done:
    g_free(id);
    g_free(anchor);
}

static void execute(Request *r, const char *method, JSCValue *params) {
    Server *s = r->client->server;
    if (!gtk_widget_get_visible(GTK_WIDGET(s->window)) &&
        (!strcmp(method, "click") || !strcmp(method, "key") || !strcmp(method, "typeText"))) {
        reply(r, NULL, -32004, "Show the window before sending input");
        return;
    }
    if (!strcmp(method, "info")) {
        JSCValue *o = object(s);
        number(o, "protocolVersion", 1);
        number(o, "pid", getpid());
        string(o, "engine", "WebKitGTK");
        boolean(o, "background", s->background);
        string(o, "title", webkit_web_view_get_title(s->view));
        string(o, "url", webkit_web_view_get_uri(s->view));
        boolean(o, "loading", webkit_web_view_is_loading(s->view));
        put(o, "viewport", viewport(s));
        put(o, "window", window_info(s));
        put(o, "methods",
            jsc_value_new_from_json(
                s->json,
                "[\"info\",\"evaluate\",\"navigate\",\"screenshot\",\"resize\","
                "\"screens\",\"move\",\"show\",\"click\",\"key\",\"typeText\",\"close\"]"));
        JSCValue *caps = object(s);
        boolean(caps, "windowPosition", position_supported(s->window));
        boolean(caps, "deferredShow", TRUE);
        string(caps, "windowCoordinates", "gdk-logical");
        boolean(caps, "awaitPromises", TRUE);
        string(caps, "nativeInput", xtest_available(s) ? "x11-xtest" : "unsupported");
        boolean(caps, "keyRepeat", FALSE);
        boolean(caps, "backgroundNativeInput", FALSE);
        string(caps, "screenshot", "viewport");
        number(caps, "maxRequestBytes", MAX_REQUEST);
        number(caps, "maxResponseBytes", MAX_RESPONSE);
        put(o, "capabilities", caps);
        reply(r, o, 0, NULL);
        g_object_unref(o);
    } else if (!strcmp(method, "screens")) {
        JSCValue *o = object(s);
        put(o, "screens", screen_list(s));
        reply(r, o, 0, NULL);
        g_object_unref(o);
    } else if (!strcmp(method, "move")) {
        move_window(r, params);
    } else if (!strcmp(method, "show")) {
        turf_linux_show_window(s->window, s->background);
        JSCValue *o = window_info(s);
        reply(r, o, 0, NULL);
        g_object_unref(o);
    } else if (!strcmp(method, "evaluate")) {
        char *expression = get_string(params, "expression");
        if (!expression) {
            reply(r, NULL, -32602, "expression must be a string");
            return;
        }
        GVariantBuilder args;
        g_variant_builder_init(&args, G_VARIANT_TYPE_VARDICT);
        g_variant_builder_add(&args, "{sv}", "expression", g_variant_new_string(expression));
        GVariant *arguments = g_variant_ref_sink(g_variant_builder_end(&args));
        webkit_web_view_call_async_javascript_function(
            s->view,
            "const value = await (0, eval)(expression); return JSON.stringify({type: value === "
            "null ? 'null' : typeof value, value});",
            -1, arguments, NULL, NULL, r->client->cancel, evaluated, request_ref(r));
        g_variant_unref(arguments);
        g_free(expression);
    } else if (!strcmp(method, "navigate")) {
        char *url = get_string(params, "url");
        char *scheme = url ? g_uri_parse_scheme(url) : NULL;
        gboolean valid =
            scheme &&
            (!g_ascii_strcasecmp(scheme, "http") || !g_ascii_strcasecmp(scheme, "https") ||
             !g_ascii_strcasecmp(scheme, "file") || !g_ascii_strcasecmp(scheme, "about"));
        if (!valid)
            reply(r, NULL, -32602, "url must use http, https, file, or about");
        else if (s->navigation || webkit_web_view_is_loading(s->view))
            reply(r, NULL, -32000, "A navigation is already in progress");
        else {
            s->navigation = request_ref(r);
            webkit_web_view_load_uri(s->view, url);
        }
        g_free(scheme);
        g_free(url);
    } else if (!strcmp(method, "screenshot")) {
        webkit_web_view_get_snapshot(s->view, WEBKIT_SNAPSHOT_REGION_VISIBLE,
                                     WEBKIT_SNAPSHOT_OPTIONS_NONE, r->client->cancel, snapshot,
                                     request_ref(r));
    } else if (!strcmp(method, "resize")) {
        double width, height;
        if (!get_number(params, "width", &width) || !get_number(params, "height", &height) ||
            width < 1 || height < 1 || width > 8192 || height > 8192)
            reply(r, NULL, -32602, "width and height must be numbers from 1 to 8192");
        else {
            // A realized but unmapped GTK toplevel retains its initial surface
            // size. Recreate that hidden surface so first map uses the new size.
            if (!gtk_widget_get_visible(GTK_WIDGET(s->window)) &&
                gtk_widget_get_realized(GTK_WIDGET(s->window)))
                gtk_widget_unrealize(GTK_WIDGET(s->window));
            gtk_window_set_default_size(s->window, (int)width, (int)height);
            if (!gtk_widget_get_visible(GTK_WIDGET(s->window))) {
                JSCValue *o = object(s);
                number(o, "width", (int)width);
                number(o, "height", (int)height);
                reply(r, o, 0, NULL);
                g_object_unref(o);
                return;
            }
            TurfResizeRequest *resize = g_new0(TurfResizeRequest, 1);
            resize->request = request_ref(r);
            resize->width = (int)width;
            resize->height = (int)height;
            g_timeout_add_full(G_PRIORITY_DEFAULT, 16, resized, resize, resize_free);
        }
    } else if (!strcmp(method, "click"))
        click(r, params);
    else if (!strcmp(method, "key"))
        key(r, params);
    else if (!strcmp(method, "typeText"))
        type_text(r, params);
    else if (!strcmp(method, "close")) {
        r->client->close_window = TRUE;
        JSCValue *o = object(s);
        boolean(o, "closing", TRUE);
        reply(r, o, 0, NULL);
        g_object_unref(o);
    } else
        reply(r, NULL, -32601, "Method not found");
}
static Request *request_new(Client *c) {
    Request *r = g_new0(Request, 1);
    r->refs = 1;
    r->client = client_ref(c);
    c->request = r;
    r->timeout = g_timeout_add_full(G_PRIORITY_DEFAULT, 30000, request_timeout, request_ref(r),
                                    request_unref);
    return r;
}
static void handle_line(Client *c, const char *line) {
    Server *s = c->server;
    Request *r = request_new(c);
    JSCValue *root = jsc_value_new_from_json(s->json, line);
    jsc_context_clear_exception(s->json);
    if (!root)
        reply(r, NULL, -32700, "Invalid JSON");
    else if (!jsc_value_is_object(root) || jsc_value_is_array(root))
        reply(r, NULL, -32600, "Expected a JSON-RPC request object");
    else {
        JSCValue *id = jsc_value_object_get_property(root, "id");
        char *version = get_string(root, "jsonrpc"), *method = get_string(root, "method");
        gboolean valid_id = jsc_value_is_string(id) ||
                            (jsc_value_is_number(id) && isfinite(jsc_value_to_double(id)) &&
                             fabs(jsc_value_to_double(id)) <= 9007199254740991.0);
        if (!valid_id || !version || strcmp(version, "2.0") || !method)
            reply(r, NULL, -32600,
                  "Expected jsonrpc 2.0, a string method, and a string or numeric id");
        else {
            r->id = g_object_ref(id);
            JSCValue *params = jsc_value_object_get_property(root, "params");
            if (jsc_value_is_undefined(params)) {
                g_object_unref(params);
                params = object(s);
            }
            if (!jsc_value_is_object(params) || jsc_value_is_array(params))
                reply(r, NULL, -32602, "params must be an object");
            else
                execute(r, method, params);
            g_object_unref(params);
        }
        g_object_unref(id);
        g_free(version);
        g_free(method);
    }
    g_clear_object(&root);
    request_unref(r);
}
static void read_done(GObject *source, GAsyncResult *result, gpointer data) {
    Client *c = data;
    GError *error = NULL;
    GBytes *bytes = g_input_stream_read_bytes_finish(G_INPUT_STREAM(source), result, &error);
    if (!c->closed) {
        gsize size = bytes ? g_bytes_get_size(bytes) : 0;
        if (!size)
            client_close(c);
        else {
            g_byte_array_append(c->input, g_bytes_get_data(bytes, NULL), size);
            client_next(c);
        }
    }
    g_clear_pointer(&bytes, g_bytes_unref);
    g_clear_error(&error);
    client_unref(c);
}
static void client_next(Client *c) {
    if (c->closed || c->busy)
        return;
    guint8 *newline = c->input->len ? memchr(c->input->data, '\n', c->input->len) : NULL;
    gsize length = newline ? (gsize)(newline - c->input->data) : c->input->len;
    if (length > MAX_REQUEST) {
        c->busy = TRUE;
        c->close_after_write = TRUE;
        Request *r = request_new(c);
        reply(r, NULL, -32600, "Request exceeds 1 MiB");
        request_unref(r);
        return;
    }
    if (newline) {
        gboolean valid = g_utf8_validate((const char *)c->input->data, length, NULL) &&
                         !memchr(c->input->data, 0, length);
        char *line = valid ? g_strndup((const char *)c->input->data, length) : g_strdup("invalid");
        g_byte_array_remove_range(c->input, 0, length + 1);
        c->busy = TRUE;
        clear_timer(&c->deadline);
        handle_line(c, line);
        g_free(line);
    } else
        g_input_stream_read_bytes_async(g_io_stream_get_input_stream(G_IO_STREAM(c->connection)),
                                        8192, G_PRIORITY_DEFAULT, c->cancel, read_done,
                                        client_ref(c));
}
static gboolean incoming(GSocketService *service, GSocketConnection *connection, GObject *source,
                         gpointer data) {
    (void)service;
    (void)source;
    Server *s = data;
    struct ucred peer;
    socklen_t length = sizeof(peer);
    int fd = g_socket_get_fd(g_socket_connection_get_socket(connection));
    if (s->stopped || g_list_length(s->clients) >= 16 ||
        getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &length) || peer.uid != geteuid()) {
        g_io_stream_close(G_IO_STREAM(connection), NULL, NULL);
        return TRUE;
    }
    Client *c = g_new0(Client, 1);
    c->refs = 1;
    c->server = server_ref(s);
    c->connection = g_object_ref(connection);
    c->cancel = g_cancellable_new();
    c->input = g_byte_array_new();
    s->clients = g_list_prepend(s->clients, c);
    deadline(c, 10);
    client_next(c);
    return TRUE;
}
void turf_linux_show_window(void *window, bool no_focus) {
    GtkWidget *widget = GTK_WIDGET(window);
    if (gtk_widget_get_visible(widget))
        return;
    gboolean background = no_focus || (server && server->background);
    gtk_widget_realize(widget);
    Placement *p = placement(widget);
    if (p->positioned)
        turf_linux_set_position(window, p->x, p->y);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
    if (background && GDK_IS_X11_SURFACE(surface))
        gdk_x11_surface_set_user_time(surface, 0);
    if (background)
        gtk_widget_set_visible(widget, TRUE);
    else
        gtk_window_present(GTK_WINDOW(window));
}
int turf_linux_automation_start(void *view, void *window, const char *path, bool background) {
    if (server)
        return EALREADY;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (!view || !window || !path || path[0] != '/' || strlen(path) >= sizeof(address.sun_path))
        return EINVAL;
    char *parent = g_path_get_dirname(path);
    struct stat st;
    if (lstat(parent, &st)) {
        int err = errno;
        g_free(parent);
        return err;
    }
    g_free(parent);
    if (!S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 077))
        return EACCES;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return errno;
    strcpy(address.sun_path, path);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address))) {
        int err = errno;
        close(fd);
        return err;
    }
    if (lstat(path, &st)) {
        int err = errno;
        close(fd);
        return err;
    }
    if (chmod(path, 0600) || listen(fd, 16)) {
        int err = errno;
        close(fd);
        unlink(path);
        return err;
    }
    GError *error = NULL;
    GSocket *socket = g_socket_new_from_fd(fd, &error);
    if (!socket) {
        close(fd);
        unlink(path);
        g_clear_error(&error);
        return EIO;
    }
    Server *s = g_new0(Server, 1);
    s->refs = 1;
    s->background = background;
    s->view = g_object_ref(view);
    s->window = g_object_ref(window);
    s->json = jsc_context_new();
    s->path = g_strdup(path);
    s->inode = st.st_ino;
    s->device = st.st_dev;
    s->service = g_socket_service_new();
    if (!g_socket_listener_add_socket(G_SOCKET_LISTENER(s->service), socket, NULL, &error)) {
        g_object_unref(socket);
        unlink(path);
        g_clear_error(&error);
        server_unref(s);
        return EIO;
    }
    g_object_unref(socket);
    g_signal_connect(s->service, "incoming", G_CALLBACK(incoming), s);
    s->load_handler = g_signal_connect(view, "load-changed", G_CALLBACK(load_changed), s);
    s->fail_handler = g_signal_connect(view, "load-failed", G_CALLBACK(load_failed), s);
    server = s;
    g_socket_service_start(s->service);
    return 0;
}
void turf_linux_automation_stop(void) {
    Server *s = server;
    if (!s)
        return;
    server = NULL;
    s->stopped = TRUE;
    g_socket_service_stop(s->service);
    g_socket_listener_close(G_SOCKET_LISTENER(s->service));
    g_signal_handlers_disconnect_by_data(s->service, s);
    g_signal_handler_disconnect(s->view, s->load_handler);
    g_signal_handler_disconnect(s->view, s->fail_handler);
    if (s->navigation) {
        Request *r = s->navigation;
        s->navigation = NULL;
        request_unref(r);
    }
    while (s->clients)
        client_close(s->clients->data);
    // Late WebKit completions may retain requests; they must not keep windows alive.
    g_clear_object(&s->view);
    g_clear_object(&s->window);
    struct stat st;
    if (!lstat(s->path, &st) && S_ISSOCK(st.st_mode) && st.st_ino == s->inode &&
        st.st_dev == s->device)
        unlink(s->path);
    server_unref(s);
}
