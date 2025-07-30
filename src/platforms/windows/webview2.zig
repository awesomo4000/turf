const std = @import("std");
pub const win = std.os.windows;

// Windows type aliases
pub const HRESULT = win.HRESULT;
pub const HWND = win.HWND;
pub const HINSTANCE = win.HINSTANCE;
pub const BOOL = win.BOOL;
pub const S_OK = win.S_OK;
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

// Window styles
pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const WS_VISIBLE = 0x10000000;
pub const WM_SIZE = 0x0005;
pub const WM_DESTROY = 0x0002;
pub const WM_QUIT = 0x0012;
pub const WM_USER = 0x0400;
pub const WM_PROCESS_SCRIPT_QUEUE = WM_USER + 1;
pub const WM_PROCESS_MESSAGE_QUEUE = WM_USER + 2;

// COM initialization
pub const COINIT_APARTMENTTHREADED = 0x2;

// Windows structures
pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const WNDCLASSW = extern struct {
    style: u32,
    lpfnWndProc: *const fn (HWND, u32, win.WPARAM, win.LPARAM) callconv(win.WINAPI) win.LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?win.HICON,
    hCursor: ?win.HCURSOR,
    hbrBackground: ?win.HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: win.WPARAM,
    lParam: win.LPARAM,
    time: u32,
    pt: extern struct { x: i32, y: i32 },
};

// Windows API imports
pub extern "user32" fn RegisterClassW(*const WNDCLASSW) callconv(win.WINAPI) u16;
pub extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?win.HMENU, HINSTANCE, ?*anyopaque) callconv(win.WINAPI) ?HWND;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(win.WINAPI) win.BOOL;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(win.WINAPI) win.BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(win.WINAPI) win.BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(win.WINAPI) win.BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(win.WINAPI) win.LRESULT;
pub const PM_REMOVE = 0x0001;
pub extern "user32" fn PostQuitMessage(i32) callconv(win.WINAPI) void;
pub extern "user32" fn PostMessageW(HWND, u32, win.WPARAM, win.LPARAM) callconv(win.WINAPI) win.BOOL;
pub extern "user32" fn DefWindowProcW(HWND, u32, win.WPARAM, win.LPARAM) callconv(win.WINAPI) win.LRESULT;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(win.WINAPI) win.BOOL;
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(win.WINAPI) ?HINSTANCE;

// COM imports
pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: win.DWORD) callconv(win.WINAPI) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(win.WINAPI) void;

// File/Directory imports for temporary folder handling
pub const FILE_ATTRIBUTE_TEMPORARY = 0x100;
pub const FILE_FLAG_DELETE_ON_CLOSE = 0x04000000;
pub extern "kernel32" fn GetTempPathW(nBufferLength: win.DWORD, lpBuffer: [*]u16) callconv(win.WINAPI) win.DWORD;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(win.WINAPI) win.BOOL;

// WebView2Loader import
pub extern "WebView2Loader" fn CreateCoreWebView2EnvironmentWithOptions(
    browserExecutableFolder: ?[*:0]const u16,
    userDataFolder: ?[*:0]const u16,
    environmentOptions: ?*anyopaque,
    environmentCreatedHandler: ?*anyopaque
) callconv(win.WINAPI) HRESULT;

// WebView2 EventRegistrationToken
pub const EventRegistrationToken = extern struct {
    value: i64,
};

// WebView2 interfaces (partial definitions - enough for basic functionality)
pub const ICoreWebView2 = extern struct {
    vtable: *const VTable,
    
    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn(*ICoreWebView2, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*ICoreWebView2) callconv(win.WINAPI) u32,
        Release: *const fn(*ICoreWebView2) callconv(win.WINAPI) u32,
        
        // ICoreWebView2 methods in exact vtable order from WebView2.h
        get_Settings: *const fn(*ICoreWebView2, **anyopaque) callconv(win.WINAPI) HRESULT,
        get_Source: *const fn(*ICoreWebView2, *?[*:0]u16) callconv(win.WINAPI) HRESULT,
        Navigate: *const fn(*ICoreWebView2, [*:0]const u16) callconv(win.WINAPI) HRESULT,
        NavigateToString: *const fn(*ICoreWebView2, [*:0]const u16) callconv(win.WINAPI) HRESULT,
        add_NavigationStarting: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_NavigationStarting: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_ContentLoading: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_ContentLoading: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_SourceChanged: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_SourceChanged: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_HistoryChanged: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_HistoryChanged: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_NavigationCompleted: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_NavigationCompleted: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_FrameNavigationStarting: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_FrameNavigationStarting: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_FrameNavigationCompleted: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_FrameNavigationCompleted: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_ScriptDialogOpening: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_ScriptDialogOpening: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_PermissionRequested: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_PermissionRequested: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_ProcessFailed: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_ProcessFailed: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        AddScriptToExecuteOnDocumentCreated: *const fn(*ICoreWebView2, [*:0]const u16, ?*anyopaque) callconv(win.WINAPI) HRESULT,
        RemoveScriptToExecuteOnDocumentCreated: *const fn(*ICoreWebView2, [*:0]const u16) callconv(win.WINAPI) HRESULT,
        ExecuteScript: *const fn(*ICoreWebView2, [*:0]const u16, ?*anyopaque) callconv(win.WINAPI) HRESULT,
        CapturePreview: *const fn(*ICoreWebView2, u32, *anyopaque, ?*anyopaque) callconv(win.WINAPI) HRESULT,
        Reload: *const fn(*ICoreWebView2) callconv(win.WINAPI) HRESULT,
        PostWebMessageAsJson: *const fn(*ICoreWebView2, [*:0]const u16) callconv(win.WINAPI) HRESULT,
        PostWebMessageAsString: *const fn(*ICoreWebView2, [*:0]const u16) callconv(win.WINAPI) HRESULT,
        add_WebMessageReceived: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_WebMessageReceived: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        CallDevToolsProtocolMethod: *const fn(*ICoreWebView2, [*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(win.WINAPI) HRESULT,
        get_BrowserProcessId: *const fn(*ICoreWebView2, *u32) callconv(win.WINAPI) HRESULT,
        get_CanGoBack: *const fn(*ICoreWebView2, *BOOL) callconv(win.WINAPI) HRESULT,
        get_CanGoForward: *const fn(*ICoreWebView2, *BOOL) callconv(win.WINAPI) HRESULT,
        GoBack: *const fn(*ICoreWebView2) callconv(win.WINAPI) HRESULT,
        GoForward: *const fn(*ICoreWebView2) callconv(win.WINAPI) HRESULT,
        GetDevToolsProtocolEventReceiver: *const fn(*ICoreWebView2, [*:0]const u16, **anyopaque) callconv(win.WINAPI) HRESULT,
        Stop: *const fn(*ICoreWebView2) callconv(win.WINAPI) HRESULT,
        add_NewWindowRequested: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_NewWindowRequested: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_DocumentTitleChanged: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_DocumentTitleChanged: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        get_DocumentTitle: *const fn(*ICoreWebView2, *?[*:0]u16) callconv(win.WINAPI) HRESULT,
        AddHostObjectToScript: *const fn(*ICoreWebView2, [*:0]const u16, *anyopaque) callconv(win.WINAPI) HRESULT,
        RemoveHostObjectFromScript: *const fn(*ICoreWebView2, [*:0]const u16) callconv(win.WINAPI) HRESULT,
        OpenDevToolsWindow: *const fn(*ICoreWebView2) callconv(win.WINAPI) HRESULT,
        add_ContainsFullScreenElementChanged: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_ContainsFullScreenElementChanged: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        get_ContainsFullScreenElement: *const fn(*ICoreWebView2, *BOOL) callconv(win.WINAPI) HRESULT,
        add_WebResourceRequested: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_WebResourceRequested: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        AddWebResourceRequestedFilter: *const fn(*ICoreWebView2, [*:0]const u16, i32) callconv(win.WINAPI) HRESULT,
        RemoveWebResourceRequestedFilter: *const fn(*ICoreWebView2, [*:0]const u16, i32) callconv(win.WINAPI) HRESULT,
        add_WindowCloseRequested: *const fn(*ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_WindowCloseRequested: *const fn(*ICoreWebView2, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
    };
};

pub const ICoreWebView2Controller = extern struct {
    vtable: *const VTable,
    
    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn(*ICoreWebView2Controller, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*ICoreWebView2Controller) callconv(win.WINAPI) u32,
        Release: *const fn(*ICoreWebView2Controller) callconv(win.WINAPI) u32,
        
        // ICoreWebView2Controller methods (partial list)
        get_IsVisible: *const fn(*ICoreWebView2Controller, *BOOL) callconv(win.WINAPI) HRESULT,
        put_IsVisible: *const fn(*ICoreWebView2Controller, BOOL) callconv(win.WINAPI) HRESULT,
        get_Bounds: *const fn(*ICoreWebView2Controller, *RECT) callconv(win.WINAPI) HRESULT,
        put_Bounds: *const fn(*ICoreWebView2Controller, RECT) callconv(win.WINAPI) HRESULT,
        get_ZoomFactor: *const fn(*ICoreWebView2Controller, *f64) callconv(win.WINAPI) HRESULT,
        put_ZoomFactor: *const fn(*ICoreWebView2Controller, f64) callconv(win.WINAPI) HRESULT,
        add_ZoomFactorChanged: *const fn(*ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_ZoomFactorChanged: *const fn(*ICoreWebView2Controller, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        SetBoundsAndZoomFactor: *const fn(*ICoreWebView2Controller, RECT, f64) callconv(win.WINAPI) HRESULT,
        MoveFocus: *const fn(*ICoreWebView2Controller, u32) callconv(win.WINAPI) HRESULT,
        add_MoveFocusRequested: *const fn(*ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_MoveFocusRequested: *const fn(*ICoreWebView2Controller, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_GotFocus: *const fn(*ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_GotFocus: *const fn(*ICoreWebView2Controller, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_LostFocus: *const fn(*ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_LostFocus: *const fn(*ICoreWebView2Controller, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        add_AcceleratorKeyPressed: *const fn(*ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_AcceleratorKeyPressed: *const fn(*ICoreWebView2Controller, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        get_ParentWindow: *const fn(*ICoreWebView2Controller, *HWND) callconv(win.WINAPI) HRESULT,
        put_ParentWindow: *const fn(*ICoreWebView2Controller, HWND) callconv(win.WINAPI) HRESULT,
        NotifyParentWindowPositionChanged: *const fn(*ICoreWebView2Controller) callconv(win.WINAPI) HRESULT,
        Close: *const fn(*ICoreWebView2Controller) callconv(win.WINAPI) HRESULT,
        get_CoreWebView2: *const fn(*ICoreWebView2Controller, **ICoreWebView2) callconv(win.WINAPI) HRESULT,
    };
};

pub const ICoreWebView2Environment = extern struct {
    vtable: *const VTable,
    
    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn(*ICoreWebView2Environment, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*ICoreWebView2Environment) callconv(win.WINAPI) u32,
        Release: *const fn(*ICoreWebView2Environment) callconv(win.WINAPI) u32,
        
        // ICoreWebView2Environment methods (partial list)
        CreateCoreWebView2Controller: *const fn(*ICoreWebView2Environment, HWND, ?*anyopaque) callconv(win.WINAPI) HRESULT,
        CreateWebResourceRequest: *const fn(*ICoreWebView2Environment, [*:0]const u16, [*:0]const u16, ?*anyopaque, [*:0]const u16, **anyopaque) callconv(win.WINAPI) HRESULT,
        get_BrowserVersionString: *const fn(*ICoreWebView2Environment, *?[*:0]u16) callconv(win.WINAPI) HRESULT,
        add_NewBrowserVersionAvailable: *const fn(*ICoreWebView2Environment, ?*anyopaque, *EventRegistrationToken) callconv(win.WINAPI) HRESULT,
        remove_NewBrowserVersionAvailable: *const fn(*ICoreWebView2Environment, EventRegistrationToken) callconv(win.WINAPI) HRESULT,
    };
};

// Handler base interface for callbacks
pub const IUnknown = extern struct {
    QueryInterface: *const fn(*anyopaque, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
    AddRef: *const fn(*anyopaque) callconv(win.WINAPI) u32,
    Release: *const fn(*anyopaque) callconv(win.WINAPI) u32,
};

// WebView configuration options
pub const WebViewOptions = struct {
    title: []const u8 = "WebView",
    width: i32 = 800,
    height: i32 = 600,
    url: ?[]const u8 = null,
    html: ?[]const u8 = null,
    js_inject: ?[]const u8 = null,
};

// High-level WebView wrapper
pub const WebView = struct {
    allocator: std.mem.Allocator,
    options: WebViewOptions,
    hwnd: ?HWND = null,
    environment: ?*ICoreWebView2Environment = null,
    controller: ?*ICoreWebView2Controller = null,
    webview: ?*ICoreWebView2 = null,
    user_data_folder: []u8,
    user_data_existed: bool = false,
    url: ?[]const u8 = null,
    script_id: ?[]u8 = null,
    is_ready: bool = false,
    is_page_ready: bool = false,
    is_shutting_down: bool = false,
    pending_navigation: ?[]const u8 = null,
    
    // Message queue for thread-safe communication
    message_queue: std.ArrayList([]const u8),
    queue_mutex: std.Thread.Mutex = .{},
    js_inject: ?[]const u8 = null,
    
    // Script execution queue for thread-safe ExecuteScript
    script_queue: std.ArrayList([]const u8),
    script_mutex: std.Thread.Mutex = .{},
    
    // Event tokens for cleanup
    nav_starting_token: ?EventRegistrationToken = null,
    nav_completed_token: ?EventRegistrationToken = null,
    content_loading_token: ?EventRegistrationToken = null,
    source_changed_token: ?EventRegistrationToken = null,
    msg_received_token: ?EventRegistrationToken = null,
    window_close_token: ?EventRegistrationToken = null,
    
    // Static instances for handlers
    env_handler: EnvironmentHandler = undefined,
    controller_handler: ControllerHandler = undefined,
    nav_starting_handler: NavigationStartingHandler = undefined,
    nav_handler: NavigationCompletedHandler = undefined,
    content_loading_handler: ContentLoadingHandler = undefined,
    source_changed_handler: SourceChangedHandler = undefined,
    msg_handler: WebMessageReceivedHandler = undefined,
    env_vtable: EnvironmentHandler.VTable = undefined,
    controller_vtable: ControllerHandler.VTable = undefined,
    nav_starting_vtable: NavigationStartingHandler.VTable = undefined,
    nav_vtable: NavigationCompletedHandler.VTable = undefined,
    content_loading_vtable: ContentLoadingHandler.VTable = undefined,
    source_changed_vtable: SourceChangedHandler.VTable = undefined,
    msg_vtable: WebMessageReceivedHandler.VTable = undefined,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, options: WebViewOptions) !*Self {
        std.debug.print("WebView2.init called\n", .{});
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.* = Self{
            .allocator = allocator,
            .options = options,
            .url = options.url,
            .user_data_folder = try allocator.alloc(u8, std.fs.max_path_bytes),
            .message_queue = std.ArrayList([]const u8).init(allocator),
            .script_queue = std.ArrayList([]const u8).init(allocator),
            .js_inject = options.js_inject,
        };
        std.debug.print("WebView2 struct initialized\n", .{});
        if (options.js_inject) |js| {
            std.debug.print("WebView2 received {} bytes of JavaScript to inject\n", .{js.len});
        }
        
        // Initialize handler vtables
        self.env_vtable = EnvironmentHandler.VTable{
            .QueryInterface = EnvironmentHandler.queryInterface,
            .AddRef = EnvironmentHandler.addRef,
            .Release = EnvironmentHandler.release,
            .Invoke = EnvironmentHandler.invoke,
        };
        
        self.controller_vtable = ControllerHandler.VTable{
            .QueryInterface = ControllerHandler.queryInterface,
            .AddRef = ControllerHandler.addRef,
            .Release = ControllerHandler.release,
            .Invoke = ControllerHandler.invoke,
        };
        
        self.nav_starting_vtable = NavigationStartingHandler.VTable{
            .QueryInterface = NavigationStartingHandler.queryInterface,
            .AddRef = NavigationStartingHandler.addRef,
            .Release = NavigationStartingHandler.release,
            .Invoke = NavigationStartingHandler.invoke,
        };
        
        self.nav_vtable = NavigationCompletedHandler.VTable{
            .QueryInterface = NavigationCompletedHandler.queryInterface,
            .AddRef = NavigationCompletedHandler.addRef,
            .Release = NavigationCompletedHandler.release,
            .Invoke = NavigationCompletedHandler.invoke,
        };
        
        self.content_loading_vtable = ContentLoadingHandler.VTable{
            .QueryInterface = ContentLoadingHandler.queryInterface,
            .AddRef = ContentLoadingHandler.addRef,
            .Release = ContentLoadingHandler.release,
            .Invoke = ContentLoadingHandler.invoke,
        };
        
        self.source_changed_vtable = SourceChangedHandler.VTable{
            .QueryInterface = SourceChangedHandler.queryInterface,
            .AddRef = SourceChangedHandler.addRef,
            .Release = SourceChangedHandler.release,
            .Invoke = SourceChangedHandler.invoke,
        };
        
        self.msg_vtable = WebMessageReceivedHandler.VTable{
            .QueryInterface = WebMessageReceivedHandler.queryInterface,
            .AddRef = WebMessageReceivedHandler.addRef,
            .Release = WebMessageReceivedHandler.release,
            .Invoke = WebMessageReceivedHandler.invoke,
        };
        
        self.env_handler = EnvironmentHandler{
            .vtable = &self.env_vtable,
            .ref_count = 1,
            .parent = self,
        };
        
        self.controller_handler = ControllerHandler{
            .vtable = &self.controller_vtable,
            .ref_count = 1,
            .parent = self,
        };
        
        self.nav_starting_handler = NavigationStartingHandler{
            .vtable = &self.nav_starting_vtable,
            .ref_count = 1,
            .parent = self,
        };
        
        self.nav_handler = NavigationCompletedHandler{
            .vtable = &self.nav_vtable,
            .ref_count = 1,
            .parent = self,
        };
        
        self.content_loading_handler = ContentLoadingHandler{
            .vtable = &self.content_loading_vtable,
            .ref_count = 1,
            .parent = self,
        };
        
        self.source_changed_handler = SourceChangedHandler{
            .vtable = &self.source_changed_vtable,
            .ref_count = 1,
            .parent = self,
        };
        
        self.msg_handler = WebMessageReceivedHandler{
            .vtable = &self.msg_vtable,
            .ref_count = 1,
            .parent = self,
        };
        
        // Store URL from options if provided
        if (options.url) |url| {
            self.url = allocator.dupe(u8, url) catch null;
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        const allocator = self.allocator;
        
        // Clean up message queue
        {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            for (self.message_queue.items) |message| {
                allocator.free(message);
            }
            self.message_queue.deinit();
        }
        
        // Clean up script queue
        {
            self.script_mutex.lock();
            defer self.script_mutex.unlock();
            for (self.script_queue.items) |script| {
                allocator.free(script);
            }
            self.script_queue.deinit();
        }
        
        allocator.free(self.user_data_folder);
        if (self.url) |url| {
            allocator.free(url);
        }
        if (self.pending_navigation) |pending| {
            allocator.free(pending);
        }
        allocator.destroy(self);
    }
    
    pub fn run(self: *Self) !void {
        // Initialize COM
        const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
        if (hr != S_OK and hr != @as(HRESULT, @bitCast(@as(u32, 1)))) { // S_FALSE
            return error.ComInitializationFailed;
        }
        defer CoUninitialize();
        
        // Create window
        try self.createWindow();
        
        // Create WebView2 environment
        try self.createWebView2Environment();
        
        // Message loop - use blocking GetMessage like the original wumpa
        var msg: MSG = undefined;
        while (true) {
            const result = GetMessageW(&msg, null, 0, 0);
            if (result == 0) break; // WM_QUIT
            if (result == -1) continue; // Error
            
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        
        // Clean up
        self.cleanup();
    }
    
    fn createWindow(self: *Self) !void {
        const instance = GetModuleHandleW(null) orelse return error.NoModuleHandle;
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("WumpaWebView");
        
        const wc = WNDCLASSW{
            .style = 0,
            .lpfnWndProc = windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = @sizeOf(*Self),
            .hInstance = instance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = @ptrFromInt(6), // COLOR_WINDOW + 1
            .lpszMenuName = null,
            .lpszClassName = class_name,
        };
        
        if (RegisterClassW(&wc) == 0) {
            return error.WindowClassRegistrationFailed;
        }
        
        // Convert title to UTF-16
        var title_utf16: [256]u16 = undefined;
        const title_len = try std.unicode.utf8ToUtf16Le(&title_utf16, self.options.title);
        title_utf16[title_len] = 0;
        
        self.hwnd = CreateWindowExW(
            0,
            class_name,
            @ptrCast(&title_utf16),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            100, 100, self.options.width, self.options.height,
            null,
            null,
            instance,
            self
        );
        
        if (self.hwnd == null) {
            return error.WindowCreationFailed;
        }
        
        _ = ShowWindow(self.hwnd.?, 1);
    }
    
    fn createWebView2Environment(self: *Self) !void {
        // Create user data folder in temp directory
        const user_data_path = try self.createUserDataFolder();
        const path_len = user_data_path.len;
        
        // Null terminate the path
        self.user_data_folder[path_len] = 0;
        
        // Check if folder existed
        self.user_data_existed = if (std.fs.cwd().access(self.user_data_folder[0..path_len], .{})) |_| true else |_| false;
        
        
        // Convert to UTF-16
        var user_data_utf16: [std.fs.max_path_bytes]u16 = undefined;
        const utf16_len = try std.unicode.utf8ToUtf16Le(&user_data_utf16, self.user_data_folder[0..path_len]);
        user_data_utf16[utf16_len] = 0;
        
        // Create WebView2 environment
        const result = CreateCoreWebView2EnvironmentWithOptions(
            null,
            @ptrCast(&user_data_utf16),
            null,
            @ptrCast(&self.env_handler)
        );
        
        if (result != S_OK) {
            return error.WebView2EnvironmentCreationFailed;
        }
    }
    
    fn createUserDataFolder(self: *Self) ![]const u8 {
        // Get Windows temp directory
        var temp_path_utf16: [std.fs.max_path_bytes]u16 = undefined;
        const temp_len = GetTempPathW(@intCast(temp_path_utf16.len), &temp_path_utf16);
        if (temp_len == 0) {
            return error.TempPathFailed;
        }
        
        // Convert to UTF-8
        var temp_path_utf8: [std.fs.max_path_bytes]u8 = undefined;
        const utf8_len = try std.unicode.utf16LeToUtf8(&temp_path_utf8, temp_path_utf16[0..temp_len]);
        
        // Create unique folder name with timestamp
        const timestamp = std.time.timestamp();
        const user_data_path = try std.fmt.bufPrint(
            self.user_data_folder,
            "{s}wumpa_temp_{}",
            .{ temp_path_utf8[0..utf8_len], timestamp }
        );
        
        return user_data_path;
    }
    
    fn cleanup(self: *Self) void {
        // Mark as shutting down to stop accepting new messages
        self.is_shutting_down = true;
        
        // Process any remaining queued messages
        self.processMessageQueue();
        
        // Remove event handlers before releasing COM objects
        if (self.webview) |webview| {
            if (self.nav_starting_token) |token| {
                const result = webview.vtable.remove_NavigationStarting(webview, token);
                if (result != S_OK) {
                    std.debug.print("remove_NavigationStarting failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                }
                self.nav_starting_token = null;
            }
            
            if (self.nav_completed_token) |token| {
                const result = webview.vtable.remove_NavigationCompleted(webview, token);
                if (result != S_OK) {
                    std.debug.print("remove_NavigationCompleted failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                }
                self.nav_completed_token = null;
            }
            
            if (self.content_loading_token) |token| {
                const result = webview.vtable.remove_ContentLoading(webview, token);
                if (result != S_OK) {
                    std.debug.print("remove_ContentLoading failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                }
                self.content_loading_token = null;
            }
            
            if (self.source_changed_token) |token| {
                const result = webview.vtable.remove_SourceChanged(webview, token);
                if (result != S_OK) {
                    std.debug.print("remove_SourceChanged failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                }
                self.source_changed_token = null;
            }
            
            if (self.msg_received_token) |token| {
                const result = webview.vtable.remove_WebMessageReceived(webview, token);
                if (result != S_OK) {
                    std.debug.print("remove_WebMessageReceived failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                }
                self.msg_received_token = null;
            }
            
            if (self.window_close_token) |token| {
                const result = webview.vtable.remove_WindowCloseRequested(webview, token);
                if (result != S_OK) {
                    std.debug.print("remove_WindowCloseRequested failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                }
                self.window_close_token = null;
            }
        }
        
        // Clean up WebView2 resources in correct order
        if (self.controller) |controller| {
            // Close the controller first
            const close_result = controller.vtable.Close(controller);
            if (close_result != S_OK) {
                std.debug.print("Controller.Close failed: 0x{x}\n", .{@as(u32, @bitCast(close_result))});
            }
            
            // Then release the controller
            const ref_count = controller.vtable.Release(controller);
            std.debug.print("Controller released, ref_count: {}\n", .{ref_count});
            self.controller = null;
        }
        
        if (self.webview) |webview| {
            const ref_count = webview.vtable.Release(webview);
            std.debug.print("WebView released, ref_count: {}\n", .{ref_count});
            self.webview = null;
        }
        
        if (self.environment) |environment| {
            const ref_count = environment.vtable.Release(environment);
            std.debug.print("Environment released, ref_count: {}\n", .{ref_count});
            self.environment = null;
        }
        
        // Clean up user data folder if it didn't exist before
        if (!self.user_data_existed) {
            const folder_path = std.mem.sliceTo(self.user_data_folder, 0);
            
            // Try multiple times with delays
            var attempts: u32 = 0;
            while (attempts < 5) : (attempts += 1) {
                std.time.sleep(100 * std.time.ns_per_ms);
                
                std.fs.cwd().deleteTree(folder_path) catch |err| {
                    if (attempts == 4) {
                        std.debug.print("Warning: Could not delete user data folder after {} attempts: {}\n", .{ attempts + 1, err });
                    }
                    continue;
                };
                
                break;
            }
        }
    }
    
    fn injectJavaScript(self: *Self) void {
        self.injectJavaScriptToWebView(self.webview);
    }
    
    fn injectJavaScriptToWebView(self: *Self, webview: ?*ICoreWebView2) void {
        if (webview) |wv| {
            // Use the injected JavaScript content
            const js_content = self.js_inject orelse "";
            
            if (js_content.len == 0) {
                std.debug.print("No JavaScript to inject\n", .{});
                return;
            }
            
            // Check for null terminator in the content
            const actual_len = std.mem.indexOfScalar(u8, js_content, 0) orelse js_content.len;
            const clean_content = js_content[0..actual_len];
            
            std.debug.print("Injecting {} bytes of JavaScript (cleaned from {})\n", .{clean_content.len, js_content.len});
            if (clean_content.len < 100) {
                std.debug.print("WARNING: JavaScript content appears truncated! First few bytes: ", .{});
                for (clean_content[0..@min(clean_content.len, 10)]) |byte| {
                    std.debug.print("{x:0>2} ", .{byte});
                }
                std.debug.print("\n", .{});
            }
            
            // First inject a simple test to verify injection works
            const test_js = "console.log('WebView2 JavaScript injection test - WORKING!'); window.TURF_TEST = 123;";
            
            // Convert test to UTF-16
            var test_utf16_buffer: [512]u16 = undefined;
            const test_len = std.unicode.utf8ToUtf16Le(&test_utf16_buffer, test_js) catch {
                std.debug.print("Failed to convert test JavaScript to UTF-16\n", .{});
                return;
            };
            test_utf16_buffer[test_len] = 0;
            
            // Execute test script
            const test_result = wv.vtable.ExecuteScript(
                wv,
                @ptrCast(&test_utf16_buffer),
                null
            );
            
            if (test_result != S_OK) {
                std.debug.print("Test ExecuteScript failed: 0x{x}\n", .{@as(u32, @bitCast(test_result))});
                return;
            }
            
            std.debug.print("Test script injected successfully, now injecting main script\n", .{});
            
            // Allocate a large static buffer for UTF-16 conversion
            const utf16_buffer = self.allocator.alloc(u16, clean_content.len * 2) catch {
                std.debug.print("Failed to allocate UTF-16 buffer\n", .{});
                return;
            };
            defer self.allocator.free(utf16_buffer);
            
            // Convert to UTF-16
            const js_len = std.unicode.utf8ToUtf16Le(utf16_buffer, clean_content) catch |err| {
                std.debug.print("Failed to convert to UTF-16: {}\n", .{err});
                return;
            };
            utf16_buffer[js_len] = 0;
            
            std.debug.print("Converted {} bytes to {} UTF-16 code units\n", .{clean_content.len, js_len});
            
            // Execute the script
            const result = wv.vtable.ExecuteScript(
                wv,
                @ptrCast(&utf16_buffer[0]),
                null
            );
            
            if (result != S_OK) {
                std.debug.print("Main ExecuteScript failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                
                // Fallback: inject a minimal turf object
                const fallback = 
                    \\window.turf = {
                    \\    send: function(msg) {
                    \\        if (window.chrome && window.chrome.webview) {
                    \\            window.chrome.webview.postMessage(JSON.stringify(msg));
                    \\        }
                    \\    },
                    \\    onMessage: function() {},
                    \\    test: 'Fallback turf loaded'
                    \\};
                    \\console.log('Fallback turf loaded');
                ;
                
                var fallback_utf16: [1024]u16 = undefined;
                const fallback_len = std.unicode.utf8ToUtf16Le(&fallback_utf16, fallback) catch return;
                fallback_utf16[fallback_len] = 0;
                
                _ = wv.vtable.ExecuteScript(wv, @ptrCast(&fallback_utf16), null);
            } else {
                std.debug.print("Main script injected successfully!\n", .{});
            }
        }
    }
    
    pub fn navigate(self: *Self, url: []const u8) void {
        if (!self.is_ready) {
            // Store the URL to navigate to once ready
            self.pending_navigation = self.allocator.dupe(u8, url) catch {
                std.debug.print("Failed to allocate pending navigation URL\n", .{});
                return;
            };
            return;
        }
        
        if (self.webview) |webview| {
            // Reset page ready flag when navigating
            self.is_page_ready = false;
            
            // Convert URL to UTF-16
            var url_utf16_buffer: [4096]u16 = undefined;
            const url_len = std.unicode.utf8ToUtf16Le(&url_utf16_buffer, url) catch {
                std.debug.print("Failed to convert URL to UTF-16\n", .{});
                return;
            };
            url_utf16_buffer[url_len] = 0;
            
            const result = webview.vtable.Navigate(webview, @ptrCast(&url_utf16_buffer));
            if (result != S_OK) {
                std.debug.print("Navigate failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
            }
        }
    }
    
    pub fn loadFile(self: *Self, path: []const u8) void {
        // Convert to absolute path if needed
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fs.realpath(path, &path_buffer) catch |err| {
            std.debug.print("Failed to resolve path: {}\n", .{err});
            return;
        };
        
        // Build file:/// URL
        var url_buffer: [std.fs.max_path_bytes + 10]u8 = undefined;
        const file_url = std.fmt.bufPrint(&url_buffer, "file:///{s}", .{abs_path}) catch {
            std.debug.print("Failed to format file URL\n", .{});
            return;
        };
        
        // Replace backslashes with forward slashes for file URLs
        for (file_url) |*char| {
            if (char.* == '\\') char.* = '/';
        }
        
        self.navigate(file_url);
    }
    
    pub fn isReady(self: *Self) bool {
        return self.is_ready and self.webview != null;
    }
    
    pub fn isPageReady(self: *Self) bool {
        return self.is_page_ready;
    }
    
    pub fn postMessageAsJson(self: *Self, json: []const u8) void {
        // Check if page is ready to receive messages
        if (!self.is_page_ready) {
            std.debug.print("Page not ready yet, skipping message: {s}\n", .{json});
            return;
        }
        
        if (self.webview) |webview| {
            // Convert JSON to UTF-16
            var json_utf16_buffer: [32768]u16 = undefined;
            const json_len = std.unicode.utf8ToUtf16Le(&json_utf16_buffer, json) catch {
                std.debug.print("Failed to convert JSON to UTF-16\n", .{});
                return;
            };
            json_utf16_buffer[json_len] = 0;
            
            // Successfully sending message
            const result = webview.vtable.PostWebMessageAsJson(webview, @ptrCast(&json_utf16_buffer));
            if (result != S_OK) {
                std.debug.print("PostWebMessageAsJson failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
            }
        }
    }
    
    pub fn executeScript(self: *Self, script: []const u8) void {
        // Queue the script for execution on the UI thread
        self.script_mutex.lock();
        defer self.script_mutex.unlock();
        
        const script_copy = self.allocator.dupe(u8, script) catch {
            std.debug.print("Failed to allocate script copy\n", .{});
            return;
        };
        
        self.script_queue.append(script_copy) catch {
            self.allocator.free(script_copy);
            std.debug.print("Failed to queue script\n", .{});
            return;
        };
        
        // Post a message to process the queue immediately
        if (self.hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_PROCESS_SCRIPT_QUEUE, 0, 0);
        }
    }
    
    fn processScriptQueue(self: *Self) void {
        // Process any queued scripts on the UI thread
        if (!self.is_page_ready or self.webview == null) {
            return;
        }
        
        self.script_mutex.lock();
        defer self.script_mutex.unlock();
        
        while (self.script_queue.items.len > 0) {
            const script = self.script_queue.orderedRemove(0);
            defer self.allocator.free(script);
            
            if (self.webview) |webview| {
                // Convert script to UTF-16
                var script_utf16_buffer: [32768]u16 = undefined;
                const script_len = std.unicode.utf8ToUtf16Le(&script_utf16_buffer, script) catch {
                    std.debug.print("Failed to convert script to UTF-16\n", .{});
                    continue;
                };
                script_utf16_buffer[script_len] = 0;
                
                // Execute the script
                const result = webview.vtable.ExecuteScript(
                    webview,
                    @ptrCast(&script_utf16_buffer),
                    null  // We don't need the result callback
                );
                
                if (result != S_OK) {
                    std.debug.print("ExecuteScript failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
                } else {
                    // std.debug.print("Successfully executed {} bytes of script\n", .{script.len});
                }
            }
        }
    }
    
    // Thread-safe message queueing
    pub fn queueMessage(self: *Self, json: []const u8) !void {
        // Don't accept new messages if shutting down
        if (self.is_shutting_down) {
            return error.ShuttingDown;
        }
        
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        
        // Duplicate the message since it might be from a temporary buffer
        const json_copy = try self.allocator.dupe(u8, json);
        try self.message_queue.append(json_copy);
        
        // Post a message to process the queue immediately
        if (self.hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_PROCESS_MESSAGE_QUEUE, 0, 0);
        }
    }
    
    // Process queued messages from the UI thread
    pub fn processMessageQueue(self: *Self) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        
        while (self.message_queue.items.len > 0) {
            const message = self.message_queue.orderedRemove(0);
            defer self.allocator.free(message);
            
            self.postMessageAsJson(message);
        }
    }
    
    fn windowProc(hwnd: HWND, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) callconv(win.WINAPI) win.LRESULT {
        switch (msg) {
            WM_CREATE => {
                const create_struct: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @intCast(lparam)));
                const webview: *Self = @ptrCast(@alignCast(create_struct.lpCreateParams));
                _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @as(isize, @intCast(@intFromPtr(webview))));
                return 0;
            },
            WM_SIZE => {
                const ptr_value = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
                if (ptr_value != 0) {
                    const self: *Self = @ptrFromInt(@as(usize, @intCast(ptr_value)));
                    if (self.controller) |controller| {
                        var rect: RECT = undefined;
                        _ = GetClientRect(hwnd, &rect);
                        _ = controller.vtable.put_Bounds(controller, rect);
                    }
                }
                return 0;
            },
            WM_CLOSE => {
                const ptr_value = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
                if (ptr_value != 0) {
                    const self: *Self = @ptrFromInt(@as(usize, @intCast(ptr_value)));
                    self.is_shutting_down = true;
                }
                _ = DestroyWindow(hwnd);
                return 0;
            },
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            },
            WM_PROCESS_SCRIPT_QUEUE => {
                const ptr_value = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
                if (ptr_value != 0) {
                    const self: *Self = @ptrFromInt(@as(usize, @intCast(ptr_value)));
                    self.processScriptQueue();
                }
                return 0;
            },
            WM_PROCESS_MESSAGE_QUEUE => {
                const ptr_value = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
                if (ptr_value != 0) {
                    const self: *Self = @ptrFromInt(@as(usize, @intCast(ptr_value)));
                    self.processMessageQueue();
                }
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};

// Additional Windows APIs needed
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(win.WINAPI) isize;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(win.WINAPI) isize;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(win.WINAPI) BOOL;
pub const GWLP_USERDATA = -21;
pub const WM_CREATE = 0x0001;
pub const WM_CLOSE = 0x0010;

// Create struct for window creation
pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: HINSTANCE,
    hMenu: ?win.HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: [*:0]const u16,
    lpszClass: [*:0]const u16,
    dwExStyle: win.DWORD,
};

// Environment completion handler
const EnvironmentHandler = extern struct {
    vtable: *const VTable,
    ref_count: u32,
    parent: *WebView = undefined,

    const VTable = extern struct {
        QueryInterface: *const fn(*EnvironmentHandler, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*EnvironmentHandler) callconv(win.WINAPI) u32,
        Release: *const fn(*EnvironmentHandler) callconv(win.WINAPI) u32,
        Invoke: *const fn(*EnvironmentHandler, HRESULT, *ICoreWebView2Environment) callconv(win.WINAPI) HRESULT,
    };

    fn queryInterface(self: *EnvironmentHandler, riid: *const win.GUID, ppvObject: **anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self; _ = riid; _ = ppvObject;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(self: *EnvironmentHandler) callconv(win.WINAPI) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *EnvironmentHandler) callconv(win.WINAPI) u32 {
        if (self.ref_count > 0) self.ref_count -= 1;
        return self.ref_count;
    }

    fn invoke(self: *EnvironmentHandler, errorCode: HRESULT, environment: *ICoreWebView2Environment) callconv(win.WINAPI) HRESULT {
        if (errorCode != S_OK) return errorCode;
        
        self.parent.environment = environment;
        _ = environment.vtable.AddRef(environment);
        
        
        // Try injecting script right after environment is created
        // This might not work since we don't have webview yet
        
        // Create controller
        const result = environment.vtable.CreateCoreWebView2Controller(
            environment,
            self.parent.hwnd.?,
            @ptrCast(&self.parent.controller_handler)
        );
        _ = result;
        
        return S_OK;
    }
};

// Controller completion handler
const ControllerHandler = extern struct {
    vtable: *const VTable,
    ref_count: u32,
    parent: *WebView = undefined,

    const VTable = extern struct {
        QueryInterface: *const fn(*ControllerHandler, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*ControllerHandler) callconv(win.WINAPI) u32,
        Release: *const fn(*ControllerHandler) callconv(win.WINAPI) u32,
        Invoke: *const fn(*ControllerHandler, HRESULT, *ICoreWebView2Controller) callconv(win.WINAPI) HRESULT,
    };

    fn queryInterface(self: *ControllerHandler, riid: *const win.GUID, ppvObject: **anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self; _ = riid; _ = ppvObject;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(self: *ControllerHandler) callconv(win.WINAPI) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *ControllerHandler) callconv(win.WINAPI) u32 {
        if (self.ref_count > 0) self.ref_count -= 1;
        return self.ref_count;
    }

    fn invoke(self: *ControllerHandler, errorCode: HRESULT, controller: *ICoreWebView2Controller) callconv(win.WINAPI) HRESULT {
        if (errorCode != S_OK) return errorCode;
        
        self.parent.controller = controller;
        _ = controller.vtable.AddRef(controller);
        
        // Get WebView2
        var webview: ?*ICoreWebView2 = null;
        const hr = controller.vtable.get_CoreWebView2(controller, @ptrCast(&webview));
        
        if (hr == S_OK and webview != null) {
            self.parent.webview = webview.?;
            _ = webview.?.vtable.AddRef(webview.?);
            
            // Set bounds
            var rect: RECT = undefined;
            _ = GetClientRect(self.parent.hwnd.?, &rect);
            _ = controller.vtable.put_Bounds(controller, rect);
            
            // Make visible
            _ = controller.vtable.put_IsVisible(controller, TRUE);
            
            // Add navigation starting handler
            var nav_starting_token: EventRegistrationToken = undefined;
            const nav_starting_result = webview.?.vtable.add_NavigationStarting(
                webview.?,
                @ptrCast(&self.parent.nav_starting_handler),
                &nav_starting_token
            );
            if (nav_starting_result == S_OK) {
                self.parent.nav_starting_token = nav_starting_token;
                std.debug.print("add_NavigationStarting succeeded\n", .{});
            } else {
                std.debug.print("add_NavigationStarting failed: 0x{x}\n", .{@as(u32, @bitCast(nav_starting_result))});
            }
            
            // Add content loading handler
            var content_loading_token: EventRegistrationToken = undefined;
            const content_loading_result = webview.?.vtable.add_ContentLoading(
                webview.?,
                @ptrCast(&self.parent.content_loading_handler),
                &content_loading_token
            );
            if (content_loading_result == S_OK) {
                self.parent.content_loading_token = content_loading_token;
                std.debug.print("add_ContentLoading succeeded\n", .{});
            } else {
                std.debug.print("add_ContentLoading failed: 0x{x}\n", .{@as(u32, @bitCast(content_loading_result))});
            }
            
            // Add source changed handler
            var source_changed_token: EventRegistrationToken = undefined;
            const source_changed_result = webview.?.vtable.add_SourceChanged(
                webview.?,
                @ptrCast(&self.parent.source_changed_handler),
                &source_changed_token
            );
            if (source_changed_result == S_OK) {
                self.parent.source_changed_token = source_changed_token;
                std.debug.print("add_SourceChanged succeeded\n", .{});
            } else {
                std.debug.print("add_SourceChanged failed: 0x{x}\n", .{@as(u32, @bitCast(source_changed_result))});
            }
            
            // Add navigation completed handler to inject JavaScript after each page loads
            var token: EventRegistrationToken = undefined;
            const nav_handler_result = webview.?.vtable.add_NavigationCompleted(
                webview.?,
                @ptrCast(&self.parent.nav_handler),
                &token
            );
            if (nav_handler_result == S_OK) {
                self.parent.nav_completed_token = token;
                std.debug.print("add_NavigationCompleted succeeded\n", .{});
            } else {
                std.debug.print("add_NavigationCompleted failed: 0x{x}\n", .{@as(u32, @bitCast(nav_handler_result))});
            }
            
            // Add WebMessage received handler
            var msg_token: EventRegistrationToken = undefined;
            const msg_handler_result = webview.?.vtable.add_WebMessageReceived(
                webview.?,
                @ptrCast(&self.parent.msg_handler),
                &msg_token
            );
            if (msg_handler_result == S_OK) {
                self.parent.msg_received_token = msg_token;
                std.debug.print("add_WebMessageReceived succeeded\n", .{});
            } else {
                std.debug.print("add_WebMessageReceived failed: 0x{x}\n", .{@as(u32, @bitCast(msg_handler_result))});
            }
            
            // Mark as ready before navigation
            self.parent.is_ready = true;
            
            // Check for pending navigation first
            if (self.parent.pending_navigation) |pending_url| {
                defer self.parent.allocator.free(pending_url);
                self.parent.pending_navigation = null;
                self.parent.navigate(pending_url);
                return S_OK;
            }
            
            // Navigate to content
            if (self.parent.url) |url| {
                std.debug.print("Navigating to URL from options: {s}\n", .{url});
                // Navigate to URL
                var url_utf16_buffer: [4096]u16 = undefined;
                const url_len = std.unicode.utf8ToUtf16Le(&url_utf16_buffer, url) catch {
                    std.debug.print("Failed to convert URL to UTF-16\n", .{});
                    return S_OK;
                };
                url_utf16_buffer[url_len] = 0;
                const nav_result = webview.?.vtable.Navigate(webview.?, @ptrCast(&url_utf16_buffer));
                std.debug.print("Navigate result: 0x{x}\n", .{@as(u32, @bitCast(nav_result))});
            } else if (self.parent.options.html) |html| {
                // Navigate to HTML string
                var html_utf16_buffer: [32768]u16 = undefined;
                const html_len = std.unicode.utf8ToUtf16Le(&html_utf16_buffer, html) catch {
                    return S_OK;
                };
                html_utf16_buffer[html_len] = 0;
                _ = webview.?.vtable.NavigateToString(webview.?, @ptrCast(&html_utf16_buffer));
                
                // Inject JavaScript immediately for NavigateToString
                // NavigateToString loads synchronously so we can inject right away
                self.parent.injectJavaScript();
            } else {
                // Default hello page
                const default_html = std.unicode.utf8ToUtf16LeStringLiteral("<html><body style='font-family:Arial;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;font-size:3em'>hello</body></html>");
                _ = webview.?.vtable.NavigateToString(webview.?, default_html);
                
                // Inject JavaScript immediately
                self.parent.injectJavaScript();
            }
        }
        
        return S_OK;
    }
};

// Navigation completed handler to inject JavaScript
const NavigationCompletedHandler = extern struct {
    vtable: *const VTable,
    ref_count: u32,
    parent: *WebView = undefined,

    const VTable = extern struct {
        QueryInterface: *const fn(*NavigationCompletedHandler, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*NavigationCompletedHandler) callconv(win.WINAPI) u32,
        Release: *const fn(*NavigationCompletedHandler) callconv(win.WINAPI) u32,
        Invoke: *const fn(*NavigationCompletedHandler, *ICoreWebView2, *anyopaque) callconv(win.WINAPI) HRESULT,
    };

    fn queryInterface(self: *NavigationCompletedHandler, riid: *const win.GUID, ppvObject: **anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self; _ = riid; _ = ppvObject;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(self: *NavigationCompletedHandler) callconv(win.WINAPI) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *NavigationCompletedHandler) callconv(win.WINAPI) u32 {
        if (self.ref_count > 0) self.ref_count -= 1;
        return self.ref_count;
    }

    fn invoke(self: *NavigationCompletedHandler, sender: *ICoreWebView2, args: *anyopaque) callconv(win.WINAPI) HRESULT {
        _ = args;
        std.debug.print("NavigationCompleted event fired\n", .{});
        
        // Mark page as ready
        self.parent.is_page_ready = true;
        
        // Inject the JavaScript that was passed to us using the sender
        self.parent.injectJavaScriptToWebView(sender);
        
        return S_OK;
    }
};

// Navigation starting handler
const NavigationStartingHandler = extern struct {
    vtable: *const VTable,
    ref_count: u32,
    parent: *WebView = undefined,

    const VTable = extern struct {
        QueryInterface: *const fn(*NavigationStartingHandler, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*NavigationStartingHandler) callconv(win.WINAPI) u32,
        Release: *const fn(*NavigationStartingHandler) callconv(win.WINAPI) u32,
        Invoke: *const fn(*NavigationStartingHandler, *ICoreWebView2, *anyopaque) callconv(win.WINAPI) HRESULT,
    };

    fn queryInterface(self: *NavigationStartingHandler, riid: *const win.GUID, ppvObject: **anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self; _ = riid; _ = ppvObject;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(self: *NavigationStartingHandler) callconv(win.WINAPI) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *NavigationStartingHandler) callconv(win.WINAPI) u32 {
        if (self.ref_count > 0) self.ref_count -= 1;
        return self.ref_count;
    }

    fn invoke(self: *NavigationStartingHandler, sender: *ICoreWebView2, args: *anyopaque) callconv(win.WINAPI) HRESULT {
        _ = sender;
        _ = args;
        std.debug.print("NavigationStarting event fired\n", .{});
        
        // Reset page ready flag when starting new navigation
        self.parent.is_page_ready = false;
        
        return S_OK;
    }
};

// Content loading handler (similar to DOMContentLoaded)
const ContentLoadingHandler = extern struct {
    vtable: *const VTable,
    ref_count: u32,
    parent: *WebView = undefined,

    const VTable = extern struct {
        QueryInterface: *const fn(*ContentLoadingHandler, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*ContentLoadingHandler) callconv(win.WINAPI) u32,
        Release: *const fn(*ContentLoadingHandler) callconv(win.WINAPI) u32,
        Invoke: *const fn(*ContentLoadingHandler, *ICoreWebView2, *anyopaque) callconv(win.WINAPI) HRESULT,
    };

    fn queryInterface(self: *ContentLoadingHandler, riid: *const win.GUID, ppvObject: **anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self; _ = riid; _ = ppvObject;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(self: *ContentLoadingHandler) callconv(win.WINAPI) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *ContentLoadingHandler) callconv(win.WINAPI) u32 {
        if (self.ref_count > 0) self.ref_count -= 1;
        return self.ref_count;
    }

    fn invoke(self: *ContentLoadingHandler, sender: *ICoreWebView2, args: *anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self;
        _ = sender;
        _ = args;
        std.debug.print("ContentLoading event fired - DOM is ready\n", .{});
        
        return S_OK;
    }
};

// Source changed handler
const SourceChangedHandler = extern struct {
    vtable: *const VTable,
    ref_count: u32,
    parent: *WebView = undefined,

    const VTable = extern struct {
        QueryInterface: *const fn(*SourceChangedHandler, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*SourceChangedHandler) callconv(win.WINAPI) u32,
        Release: *const fn(*SourceChangedHandler) callconv(win.WINAPI) u32,
        Invoke: *const fn(*SourceChangedHandler, *ICoreWebView2, *anyopaque) callconv(win.WINAPI) HRESULT,
    };

    fn queryInterface(self: *SourceChangedHandler, riid: *const win.GUID, ppvObject: **anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self; _ = riid; _ = ppvObject;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(self: *SourceChangedHandler) callconv(win.WINAPI) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *SourceChangedHandler) callconv(win.WINAPI) u32 {
        if (self.ref_count > 0) self.ref_count -= 1;
        return self.ref_count;
    }

    fn invoke(self: *SourceChangedHandler, sender: *ICoreWebView2, args: *anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self;
        _ = sender;
        _ = args;
        std.debug.print("SourceChanged event fired\n", .{});
        
        return S_OK;
    }
};

// WebMessage received handler
const WebMessageReceivedHandler = extern struct {
    vtable: *const VTable,
    ref_count: u32,
    parent: *WebView = undefined,

    const VTable = extern struct {
        QueryInterface: *const fn(*WebMessageReceivedHandler, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*WebMessageReceivedHandler) callconv(win.WINAPI) u32,
        Release: *const fn(*WebMessageReceivedHandler) callconv(win.WINAPI) u32,
        Invoke: *const fn(*WebMessageReceivedHandler, *ICoreWebView2, *ICoreWebView2WebMessageReceivedEventArgs) callconv(win.WINAPI) HRESULT,
    };

    fn queryInterface(self: *WebMessageReceivedHandler, riid: *const win.GUID, ppvObject: **anyopaque) callconv(win.WINAPI) HRESULT {
        _ = self; _ = riid; _ = ppvObject;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(self: *WebMessageReceivedHandler) callconv(win.WINAPI) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *WebMessageReceivedHandler) callconv(win.WINAPI) u32 {
        if (self.ref_count > 0) self.ref_count -= 1;
        return self.ref_count;
    }

    fn invoke(self: *WebMessageReceivedHandler, sender: *ICoreWebView2, args: *ICoreWebView2WebMessageReceivedEventArgs) callconv(win.WINAPI) HRESULT {
        _ = sender;
        _ = self;
        
        // Try to get the message as string
        var message: ?[*:0]u16 = null;
        const result = args.vtable.TryGetWebMessageAsString(args, &message);
        
        if (result == S_OK and message != null) {
            // Convert from UTF-16 to UTF-8
            const message_slice = std.mem.span(message.?);
            var utf8_buffer: [4096]u8 = undefined;
            const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buffer, message_slice) catch {
                return S_OK;
            };
            
            const message_str = utf8_buffer[0..utf8_len];
            std.debug.print("Received message from JavaScript: {s}\n", .{message_str});
            
            // Call the backend's message handler
            @import("backend.zig").onJavaScriptMessage(message_str);
        }
        
        return S_OK;
    }
};

// WebMessageReceivedEventArgs interface
const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    vtable: *const VTable,
    
    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn(*ICoreWebView2WebMessageReceivedEventArgs, *const win.GUID, **anyopaque) callconv(win.WINAPI) HRESULT,
        AddRef: *const fn(*ICoreWebView2WebMessageReceivedEventArgs) callconv(win.WINAPI) u32,
        Release: *const fn(*ICoreWebView2WebMessageReceivedEventArgs) callconv(win.WINAPI) u32,
        
        // ICoreWebView2WebMessageReceivedEventArgs methods
        get_Source: *const fn(*ICoreWebView2WebMessageReceivedEventArgs, *?[*:0]u16) callconv(win.WINAPI) HRESULT,
        get_WebMessageAsJson: *const fn(*ICoreWebView2WebMessageReceivedEventArgs, *?[*:0]u16) callconv(win.WINAPI) HRESULT,
        TryGetWebMessageAsString: *const fn(*ICoreWebView2WebMessageReceivedEventArgs, *?[*:0]u16) callconv(win.WINAPI) HRESULT,
    };
};

