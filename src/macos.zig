const std = @import("std");

const types = @import("types.zig");

extern fn ZTrayMacOSBeginMainMenu() bool;
extern fn ZTrayMacOSBeginMenu(title: [*:0]const u8) bool;
extern fn ZTrayMacOSAddItem(
    title: [*:0]const u8,
    action_id: c_int,
    key: [*:0]const u8,
    modifiers: u32,
    enabled: bool,
) bool;
extern fn ZTrayMacOSAddSeparator() bool;
extern fn ZTrayMacOSEndMenu() bool;
extern fn ZTrayMacOSEndMainMenu() bool;
extern fn ZTrayMacOSPollAction() c_int;

extern fn ZTrayMacOSTrayInstall(tooltip: [*:0]const u8, icon_path_utf8_or_null: ?[*:0]const u8, png_bytes: ?[*]const u8, png_len: usize) bool;
extern fn ZTrayMacOSTrayClearMenu() bool;
extern fn ZTrayMacOSTrayAddItem(
    title: [*:0]const u8,
    action_id: c_int,
    key: [*:0]const u8,
    modifiers: u32,
    enabled: bool,
) bool;
extern fn ZTrayMacOSTrayAddSeparator() bool;
extern fn ZTrayMacOSTrayPollAction() c_int;
extern fn ZTrayMacOSTrayShutdown() void;
extern fn ZTrayMacOSPumpEventsTimeoutMs(ms: c_uint) void;

var macos_menu_installed: std.atomic.Value(bool) = .init(false);
var macos_tray_active: std.atomic.Value(bool) = .init(false);

const AddItemFn = *const fn ([*:0]const u8, c_int, [*:0]const u8, u32, bool) callconv(.c) bool;
const AddSepFn = *const fn () callconv(.c) bool;

fn addItemsToTarget(
    allocator: std.mem.Allocator,
    items: []const types.Item,
    addItem: AddItemFn,
    addSep: AddSepFn,
) error{ MenuInstallFailed, OutOfMemory }!void {
    for (items) |item| {
        switch (item) {
            .separator => {
                if (!addSep()) return error.MenuInstallFailed;
            },
            .action => |action| {
                const item_title = try allocator.dupeSentinel(u8, action.title, 0);
                defer allocator.free(item_title);

                var key_buf: [2]u8 = undefined;
                const key_empty = [_:0]u8{0};
                const key_z: [*:0]const u8 = if (action.shortcut) |shortcut| blk: {
                    key_buf[0] = shortcut.key.keyEquivalentByte();
                    key_buf[1] = 0;
                    break :blk key_buf[0..1 :0];
                } else key_empty[0..0 :0];

                const modifiers = if (action.shortcut) |shortcut| types.modifierMask(shortcut) else 0;
                if (!addItem(item_title.ptr, action.action_id, key_z, modifiers, action.enabled))
                    return error.MenuInstallFailed;
            },
        }
    }
}

pub fn installMainMenu(allocator: std.mem.Allocator, menu_bar: types.MenuBar) error{ MenuAlreadyInstalled, MenuInstallFailed, OutOfMemory }!void {
    if (macos_menu_installed.swap(true, .acq_rel)) return error.MenuAlreadyInstalled;
    errdefer _ = macos_menu_installed.store(false, .release);
    if (!ZTrayMacOSBeginMainMenu()) return error.MenuInstallFailed;

    for (menu_bar.menus) |menu| {
        const title = try allocator.dupeSentinel(u8, menu.title, 0);
        defer allocator.free(title);
        if (!ZTrayMacOSBeginMenu(title.ptr)) return error.MenuInstallFailed;
        try addItemsToTarget(allocator, menu.items, ZTrayMacOSAddItem, ZTrayMacOSAddSeparator);
        if (!ZTrayMacOSEndMenu()) return error.MenuInstallFailed;
    }

    if (!ZTrayMacOSEndMainMenu()) return error.MenuInstallFailed;
}

pub fn pollActionId() c_int {
    return ZTrayMacOSPollAction();
}

pub fn installTrayIcon(allocator: std.mem.Allocator, tooltip: []const u8, icon_file_utf8: ?[]const u8, icon_png: ?[]const u8) error{ TrayInstallFailed, TrayAlreadyInstalled, OutOfMemory }!void {
    if (macos_tray_active.swap(true, .acq_rel)) return error.TrayAlreadyInstalled;
    errdefer _ = macos_tray_active.store(false, .release);

    const tip_z = try allocator.dupeSentinel(u8, tooltip, 0);
    defer allocator.free(tip_z);

    const icon_z: ?[:0]u8 = if (icon_file_utf8) |p| try allocator.dupeSentinel(u8, p, 0) else null;
    defer if (icon_z) |z| allocator.free(z);

    const png = icon_png orelse "";
    const png_ptr: ?[*]const u8 = if (png.len > 0) png.ptr else null;

    if (!ZTrayMacOSTrayInstall(
        tip_z.ptr,
        if (icon_z) |z| z.ptr else null,
        png_ptr,
        png.len,
    )) {
        _ = macos_tray_active.store(false, .release);
        return error.TrayInstallFailed;
    }
}

pub fn setTrayMenu(allocator: std.mem.Allocator, menu: types.Menu) error{ OutOfMemory, MenuInstallFailed }!void {
    if (!macos_tray_active.load(.acquire)) return error.MenuInstallFailed;
    if (!ZTrayMacOSTrayClearMenu()) return error.MenuInstallFailed;
    try addItemsToTarget(allocator, menu.items, ZTrayMacOSTrayAddItem, ZTrayMacOSTrayAddSeparator);
}

pub fn shutdownTray() void {
    if (!macos_tray_active.swap(false, .acq_rel)) return;
    ZTrayMacOSTrayShutdown();
}

pub fn pollTrayActionId() c_int {
    return ZTrayMacOSTrayPollAction();
}

pub fn pumpTrayEventsDarwin() void {
    ZTrayMacOSPumpEventsTimeoutMs(50);
}
