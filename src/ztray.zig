//! System tray icon + context menu: macOS NSStatusItem, Win32 Shell_NotifyIcon, Linux StatusNotifierItem.
//!
//! Types (`Item`, `Menu`, `Shortcut`, etc.) are re-exported from **zmenu** — identical types across both modules.
//! Call [`pumpEvents`] each frame; on Linux it dispatches the shared D-Bus connection.
//!
//! ## Threading
//!
//! Call `installTrayIcon`, `setTrayMenu`, `pollTrayActionId`, `pumpEvents`, and `shutdownTray`
//! on the owning UI thread. The native backends share mutable process-global state and are not
//! safe for concurrent calls.
const std = @import("std");
const builtin = @import("builtin");

const zmenu = @import("zmenu");

pub const ActionId = zmenu.ActionId;
pub const ShortcutKey = zmenu.ShortcutKey;
pub const Shortcut = zmenu.Shortcut;
pub const Item = zmenu.Item;
pub const Menu = zmenu.Menu;
pub const TrayMenu = zmenu.Menu;

pub const zig_favicon_png = @embedFile("zig-favicon.png");

pub const TrayIconOptions = struct {
    tooltip: []const u8,
    icon_png: ?[]const u8 = null,
    icon_file: ?[]const u8 = null,
    linux_icon_name: ?[]const u8 = null,
    windows_hwnd: ?*anyopaque = null,
};

pub const InstallTrayIconError = error{ TrayInstallFailed, TrayAlreadyInstalled, OutOfMemory, InvalidWtf8 };
pub const SetTrayMenuError = error{ OutOfMemory, MenuInstallFailed, ActionIdOutOfRange, DBusUnavailable, InvalidWtf8, MenuTooLarge };

pub fn pumpEvents() void {
    switch (builtin.os.tag) {
        .linux => linuxPumpDBus(),
        .macos => macos.pump(),
        .windows => winPumpTray(),
        else => {},
    }
}

pub fn installTrayIcon(allocator: std.mem.Allocator, options: TrayIconOptions) InstallTrayIconError!void {
    switch (builtin.os.tag) {
        .macos => return macos.installTrayIcon(allocator, options.tooltip, options.icon_file, options.icon_png),
        .windows => return winInstallTrayIcon(allocator, @ptrCast(options.windows_hwnd orelse null), options.tooltip, options.icon_file, options.icon_png),
        .linux => {
            if (options.linux_icon_name == null and options.icon_file != null) {
                std.log.debug("ztray: icon_file ignored on Linux; set linux_icon_name for Freedesktop icon name", .{});
            }
            return linuxInstallTrayIcon(allocator, options.tooltip, options.linux_icon_name, options.icon_png);
        },
        else => return error.TrayInstallFailed,
    }
}

pub fn setTrayMenu(allocator: std.mem.Allocator, menu: TrayMenu) SetTrayMenuError!void {
    try zmenu.validateMenu(menu);
    switch (builtin.os.tag) {
        .macos => return macos.setTrayMenu(allocator, menu),
        .windows => return winSetTrayMenu(allocator, menu),
        .linux => return linuxSetTrayMenu(allocator, menu),
        else => return error.MenuInstallFailed,
    }
}

/// Returns and clears the last tray action id, or null if none.
///
/// The tray retains one pending action. If multiple actions occur before polling,
/// the latest action replaces earlier unpolled actions.
pub fn pollTrayActionId() ?ActionId {
    const id: c_int = switch (builtin.os.tag) {
        .macos => macos.pollTrayActionId(),
        .windows => winPollTrayActionId(),
        .linux => linuxPollTrayActionId(),
        else => -1,
    };
    if (id < 0) return null;
    return id;
}

pub fn pollTrayAction(comptime T: type) ?T {
    const id = pollTrayActionId() orelse return null;
    return std.enums.fromInt(T, id);
}

pub fn shutdownTray() void {
    switch (builtin.os.tag) {
        .macos => macos.shutdown(),
        .windows => winShutdownTray(),
        .linux => linuxShutdownTray(),
        else => {},
    }
}

pub fn trayIcon(tooltip: []const u8, icon_png: []const u8, linux_icon_name: []const u8) TrayIconOptions {
    return .{
        .tooltip = tooltip,
        .icon_png = if (builtin.os.tag == .linux) null else icon_png,
        .linux_icon_name = if (builtin.os.tag == .linux) linux_icon_name else null,
    };
}

pub const windows = struct {
    pub const tray_action_id_max: u16 = 0xFFFF - 0x7580;
};

// ── macOS tray ────────────────────────────────────────────────────────────────

const macos = struct {
    extern fn ZTrayMacOSTrayInstall(tooltip: [*:0]const u8, icon_path_utf8_or_null: ?[*:0]const u8, png_bytes: ?[*]const u8, png_len: usize) bool;
    extern fn ZTrayMacOSTrayBeginMenuUpdate() bool;
    extern fn ZTrayMacOSTrayCommitMenuUpdate() bool;
    extern fn ZTrayMacOSTrayCancelMenuUpdate() void;
    extern fn ZTrayMacOSTrayAddItem(title: [*:0]const u8, action_id: c_int, key: [*:0]const u8, modifiers: u32, enabled: bool) callconv(.c) bool;
    extern fn ZTrayMacOSTrayAddSeparator() callconv(.c) bool;
    extern fn ZTrayMacOSTrayPollAction() c_int;
    extern fn ZTrayMacOSTrayShutdown() void;
    extern fn ZTrayMacOSPumpEventsTimeoutMs(ms: c_uint) void;

    var active: std.atomic.Value(bool) = .init(false);

    pub fn installTrayIcon(allocator: std.mem.Allocator, tooltip: []const u8, icon_file: ?[]const u8, icon_png: ?[]const u8) InstallTrayIconError!void {
        if (!@This().active.swap(true, .acq_rel)) {} else return error.TrayAlreadyInstalled;
        errdefer _ = @This().active.store(false, .release);

        const tip_z = try allocator.dupeSentinel(u8, tooltip, 0);
        defer allocator.free(tip_z);
        const icon_z: ?[:0]u8 = if (icon_file) |p| try allocator.dupeSentinel(u8, p, 0) else null;
        defer if (icon_z) |z| allocator.free(z);
        const png = icon_png orelse "";
        const png_ptr: ?[*]const u8 = if (png.len > 0) png.ptr else null;

        if (!ZTrayMacOSTrayInstall(tip_z.ptr, if (icon_z) |z| z.ptr else null, png_ptr, png.len)) {
            _ = @This().active.store(false, .release);
            return error.TrayInstallFailed;
        }
    }

    pub fn setTrayMenu(allocator: std.mem.Allocator, menu: TrayMenu) SetTrayMenuError!void {
        if (!@This().active.load(.acquire)) return error.MenuInstallFailed;
        if (!ZTrayMacOSTrayBeginMenuUpdate()) return error.MenuInstallFailed;
        errdefer ZTrayMacOSTrayCancelMenuUpdate();
        for (menu.items) |item| {
            switch (item) {
                .separator => {
                    if (!ZTrayMacOSTrayAddSeparator()) return error.MenuInstallFailed;
                },
                .action => |action| {
                    const item_title = try allocator.dupeSentinel(u8, action.title, 0);
                    defer allocator.free(item_title);
                    var key_buf: [2]u8 = undefined;
                    const key_empty = [_:0]u8{0};
                    const key_z: [*:0]const u8 = if (action.shortcut) |sc| blk: {
                        key_buf[0] = sc.key.keyEquivalentByte();
                        key_buf[1] = 0;
                        break :blk key_buf[0..1 :0];
                    } else key_empty[0..0 :0];
                    const modifiers = if (action.shortcut) |sc| zmenu.modifierMask(sc) else 0;
                    if (!ZTrayMacOSTrayAddItem(item_title.ptr, action.action_id, key_z, modifiers, action.enabled))
                        return error.MenuInstallFailed;
                },
            }
        }
        if (!ZTrayMacOSTrayCommitMenuUpdate()) return error.MenuInstallFailed;
    }

    pub fn shutdown() void {
        if (!@This().active.swap(false, .acq_rel)) return;
        ZTrayMacOSTrayShutdown();
    }

    pub fn pollTrayActionId() c_int {
        return ZTrayMacOSTrayPollAction();
    }
    pub fn pump() void {
        ZTrayMacOSPumpEventsTimeoutMs(50);
    }
};

// ── Windows tray ──────────────────────────────────────────────────────────────

const HWND = ?*anyopaque;
const HMENU = ?*anyopaque;
const HICON = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const UINT = u32;
const UINT_PTR = usize;
const DWORD = u32;
const DWORD_PTR = usize;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const BOOL = c_int;
const WCHAR = u16;

const MF_STRING: UINT = 0x0000;
const MF_SEPARATOR: UINT = 0x0800;
const MF_GRAYED: UINT = 0x0001;
const WM_COMMAND: UINT = 0x0111;
const WM_USER: UINT = 0x0400;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_CONTEXTMENU: UINT = 0x007B;
const WM_APP: UINT = 0x8000;
const WS_POPUP: DWORD = 0x80000000;
const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

const NIF_MESSAGE: UINT = 0x00000001;
const NIF_ICON: UINT = 0x00000002;
const NIF_TIP: UINT = 0x00000004;
const NIM_ADD: DWORD = 0x00000000;
const NIM_DELETE: DWORD = 0x00000002;
const NIM_SETVERSION: DWORD = 0x00000004;
const NOTIFYICON_VERSION_4: UINT = 4;

const tray_command_base: u16 = 0x7580;
const tray_subclass_id: UINT_PTR = 0x5A545254;

var win_tray_pending_action_id: std.atomic.Value(c_int) = .init(-1);
var win_tray_icon_installed: std.atomic.Value(bool) = .init(false);
var win_tray_hwnd: HWND = null;
var win_tray_hwnd_owned: bool = false;
var win_tray_popup_menu: HMENU = null;
var win_tray_callback_msg: UINT = WM_APP + 80;
var win_tray_nid: UINT = 1;
var win_tray_icon_handle: HICON = null;
var win_tray_icon_destroy: bool = false;

const IMAGE_ICON: UINT = 1;
const LR_DEFAULTSIZE: UINT = 0x0040;
const LR_LOADFROMFILE: UINT = 0x0010;
const IDI_APPLICATION: UINT_PTR = 32512;
const ERROR_CLASS_ALREADY_EXISTS: DWORD = 1410;

extern fn ztray_win32_icon_from_png(data: [*]const u8, len: c_int) callconv(.c) HICON;

extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: UINT_PTR, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, i32, i32, i32, i32, HWND, HMENU, HINSTANCE, ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn GetModuleHandleW(?[*:0]const WCHAR) callconv(.winapi) HINSTANCE;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const anyopaque) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn LoadIconW(hInstance: HINSTANCE, lpIconName: UINT_PTR) callconv(.winapi) HICON;
extern "user32" fn LoadImageW(hInstance: HINSTANCE, name: UINT_PTR, t: UINT, cx: i32, cy: i32, fu: UINT) callconv(.winapi) HICON;
extern "user32" fn DestroyIcon(hIcon: HICON) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(lpMsg: *WinMSG, hWnd: HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const WinMSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const WinMSG) callconv(.winapi) LRESULT;
extern "user32" fn GetCursorPos(lpPoint: *WinPOINT) callconv(.winapi) BOOL;

extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

extern "comctl32" fn SetWindowSubclass(hWnd: HWND, pfnSubclass: *const fn (HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) callconv(.winapi) LRESULT, uIdSubclass: UINT_PTR, dwRefData: DWORD_PTR) callconv(.winapi) BOOL;
extern "comctl32" fn RemoveWindowSubclass(hWnd: HWND, pfnSubclass: *const fn (HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) callconv(.winapi) LRESULT, uIdSubclass: UINT_PTR) callconv(.winapi) BOOL;
extern "comctl32" fn DefSubclassProc(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: HICON = null,
    hCursor: HICON = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: ?[*:0]const WCHAR = null,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: HICON = null,
};

const HBRUSH = ?*anyopaque;

const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: HICON,
    szTip: [128]WCHAR,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]WCHAR = @splat(0),
    uVersion: UINT = 0,
    szInfoTitle: [64]WCHAR = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: [16]u8 = @splat(0),
    hBalloonIcon: HICON = null,
};

const WinPOINT = extern struct { x: i32, y: i32 };
const WinMSG = extern struct { hwnd: HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: DWORD, pt: WinPOINT };

const TPM_RIGHTBUTTON: UINT = 0x0002;
const TPM_BOTTOMALIGN: UINT = 0x0020;
const TPM_NONOTIFY: UINT = 0x0080;
const PM_REMOVE: UINT = 0x0001;

const tray_window_class = std.unicode.utf8ToUtf16LeStringLiteral("ZTrayMsgOnlyTray");

fn winRegisterTrayClass(hinst: HINSTANCE) !void {
    const wc = WNDCLASSEXW{
        .lpfnWndProc = DefWindowProcW,
        .hInstance = hinst,
        .lpszClassName = tray_window_class[0.. :0].ptr,
    };
    if (RegisterClassExW(&wc) == 0 and GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return error.TrayInstallFailed;
}

fn winCreateMessageWindow() !HWND {
    const hinst = GetModuleHandleW(null) orelse return error.TrayInstallFailed;
    try winRegisterTrayClass(hinst);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("");
    return CreateWindowExW(0, tray_window_class[0.. :0].ptr, title[0.. :0].ptr, WS_POPUP, 0, 0, 0, 0, HWND_MESSAGE, null, hinst, null) orelse return error.TrayInstallFailed;
}

fn winFillTip(out: *[128]WCHAR, tooltip: []const u8) void {
    @memset(std.mem.sliceAsBytes(out)[0..], 0);
    const n = std.unicode.wtf8ToWtf16Le(out[0..127], tooltip) catch {
        out[0] = 0;
        return;
    };
    out[n] = 0;
}

fn winLoadTrayIcon(allocator: std.mem.Allocator, icon_png: ?[]const u8, icon_file: ?[]const u8) !struct { icon: HICON, destroy: bool } {
    if (icon_png) |png| if (png.len > 0) {
        if (png.len > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.TrayInstallFailed;
        const h = ztray_win32_icon_from_png(@ptrCast(png.ptr), @intCast(png.len));
        if (h == null) return error.TrayInstallFailed;
        return .{ .icon = h, .destroy = true };
    };
    if (icon_file) |path| if (path.len > 0) {
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);
        const h = LoadImageW(null, @intFromPtr(wide.ptr), IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE) orelse return error.TrayInstallFailed;
        return .{ .icon = h, .destroy = true };
    };
    const h = LoadIconW(null, IDI_APPLICATION) orelse return error.TrayInstallFailed;
    return .{ .icon = h, .destroy = false };
}

fn winInstallTrayIcon(allocator: std.mem.Allocator, host_hwnd: HWND, tooltip: []const u8, icon_file: ?[]const u8, icon_png: ?[]const u8) InstallTrayIconError!void {
    if (win_tray_icon_installed.swap(true, .acq_rel)) return error.TrayAlreadyInstalled;

    win_tray_hwnd = host_hwnd orelse winCreateMessageWindow() catch |err| {
        _ = win_tray_icon_installed.store(false, .release);
        return err;
    };
    win_tray_hwnd_owned = (host_hwnd == null);

    if (SetWindowSubclass(win_tray_hwnd, winTraySubclassProc, tray_subclass_id, 0) == 0) {
        if (win_tray_hwnd_owned) _ = DestroyWindow(win_tray_hwnd);
        win_tray_hwnd = null;
        _ = win_tray_icon_installed.store(false, .release);
        return error.TrayInstallFailed;
    }

    const loaded = winLoadTrayIcon(allocator, icon_png, icon_file) catch |err| {
        _ = RemoveWindowSubclass(win_tray_hwnd, winTraySubclassProc, tray_subclass_id);
        if (win_tray_hwnd_owned) _ = DestroyWindow(win_tray_hwnd);
        win_tray_hwnd = null;
        _ = win_tray_icon_installed.store(false, .release);
        return err;
    };

    var nid: NOTIFYICONDATAW = .{ .cbSize = @sizeOf(NOTIFYICONDATAW), .hWnd = win_tray_hwnd, .uID = win_tray_nid, .uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP, .uCallbackMessage = win_tray_callback_msg, .hIcon = loaded.icon, .szTip = undefined };
    winFillTip(&nid.szTip, tooltip);

    if (Shell_NotifyIconW(NIM_ADD, &nid) == 0) {
        if (loaded.destroy) _ = DestroyIcon(loaded.icon);
        _ = RemoveWindowSubclass(win_tray_hwnd, winTraySubclassProc, tray_subclass_id);
        if (win_tray_hwnd_owned) _ = DestroyWindow(win_tray_hwnd);
        win_tray_hwnd = null;
        _ = win_tray_icon_installed.store(false, .release);
        return error.TrayInstallFailed;
    }

    win_tray_icon_handle = loaded.icon;
    win_tray_icon_destroy = loaded.destroy;
    nid.uVersion = NOTIFYICON_VERSION_4;
    _ = Shell_NotifyIconW(NIM_SETVERSION, &nid);
}

fn winSetTrayMenu(allocator: std.mem.Allocator, menu: TrayMenu) SetTrayMenuError!void {
    if (win_tray_hwnd == null) return error.MenuInstallFailed;
    const popup = CreatePopupMenu() orelse return error.MenuInstallFailed;
    errdefer _ = DestroyMenu(popup);
    for (menu.items) |item| {
        switch (item) {
            .separator => {
                if (AppendMenuW(popup, MF_SEPARATOR, 0, null) == 0) return error.MenuInstallFailed;
            },
            .action => |action| {
                if (action.action_id < 0) return error.ActionIdOutOfRange;
                if (@as(u32, @intCast(action.action_id)) > 0xFFFF - tray_command_base) return error.ActionIdOutOfRange;
                const label = try winItemLabel(allocator, action);
                defer allocator.free(label);
                const flags: UINT = if (action.enabled) MF_STRING else MF_STRING | MF_GRAYED;
                const cmd: UINT_PTR = @as(UINT_PTR, tray_command_base) + @as(u16, @intCast(action.action_id));
                if (AppendMenuW(popup, flags, cmd, label.ptr) == 0) return error.MenuInstallFailed;
            },
        }
    }
    const old = win_tray_popup_menu;
    win_tray_popup_menu = popup;
    if (old) |old_popup| _ = DestroyMenu(old_popup);
}

fn winItemLabel(allocator: std.mem.Allocator, action: Item.ActionItem) ![:0]u16 {
    const label: []const u8 = blk: {
        if (action.shortcut) |sc| {
            if (action.shortcut_display) |d| break :blk try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ action.title, d });
            const fmt = try zmenu.formatWindowsShortcut(allocator, sc);
            defer allocator.free(fmt);
            break :blk try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ action.title, fmt });
        } else break :blk try allocator.dupe(u8, action.title);
    };
    defer allocator.free(label);
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, label);
}

fn winShutdownTray() void {
    if (!win_tray_icon_installed.swap(false, .acq_rel)) return;
    if (win_tray_hwnd) |hwnd| {
        var nid: NOTIFYICONDATAW = .{ .cbSize = @sizeOf(NOTIFYICONDATAW), .hWnd = hwnd, .uID = win_tray_nid, .uFlags = 0, .uCallbackMessage = 0, .hIcon = null, .szTip = @splat(0) };
        _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        if (win_tray_icon_destroy) {
            if (win_tray_icon_handle) |hi| _ = DestroyIcon(hi);
            win_tray_icon_handle = null;
            win_tray_icon_destroy = false;
        }
        _ = RemoveWindowSubclass(hwnd, winTraySubclassProc, tray_subclass_id);
        if (win_tray_popup_menu) |m| {
            _ = DestroyMenu(m);
            win_tray_popup_menu = null;
        }
        if (win_tray_hwnd_owned) _ = DestroyWindow(hwnd);
        win_tray_hwnd = null;
        win_tray_hwnd_owned = false;
    }
    _ = win_tray_pending_action_id.store(-1, .release);
}

fn winPollTrayActionId() c_int {
    return win_tray_pending_action_id.swap(-1, .acq_rel);
}

fn winPumpTray() void {
    if (!win_tray_icon_installed.load(.acquire)) return;
    var msg: WinMSG = undefined;
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn winTraySubclassProc(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM, uIdSubclass: UINT_PTR, dwRefData: DWORD_PTR) callconv(.winapi) LRESULT {
    _ = uIdSubclass;
    _ = dwRefData;
    if (uMsg == win_tray_callback_msg) {
        const mouse_msg: UINT = @truncate(@as(usize, @bitCast(lParam)));
        if (mouse_msg == WM_RBUTTONUP or mouse_msg == WM_CONTEXTMENU) {
            if (win_tray_popup_menu) |popup| {
                var pt: WinPOINT = undefined;
                if (GetCursorPos(&pt) != 0) {
                    _ = SetForegroundWindow(hWnd);
                    _ = TrackPopupMenu(popup, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_NONOTIFY, pt.x, pt.y, 0, hWnd, null);
                    _ = PostMessageW(hWnd, WM_USER + 99, 0, 0);
                }
            }
            return 0;
        }
    }
    if (uMsg == WM_COMMAND) {
        const command: u16 = @truncate(wParam);
        if (command >= tray_command_base) {
            win_tray_pending_action_id.store(@intCast(command - tray_command_base), .release);
            return 0;
        }
    }
    return DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

// ── Linux tray ────────────────────────────────────────────────────────────────

const LinuxItemC = extern struct {
    id: i32,
    parent_id: i32,
    action_id: i32,
    flags: u32,
    shortcut_modifiers: u8,
    shortcut_key: u8,
    label: [*:0]const u8,
};

extern fn ztray_linux_tray_install(tooltip: [*:0]const u8, icon_name_or_null: ?[*:0]const u8, icon_png: ?[*]const u8, icon_png_len: c_int) c_int;
extern fn ztray_linux_tray_shutdown() void;
extern fn ztray_linux_tray_set_items(items: [*]const LinuxItemC, n: c_int) c_int;
extern fn ztray_linux_tray_take_pending() c_int;
extern fn ztray_linux_dbus_dispatch() void;

const FLAG_SEPARATOR: u32 = 1;
const FLAG_SUBMENU: u32 = 2;
const FLAG_DISABLED: u32 = 4;
const linux_max_menu_items = 512;

fn linuxShortcutModifiers(shortcut: Shortcut) u8 {
    return @intCast(zmenu.modifierMask(shortcut));
}

var linux_tray_active: std.atomic.Value(bool) = .init(false);

fn linuxInstallTrayIcon(allocator: std.mem.Allocator, tooltip: []const u8, icon_name: ?[]const u8, icon_png: ?[]const u8) InstallTrayIconError!void {
    if (icon_png) |png| if (png.len > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.TrayInstallFailed;
    if (linux_tray_active.swap(true, .acq_rel)) return error.TrayAlreadyInstalled;
    errdefer _ = linux_tray_active.store(false, .release);
    const tip_z = try allocator.dupeSentinel(u8, tooltip, 0);
    defer allocator.free(tip_z);
    const icon_z: ?[:0]u8 = if (icon_name) |n| try allocator.dupeSentinel(u8, n, 0) else null;
    defer if (icon_z) |z| allocator.free(z);
    const png = icon_png orelse "";
    if (ztray_linux_tray_install(
        tip_z.ptr,
        if (icon_z) |z| z.ptr else null,
        if (png.len > 0) png.ptr else null,
        @intCast(png.len),
    ) == 0) {
        _ = linux_tray_active.store(false, .release);
        return error.TrayInstallFailed;
    }
}

fn linuxSetTrayMenu(allocator: std.mem.Allocator, menu: TrayMenu) SetTrayMenuError!void {
    if (!linux_tray_active.load(.acquire)) return error.MenuInstallFailed;
    var flat: std.ArrayList(LinuxItemC) = .empty;
    defer {
        for (flat.items) |it| allocator.free(std.mem.span(it.label));
        flat.deinit(allocator);
    }

    var next_id: i32 = 1;
    if (flat.items.len >= linux_max_menu_items) return error.MenuTooLarge;
    try flat.append(allocator, .{ .id = 0, .parent_id = -1, .action_id = -1, .flags = FLAG_SUBMENU, .shortcut_modifiers = 0, .shortcut_key = 0, .label = (try allocator.dupeSentinel(u8, "", 0)).ptr });

    const menu_id = next_id;
    next_id += 1;
    if (flat.items.len >= linux_max_menu_items) return error.MenuTooLarge;
    try flat.append(allocator, .{ .id = menu_id, .parent_id = 0, .action_id = -1, .flags = FLAG_SUBMENU, .shortcut_modifiers = 0, .shortcut_key = 0, .label = (try allocator.dupeSentinel(u8, menu.title, 0)).ptr });
    for (menu.items) |item| {
        switch (item) {
            .separator => {
                if (flat.items.len >= linux_max_menu_items) return error.MenuTooLarge;
                const sid = next_id;
                next_id += 1;
                try flat.append(allocator, .{ .id = sid, .parent_id = menu_id, .action_id = -1, .flags = FLAG_SEPARATOR, .shortcut_modifiers = 0, .shortcut_key = 0, .label = (try allocator.dupeSentinel(u8, "", 0)).ptr });
            },
            .action => |a| {
                if (a.action_id < 0) return error.ActionIdOutOfRange;
                if (flat.items.len >= linux_max_menu_items) return error.MenuTooLarge;
                const aid = next_id;
                next_id += 1;
                var fl: u32 = 0;
                if (!a.enabled) fl |= FLAG_DISABLED;
                try flat.append(allocator, .{ .id = aid, .parent_id = menu_id, .action_id = a.action_id, .flags = fl, .shortcut_modifiers = if (a.shortcut) |shortcut| linuxShortcutModifiers(shortcut) else 0, .shortcut_key = if (a.shortcut) |shortcut| shortcut.key.keyEquivalentByte() else 0, .label = (try allocator.dupeSentinel(u8, a.title, 0)).ptr });
            },
        }
    }
    if (ztray_linux_tray_set_items(flat.items.ptr, @intCast(flat.items.len)) == 0) return error.DBusUnavailable;
}

fn linuxShutdownTray() void {
    if (!linux_tray_active.swap(false, .acq_rel)) return;
    ztray_linux_tray_shutdown();
}

fn linuxPollTrayActionId() c_int {
    ztray_linux_dbus_dispatch();
    return ztray_linux_tray_take_pending();
}

fn linuxPumpDBus() void {
    ztray_linux_dbus_dispatch();
}
