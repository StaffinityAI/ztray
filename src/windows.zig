const std = @import("std");

const types = @import("types.zig");

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
const ATOM = u16;
const WCHAR = u16;

const MF_STRING: UINT = 0x0000;
const MF_POPUP: UINT = 0x0010;
const MF_SEPARATOR: UINT = 0x0800;
const MF_GRAYED: UINT = 0x0001;
const WM_COMMAND: UINT = 0x0111;
const WM_DESTROY: UINT = 0x0002;
const WM_NCDESTROY: UINT = 0x0082;
const WM_USER: UINT = 0x0400;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_CONTEXTMENU: UINT = 0x007B;
const WM_LBUTTONDBLCLK: UINT = 0x0203;
const WM_APP: UINT = 0x8000;

const TPM_LEFTALIGN: UINT = 0x0000;
const TPM_BOTTOMALIGN: UINT = 0x0020;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const TPM_RETURNCMD: UINT = 0x0100;
const TPM_NONOTIFY: UINT = 0x0080;

const WS_POPUP: DWORD = 0x80000000;
const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

const NIF_MESSAGE: UINT = 0x00000001;
const NIF_ICON: UINT = 0x00000002;
const NIF_TIP: UINT = 0x00000004;
const NIM_ADD: DWORD = 0x00000000;
const NIM_DELETE: DWORD = 0x00000002;
const NIM_MODIFY: DWORD = 0x00000001;
const NIM_SETVERSION: DWORD = 0x00000004;
const NOTIFYICON_VERSION_4: UINT = 4;

const command_base: u16 = 0x7000;
/// Distinct from menubar command ids so both can coexist on one HWND.
const tray_command_base: u16 = 0x7580;

/// Largest `Item.ActionItem.action_id` allowed for the native menubar (`command_base` + id must fit in `u16`).
pub const menubar_action_id_max: u16 = 0xFFFF - command_base;
/// Largest `action_id` allowed for the tray popup menu on the same HWND.
pub const tray_action_id_max: u16 = 0xFFFF - tray_command_base;

comptime {
    std.debug.assert(@as(u32, command_base) + menubar_action_id_max == 0xFFFF);
    std.debug.assert(@as(u32, tray_command_base) + tray_action_id_max == 0xFFFF);
}
const subclass_id: UINT_PTR = 0x5A545241; // "ZTRA"
const tray_subclass_id: UINT_PTR = 0x5A545254; // "ZTRT"

var pending_action_id: std.atomic.Value(c_int) = .init(-1);
var menu_installed: std.atomic.Value(bool) = .init(false);
var menu_hwnd: HWND = null;
var menu_handle: HMENU = null;

var tray_pending_action_id: std.atomic.Value(c_int) = .init(-1);
var tray_icon_installed: std.atomic.Value(bool) = .init(false);
var tray_hwnd: HWND = null;
var tray_hwnd_owned: bool = false;
var tray_popup_menu: HMENU = null;
var tray_callback_msg: UINT = WM_APP + 80;
var tray_nid: UINT = 1;
var tray_icon_handle: HICON = null;
var tray_icon_destroy_on_shutdown: bool = false;

extern fn ztray_win32_icon_from_png(data: [*]const u8, len: c_int) callconv(.c) HICON;

extern "user32" fn CreateMenu() callconv(.winapi) HMENU;
extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: UINT_PTR, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn SetMenu(hWnd: HWND, hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn DrawMenuBar(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, i32, i32, i32, i32, HWND, HMENU, HINSTANCE, ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn GetModuleHandleW(?[*:0]const WCHAR) callconv(.winapi) HINSTANCE;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const anyopaque) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn LoadIconW(hInstance: HINSTANCE, lpIconName: UINT_PTR) callconv(.winapi) HICON;
extern "user32" fn LoadImageW(hInstance: HINSTANCE, name: UINT_PTR, type: UINT, cx: i32, cy: i32, fuLoad: UINT) callconv(.winapi) HICON;
extern "user32" fn DestroyIcon(hIcon: HICON) callconv(.winapi) BOOL;

extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

extern "comctl32" fn SetWindowSubclass(
    hWnd: HWND,
    pfnSubclass: *const fn (HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) callconv(.winapi) LRESULT,
    uIdSubclass: UINT_PTR,
    dwRefData: DWORD_PTR,
) callconv(.winapi) BOOL;
extern "comctl32" fn RemoveWindowSubclass(hWnd: HWND, pfnSubclass: *const fn (HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) callconv(.winapi) LRESULT, uIdSubclass: UINT_PTR) callconv(.winapi) BOOL;
extern "comctl32" fn DefSubclassProc(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

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

const IMAGE_ICON: UINT = 1;
const LR_DEFAULTSIZE: UINT = 0x0040;
const LR_LOADFROMFILE: UINT = 0x0010;
const IDI_APPLICATION: UINT_PTR = 32512;

fn trayActionFromCommand(command: u16) ?types.ActionId {
    if (command < tray_command_base) return null;
    return @intCast(command - tray_command_base);
}

fn appendItemsToPopupMenu(allocator: std.mem.Allocator, popup: HMENU, menu: types.Menu, cmd_base: u16) !void {
    for (menu.items) |item| {
        switch (item) {
            .separator => {
                if (AppendMenuW(popup, MF_SEPARATOR, 0, null) == 0) return error.MenuInstallFailed;
            },
            .action => |action| {
                if (action.action_id < 0) return error.ActionIdOutOfRange;
                const offset: u32 = @intCast(action.action_id);
                if (offset > 0xFFFF - cmd_base) return error.ActionIdOutOfRange;

                const title = try windowsItemTitle(allocator, action);
                defer allocator.free(title);

                const flags: UINT = if (action.enabled) MF_STRING else MF_STRING | MF_GRAYED;
                const cmd: UINT_PTR = @as(UINT_PTR, cmd_base) + @as(u16, @intCast(action.action_id));
                if (AppendMenuW(popup, flags, cmd, title.ptr) == 0) return error.MenuInstallFailed;
            },
        }
    }
}

fn appendMenuToMainMenu(allocator: std.mem.Allocator, main_menu: HMENU, menu: types.Menu) !void {
    const submenu = CreatePopupMenu() orelse return error.MenuInstallFailed;
    errdefer _ = DestroyMenu(submenu);
    try appendItemsToPopupMenu(allocator, submenu, menu, command_base);

    const title = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, menu.title);
    defer allocator.free(title);
    if (AppendMenuW(main_menu, MF_POPUP, @intFromPtr(submenu), title.ptr) == 0) return error.MenuInstallFailed;
}

pub fn installMainMenu(allocator: std.mem.Allocator, hwnd: HWND, menu_bar: types.MenuBar) error{ OutOfMemory, MenuAlreadyInstalled, MenuInstallFailed, ActionIdOutOfRange, InvalidWtf8 }!void {
    if (menu_installed.swap(true, .acq_rel)) return error.MenuAlreadyInstalled;
    errdefer _ = menu_installed.store(false, .release);
    if (hwnd == null) return error.MenuInstallFailed;

    const main_menu = CreateMenu() orelse return error.MenuInstallFailed;
    errdefer _ = DestroyMenu(main_menu);
    var attached = false;
    errdefer if (attached) {
        _ = SetMenu(hwnd, null);
        _ = DrawMenuBar(hwnd);
    };

    for (menu_bar.menus) |menu| try appendMenuToMainMenu(allocator, main_menu, menu);

    if (SetMenu(hwnd, main_menu) == 0) return error.MenuInstallFailed;
    attached = true;
    _ = DrawMenuBar(hwnd);
    if (SetWindowSubclass(hwnd, ztraySubclassProc, subclass_id, 0) == 0) return error.MenuInstallFailed;
    menu_hwnd = hwnd;
    menu_handle = main_menu;
}

pub fn pollActionId() c_int {
    return pending_action_id.swap(-1, .acq_rel);
}

pub fn pollTrayActionId() c_int {
    return tray_pending_action_id.swap(-1, .acq_rel);
}

const POINT = extern struct {
    x: i32,
    y: i32,
};

const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const PM_REMOVE_MSG: UINT = 0x0001;

extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;

/// Dispatch pending Win32 messages for the tray owner HWND (required for tray callbacks and menu commands).
pub fn pumpTrayMessages() void {
    if (!tray_icon_installed.load(.acquire)) return;
    var msg: MSG = undefined;
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE_MSG) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

const ERROR_CLASS_ALREADY_EXISTS: DWORD = 1410;

const tray_window_class = std.unicode.utf8ToUtf16LeStringLiteral("ZTrayMsgOnlyZtray");

fn registerTrayWindowClass(hinst: HINSTANCE) !void {
    const wc = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinst,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = tray_window_class[0.. :0].ptr,
        .hIconSm = null,
    };
    const atom = RegisterClassExW(&wc);
    if (atom == 0) {
        if (GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return error.TrayInstallFailed;
    }
}

fn createMessageOnlyTrayWindow() !HWND {
    const hinst = GetModuleHandleW(null) orelse return error.TrayInstallFailed;
    try registerTrayWindowClass(hinst);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("");
    const hwnd = CreateWindowExW(
        0,
        tray_window_class[0.. :0].ptr,
        title[0.. :0].ptr,
        WS_POPUP,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        null,
        hinst,
        null,
    ) orelse return error.TrayInstallFailed;
    return hwnd;
}

fn fillNotifyTip(out: *[128]WCHAR, tooltip: []const u8) void {
    @memset(std.mem.sliceAsBytes(out)[0..], 0);
    const max_utf16 = out.len - 1;
    const n = std.unicode.wtf8ToWtf16Le(out[0..max_utf16], tooltip) catch {
        out[0] = 0;
        return;
    };
    out[n] = 0;
}

const TrayLoadedIcon = struct {
    icon: HICON,
    destroy_on_done: bool,
};

fn loadTrayIcon(allocator: std.mem.Allocator, icon_png: ?[]const u8, icon_file_utf8: ?[]const u8) !TrayLoadedIcon {
    if (icon_png) |png| {
        if (png.len > 0) {
            if (png.len > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.TrayInstallFailed;
            const h = ztray_win32_icon_from_png(@ptrCast(png.ptr), @intCast(png.len));
            if (h == null) return error.TrayInstallFailed;
            return .{ .icon = h, .destroy_on_done = true };
        }
    }
    if (icon_file_utf8) |path| {
        if (path.len > 0) {
            const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
            defer allocator.free(wide);
            const h = LoadImageW(null, @intFromPtr(wide.ptr), IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE) orelse return error.TrayInstallFailed;
            return .{ .icon = h, .destroy_on_done = true };
        }
    }
    const h = LoadIconW(null, IDI_APPLICATION) orelse return error.TrayInstallFailed;
    return .{ .icon = h, .destroy_on_done = false };
}

/// `host_hwnd` null = internal message-only window (tray-only apps).
pub fn installTrayIcon(allocator: std.mem.Allocator, host_hwnd: HWND, tooltip_utf8: []const u8, icon_file_utf8: ?[]const u8, icon_png: ?[]const u8) error{ TrayInstallFailed, TrayAlreadyInstalled, OutOfMemory, InvalidWtf8 }!void {
    if (tray_icon_installed.swap(true, .acq_rel)) return error.TrayAlreadyInstalled;

    tray_hwnd = host_hwnd orelse createMessageOnlyTrayWindow() catch |err| {
        _ = tray_icon_installed.store(false, .release);
        return err;
    };
    tray_hwnd_owned = (host_hwnd == null);

    if (SetWindowSubclass(tray_hwnd, traySubclassProc, tray_subclass_id, 0) == 0) {
        if (tray_hwnd_owned) _ = DestroyWindow(tray_hwnd);
        tray_hwnd = null;
        tray_hwnd_owned = false;
        _ = tray_icon_installed.store(false, .release);
        return error.TrayInstallFailed;
    }

    const loaded = loadTrayIcon(allocator, icon_png, icon_file_utf8) catch |err| {
        _ = RemoveWindowSubclass(tray_hwnd, traySubclassProc, tray_subclass_id);
        if (tray_hwnd_owned) _ = DestroyWindow(tray_hwnd);
        tray_hwnd = null;
        tray_hwnd_owned = false;
        _ = tray_icon_installed.store(false, .release);
        return err;
    };

    var nid: NOTIFYICONDATAW = .{
        .cbSize = @sizeOf(NOTIFYICONDATAW),
        .hWnd = tray_hwnd,
        .uID = tray_nid,
        .uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
        .uCallbackMessage = tray_callback_msg,
        .hIcon = loaded.icon,
        .szTip = undefined,
    };
    fillNotifyTip(&nid.szTip, tooltip_utf8);

    if (Shell_NotifyIconW(NIM_ADD, &nid) == 0) {
        if (loaded.destroy_on_done) _ = DestroyIcon(loaded.icon);
        _ = RemoveWindowSubclass(tray_hwnd, traySubclassProc, tray_subclass_id);
        if (tray_hwnd_owned) _ = DestroyWindow(tray_hwnd);
        tray_hwnd = null;
        tray_hwnd_owned = false;
        _ = tray_icon_installed.store(false, .release);
        return error.TrayInstallFailed;
    }

    tray_icon_handle = loaded.icon;
    tray_icon_destroy_on_shutdown = loaded.destroy_on_done;

    nid.uVersion = NOTIFYICON_VERSION_4;
    _ = Shell_NotifyIconW(NIM_SETVERSION, &nid);
}

pub fn setTrayMenu(allocator: std.mem.Allocator, menu: types.Menu) error{ OutOfMemory, MenuInstallFailed, ActionIdOutOfRange, InvalidWtf8 }!void {
    if (tray_hwnd == null) return error.MenuInstallFailed;

    if (tray_popup_menu) |old| {
        _ = DestroyMenu(old);
        tray_popup_menu = null;
    }

    const popup = CreatePopupMenu() orelse return error.MenuInstallFailed;
    errdefer _ = DestroyMenu(popup);

    try appendItemsToPopupMenu(allocator, popup, menu, tray_command_base);
    tray_popup_menu = popup;
}

pub fn shutdownTray() void {
    if (!tray_icon_installed.swap(false, .acq_rel)) return;

    if (tray_hwnd) |hwnd| {
        var nid: NOTIFYICONDATAW = .{
            .cbSize = @sizeOf(NOTIFYICONDATAW),
            .hWnd = hwnd,
            .uID = tray_nid,
            .uFlags = 0,
            .uCallbackMessage = 0,
            .hIcon = null,
            .szTip = @splat(0),
        };
        _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        if (tray_icon_destroy_on_shutdown) {
            if (tray_icon_handle) |hi| _ = DestroyIcon(hi);
            tray_icon_handle = null;
            tray_icon_destroy_on_shutdown = false;
        }
        _ = RemoveWindowSubclass(hwnd, traySubclassProc, tray_subclass_id);
        if (tray_popup_menu) |m| {
            _ = DestroyMenu(m);
            tray_popup_menu = null;
        }
        if (tray_hwnd_owned) _ = DestroyWindow(hwnd);
        tray_hwnd = null;
        tray_hwnd_owned = false;
    }
    _ = tray_pending_action_id.store(-1, .release);
}

fn traySubclassProc(
    hWnd: HWND,
    uMsg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    uIdSubclass: UINT_PTR,
    dwRefData: DWORD_PTR,
) callconv(.winapi) LRESULT {
    _ = uIdSubclass;
    _ = dwRefData;

    if (uMsg == tray_callback_msg) {
        const mouse_msg: UINT = @truncate(@as(usize, @bitCast(lParam)));
        if (mouse_msg == WM_RBUTTONUP or mouse_msg == WM_CONTEXTMENU) {
            if (tray_popup_menu) |popup| {
                var pt: POINT = undefined;
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
        if (trayActionFromCommand(command)) |id| {
            tray_pending_action_id.store(id, .release);
            return 0;
        }
    }

    return DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

fn actionFromCommand(command: u16) ?types.ActionId {
    if (command < command_base) return null;
    return @intCast(command - command_base);
}

fn ztraySubclassProc(
    hWnd: HWND,
    uMsg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    uIdSubclass: UINT_PTR,
    dwRefData: DWORD_PTR,
) callconv(.winapi) LRESULT {
    _ = uIdSubclass;
    _ = dwRefData;

    if (uMsg == WM_COMMAND) {
        const command: u16 = @truncate(wParam);
        if (actionFromCommand(command)) |id| {
            pending_action_id.store(id, .release);
            return 0;
        }
    }

    if (uMsg == WM_NCDESTROY and menu_hwnd == hWnd) {
        menu_hwnd = null;
        if (menu_handle) |menu| _ = DestroyMenu(menu);
        menu_handle = null;
        pending_action_id.store(-1, .release);
        _ = menu_installed.store(false, .release);
    }

    return DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

fn windowsItemTitle(allocator: std.mem.Allocator, action: types.Item.ActionItem) ![:0]u16 {
    const label: []const u8 = blk: {
        if (action.shortcut) |shortcut| {
            if (action.shortcut_display) |d| {
                break :blk try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ action.title, d });
            }
            const fmt = try types.formatWindowsShortcut(allocator, shortcut);
            defer allocator.free(fmt);
            break :blk try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ action.title, fmt });
        } else {
            break :blk try allocator.dupe(u8, action.title);
        }
    };
    defer allocator.free(label);

    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, label);
}
