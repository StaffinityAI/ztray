//! Win32 HWND: DWM acrylic/Mica-style backdrop, extended client into caption, hit-testing.
//! First argument to public APIs is `HWND` as `*anyopaque` (e.g. from SDL `SDL_PROP_WINDOW_WIN32_HWND_POINTER`).

const win32 = @import("win32");
const common = @import("window_common.zig");

extern "kernel32" fn FreeLibrary(hModule: ?win32.foundation.HINSTANCE) callconv(.winapi) i32;

// Windows 11 (Build 22621+): System backdrop and extended frame for title bar drawing.
const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38; // Windows 11 SDK
const DWMSBT_TRANSIENTWINDOW: u32 = 3; // Acrylic (frosted glass)

// Layered window for whole-window opacity (LWA_ALPHA). Works with SDL's GPU renderer.
const WS_EX_LAYERED: u32 = 0x00080000;

// Undocumented user32 API for acrylic blur (used by Start menu, taskbar). Loaded at runtime.
const WCA_ACCENT_POLICY: u32 = 19;
const ACCENT_ENABLE_ACRYLICBLURBEHIND: u32 = 4;
const WINCOMPATTR_DATA = struct {
    attrib: u32,
    pv_data: *const anyopaque,
    cb_data: usize,
};
const ACCENT_POLICY = struct {
    accent_state: u32,
    accent_flags: u32,
    gradient_color: u32, // ABGR
    animation_id: u32,
};

const win32_mica_margins = win32.ui.controls.MARGINS{
    .cxLeftWidth = -1,
    .cxRightWidth = -1,
    .cyTopHeight = -1,
    .cyBottomHeight = -1,
};

const win32_mica_subclass_id: usize = 0x50584931; // "PXI1"

fn applyWin32AcrylicAccent(hwnd: win32.foundation.HWND) void {
    const user32_mod = win32.system.library_loader.LoadLibraryA("user32.dll") orelse return;
    defer _ = FreeLibrary(user32_mod);

    const proc = win32.system.library_loader.GetProcAddress(user32_mod, "SetWindowCompositionAttribute") orelse return;
    const SetWindowCompositionAttribute: *const fn (win32.foundation.HWND, *const WINCOMPATTR_DATA) callconv(.winapi) i32 = @ptrCast(proc);
    var policy = ACCENT_POLICY{
        .accent_state = ACCENT_ENABLE_ACRYLICBLURBEHIND,
        .accent_flags = 0,
        .gradient_color = 0xE6_00_00_00, // ABGR: dark tint so blur is visible
        .animation_id = 0,
    };
    var data = WINCOMPATTR_DATA{
        .attrib = WCA_ACCENT_POLICY,
        .pv_data = @ptrCast(&policy),
        .cb_data = @sizeOf(ACCENT_POLICY),
    };
    _ = SetWindowCompositionAttribute(hwnd, &data);
}

const WM_NCCALCSIZE: u32 = 0x0083;
const WM_NCHITTEST: u32 = 0x0084;
const HTCAPTION: i32 = 2;
const HTLEFT: i32 = 10;
const HTRIGHT: i32 = 11;
const HTTOP: i32 = 12;
const HTTOPLEFT: i32 = 13;
const HTTOPRIGHT: i32 = 14;
const HTBOTTOM: i32 = 15;
const HTBOTTOMLEFT: i32 = 16;
const HTBOTTOMRIGHT: i32 = 17;
const HTMINBUTTON: i32 = 8;
const HTMAXBUTTON: i32 = 9;
const HTCLOSE: i32 = 20;
const SM_CXSIZEFRAME: u32 = 32;
const SM_CYSIZEFRAME: u32 = 33;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_NCLBUTTONUP: u32 = 0x00A2;
const WM_NCMOUSEMOVE: u32 = 0x00A0;

/// System caption button width (SM_CXSIZE / index 30), with a minimum so hit-testing and layout stay aligned.
fn captionButtonWidth() i32 {
    var w = win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @fromBackingInt(@intCast(30))));
    if (w < 40) w = 40;
    return w;
}

fn win32CaptionButtonHit(hWnd: ?win32.foundation.HWND, client_x: i32, client_y: i32) ?i32 {
    var rect: win32.foundation.RECT = undefined;
    if (win32.ui.windows_and_messaging.GetClientRect(hWnd, &rect) == 0) return null;
    const caption_h = win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @fromBackingInt(@intCast(4))));
    const btn_w = captionButtonWidth();
    const right = rect.right;
    if (client_y >= 0 and client_y < caption_h and client_x >= right - 3 * btn_w) {
        if (client_x >= right - btn_w) return HTCLOSE;
        if (client_x >= right - 2 * btn_w) return HTMAXBUTTON;
        return HTMINBUTTON;
    }
    return null;
}

fn win32MicaSubclassProc(
    hWnd: ?win32.foundation.HWND,
    uMsg: u32,
    wParam: usize,
    lParam: isize,
    uIdSubclass: usize,
    dwRefData: usize,
) callconv(.winapi) isize {
    _ = uIdSubclass;
    _ = dwRefData;
    if (uMsg == win32.ui.windows_and_messaging.WM_ACTIVATE or
        uMsg == win32.ui.windows_and_messaging.WM_DWMCOMPOSITIONCHANGED)
    {
        const backdrop_type: u32 = DWMSBT_TRANSIENTWINDOW;
        _ = win32.graphics.dwm.DwmSetWindowAttribute(
            hWnd,
            @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @fromBackingInt(@intCast(DWMWA_SYSTEMBACKDROP_TYPE))),
            &backdrop_type,
            @sizeOf(u32),
        );
        _ = win32.graphics.dwm.DwmExtendFrameIntoClientArea(hWnd, &win32_mica_margins);
    }
    if (uMsg == WM_NCCALCSIZE and wParam != 0) {
        const params = @as(*win32.ui.windows_and_messaging.NCCALCSIZE_PARAMS, @ptrFromInt(@as(usize, @intCast(lParam))));
        if (win32.ui.windows_and_messaging.IsZoomed(hWnd) != 0) {
            const hmon = win32.graphics.gdi.MonitorFromWindow(hWnd, win32.graphics.gdi.MONITOR_DEFAULTTONEAREST);
            var mi: win32.graphics.gdi.MONITORINFO = undefined;
            mi.cbSize = @sizeOf(win32.graphics.gdi.MONITORINFO);
            if (win32.graphics.gdi.GetMonitorInfoW(hmon, &mi) != 0) {
                params.rgrc[0] = mi.rcWork;
            }
        }
        return 0;
    }
    if (uMsg == WM_NCHITTEST) {
        const def = win32.ui.shell.DefSubclassProc(hWnd, uMsg, wParam, lParam);
        const lp = @as(isize, lParam);
        const x = @as(i32, @as(i16, @truncate(lp)));
        const y = @as(i32, @as(i16, @truncate(lp >> 16)));
        var rect: win32.foundation.RECT = undefined;
        if (win32.ui.windows_and_messaging.GetWindowRect(hWnd, &rect) == 0) return def;
        const top = rect.top;
        const bottom = rect.bottom;
        const left = rect.left;
        const right = rect.right;
        if (x < left or x >= right or y < top or y >= bottom) return def;

        const frame_w = @max(win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @fromBackingInt(@intCast(SM_CXSIZEFRAME)))), 4);
        const frame_h = @max(win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @fromBackingInt(@intCast(SM_CYSIZEFRAME)))), 4);
        const caption_h = win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @fromBackingInt(@intCast(4))));
        const btn_w = captionButtonWidth();

        if (x < left + frame_w) {
            if (y < top + frame_h) return @as(isize, @intCast(HTTOPLEFT));
            if (y >= bottom - frame_h) return @as(isize, @intCast(HTBOTTOMLEFT));
            return @as(isize, @intCast(HTLEFT));
        }
        if (x >= right - frame_w) {
            if (y < top + frame_h) return @as(isize, @intCast(HTTOPRIGHT));
            if (y >= bottom - frame_h) return @as(isize, @intCast(HTBOTTOMRIGHT));
            return @as(isize, @intCast(HTRIGHT));
        }
        if (y >= bottom - frame_h) {
            if (x < left + frame_w) return @as(isize, @intCast(HTBOTTOMLEFT));
            if (x >= right - frame_w) return @as(isize, @intCast(HTBOTTOMRIGHT));
            return @as(isize, @intCast(HTBOTTOM));
        }
        if (y < top + frame_h) return @as(isize, @intCast(HTTOP));

        if (y < top + caption_h) {
            if (x >= right - 3 * btn_w) {
                if (x >= right - btn_w) return @as(isize, @intCast(HTCLOSE));
                if (x >= right - 2 * btn_w) return @as(isize, @intCast(HTMAXBUTTON));
                return @as(isize, @intCast(HTMINBUTTON));
            }
            return @as(isize, @intCast(HTCAPTION));
        }
        return def;
    }
    if (uMsg == WM_LBUTTONDOWN or uMsg == WM_LBUTTONUP or uMsg == WM_MOUSEMOVE) {
        const lp = @as(isize, lParam);
        const client_x = @as(i32, @as(i16, @truncate(lp)));
        const client_y = @as(i32, @as(i16, @truncate(lp >> 16)));
        if (win32CaptionButtonHit(hWnd, client_x, client_y)) |hit_code| {
            var pt = win32.foundation.POINT{ .x = client_x, .y = client_y };
            if (win32.graphics.gdi.ClientToScreen(hWnd, &pt) != 0) {
                const x16 = @as(u16, @bitCast(@as(i16, @intCast(pt.x))));
                const y16 = @as(u16, @bitCast(@as(i16, @intCast(pt.y))));
                const nc_lparam: isize = @intCast((@as(u32, x16)) | (@as(u32, y16) << 16));
                const nc_msg = switch (uMsg) {
                    WM_LBUTTONDOWN => WM_NCLBUTTONDOWN,
                    WM_LBUTTONUP => WM_NCLBUTTONUP,
                    WM_MOUSEMOVE => WM_NCMOUSEMOVE,
                    else => unreachable,
                };
                return win32.ui.windows_and_messaging.DefWindowProcW(hWnd, nc_msg, @as(usize, @intCast(hit_code)), nc_lparam);
            }
        }
    }
    return win32.ui.shell.DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

/// DWM acrylic-style backdrop, extended frame, subclass for caption hit-test. `window` is `HWND`.
pub fn applyTransparentTitlebar(window: *anyopaque) void {
    const hwnd_h: win32.foundation.HWND = @ptrCast(window);

    const backdrop_type: u32 = DWMSBT_TRANSIENTWINDOW;
    _ = win32.graphics.dwm.DwmSetWindowAttribute(
        hwnd_h,
        @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @fromBackingInt(@intCast(DWMWA_SYSTEMBACKDROP_TYPE))),
        &backdrop_type,
        @sizeOf(u32),
    );

    _ = win32.ui.shell.SetWindowSubclass(hwnd_h, win32MicaSubclassProc, win32_mica_subclass_id, 0);

    _ = win32.graphics.dwm.DwmExtendFrameIntoClientArea(hwnd_h, &win32_mica_margins);

    applyWin32AcrylicAccent(hwnd_h);

    const black_brush = win32.graphics.gdi.GetStockObject(win32.graphics.gdi.GET_STOCK_OBJECT_FLAGS.BLACK_BRUSH);
    _ = win32.ui.windows_and_messaging.SetClassLongPtrW(
        hwnd_h,
        win32.ui.windows_and_messaging.GCLP_HBRBACKGROUND,
        @as(isize, @bitCast(@intFromPtr(black_brush))),
    );

    const exstyle = win32.ui.windows_and_messaging.GetWindowLongPtrW(hwnd_h, win32.ui.windows_and_messaging.GWL_EXSTYLE);
    _ = win32.ui.windows_and_messaging.SetWindowLongPtrW(hwnd_h, win32.ui.windows_and_messaging.GWL_EXSTYLE, exstyle | WS_EX_LAYERED);

    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_FRAMECHANGED: u32 = 0x0020;
    const swp_flags = @as(win32.ui.windows_and_messaging.SET_WINDOW_POS_FLAGS, @bitCast(SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED));
    _ = win32.ui.windows_and_messaging.SetWindowPos(hwnd_h, null, 0, 0, 0, 0, swp_flags);
}

/// Re-applies backdrop styling then clears caption/border tint and sets full window opacity to 255. RGBA/dark are ignored (SDL-friendly).
fn setVibrantChrome(window: *anyopaque, _: f64, _: f64, _: f64, _: f64, _: bool) void {
    const hwnd_h: win32.foundation.HWND = @ptrCast(window);

    applyTransparentTitlebar(window);

    const color_none: u32 = win32.graphics.dwm.DWMWA_COLOR_NONE;
    _ = win32.graphics.dwm.DwmSetWindowAttribute(hwnd_h, win32.graphics.dwm.DWMWA_CAPTION_COLOR, &color_none, @sizeOf(u32));
    _ = win32.graphics.dwm.DwmSetWindowAttribute(hwnd_h, win32.graphics.dwm.DWMWA_BORDER_COLOR, &color_none, @sizeOf(u32));

    _ = win32.ui.windows_and_messaging.SetLayeredWindowAttributes(
        hwnd_h,
        @bitCast(@as(u32, 0)),
        255,
        win32.ui.windows_and_messaging.LWA_ALPHA,
    );
}

pub fn titleBarButtonAt(hwnd: *anyopaque, client_x: i32, client_y: i32) ?common.TitleBarButton {
    const h: win32.foundation.HWND = @ptrCast(hwnd);
    var rect: win32.foundation.RECT = undefined;
    if (win32.ui.windows_and_messaging.GetClientRect(h, &rect) == 0) return null;
    const caption_h = win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @fromBackingInt(@intCast(4))));
    const btn_w = captionButtonWidth();
    const width = rect.right;
    if (client_y < 0 or client_y >= caption_h) return null;
    if (client_x < width - 3 * btn_w) return null;
    if (client_x >= width - btn_w) return .close;
    if (client_x >= width - 2 * btn_w) return .maximize;
    return .minimize;
}

pub fn performTitleBarButton(hwnd: *anyopaque, button: common.TitleBarButton) void {
    const hwnd_h: win32.foundation.HWND = @ptrCast(hwnd);
    const WM_SYSCOMMAND: u32 = 0x0112;
    const SC_MINIMIZE: usize = 0xF020;
    const SC_MAXIMIZE: usize = 0xF030;
    const SC_RESTORE: usize = 0xF120;
    const SC_CLOSE: usize = 0xF060;
    const wparam: usize = switch (button) {
        .minimize => SC_MINIMIZE,
        .maximize => if (win32.ui.windows_and_messaging.IsZoomed(hwnd_h) != 0) SC_RESTORE else SC_MAXIMIZE,
        .close => SC_CLOSE,
    };
    _ = win32.ui.windows_and_messaging.PostMessageW(hwnd_h, WM_SYSCOMMAND, wparam, 0);
}

pub fn titleBarButtonWidth() i32 {
    return captionButtonWidth();
}

pub fn setFrameChrome(window: *anyopaque, chrome: common.FrameChrome) void {
    setVibrantChrome(window, chrome.r, chrome.g, chrome.b, chrome.a, chrome.dark);
}
