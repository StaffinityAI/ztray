const std = @import("std");

const types = @import("types.zig");

pub const LinuxItemC = extern struct {
    id: i32,
    parent_id: i32,
    action_id: i32,
    flags: u32,
    shortcut_modifiers: u8,
    shortcut_key: u8,
    label: [*:0]const u8,
};

extern fn ztray_linux_appmenu_registrar_has_owner() c_int;

extern fn ztray_linux_dbus_init() c_int;
extern fn ztray_linux_dbus_shutdown() void;
extern fn ztray_linux_dbus_set_items(items: [*]const LinuxItemC, n: c_int) c_int;
extern fn ztray_linux_dbus_dispatch() void;
extern fn ztray_linux_dbus_take_pending() c_int;

extern fn ztray_linux_tray_install(tooltip: [*:0]const u8, icon_name_or_null: ?[*:0]const u8, icon_png: ?[*]const u8, icon_png_len: c_int) c_int;
extern fn ztray_linux_tray_shutdown() void;
extern fn ztray_linux_tray_set_items(items: [*]const LinuxItemC, n: c_int) c_int;
extern fn ztray_linux_tray_take_pending() c_int;

const FLAG_SEPARATOR: u32 = 1;
const FLAG_SUBMENU: u32 = 2;
const FLAG_DISABLED: u32 = 4;
const max_menu_items = 512;

var menu_installed: std.atomic.Value(bool) = .init(false);
var tray_session_active: std.atomic.Value(bool) = .init(false);

/// Session D-Bus `NameHasOwner` for `com.canonical.AppMenu.Registrar`. `false` means no global AppMenu host (typical DVUI in-app menubar fallback). `null` while the asynchronous query is pending, unavailable, or stubbed.
pub fn appMenuRegistrarHasOwner() ?bool {
    return switch (ztray_linux_appmenu_registrar_has_owner()) {
        0 => false,
        1 => true,
        else => null,
    };
}

fn shortcutModifiers(shortcut: types.Shortcut) u8 {
    return @intCast(types.modifierMask(shortcut));
}

fn freeFlatLabels(allocator: std.mem.Allocator, flat: *std.ArrayList(LinuxItemC)) void {
    for (flat.items) |it| allocator.free(std.mem.span(it.label));
}

/// Appends the synthetic DBusMenu root (id 0) and sets `next_id` to 1.
fn appendDbusMenuRoot(allocator: std.mem.Allocator, flat: *std.ArrayList(LinuxItemC), next_id: *i32) error{ OutOfMemory, MenuTooLarge }!void {
    if (flat.items.len >= max_menu_items) return error.MenuTooLarge;
    try flat.append(allocator, .{
        .id = 0,
        .parent_id = -1,
        .action_id = -1,
        .flags = FLAG_SUBMENU,
        .shortcut_modifiers = 0,
        .shortcut_key = 0,
        .label = (try allocator.dupeSentinel(u8, "", 0)).ptr,
    });
    next_id.* = 1;
}

/// Appends one submenu header (`menu.title`) under `parent_id`, then its items.
fn appendMenuAsChildOf(
    allocator: std.mem.Allocator,
    flat: *std.ArrayList(LinuxItemC),
    parent_id: i32,
    menu: types.Menu,
    next_id: *i32,
) error{ OutOfMemory, ActionIdOutOfRange, MenuTooLarge }!void {
    if (flat.items.len >= max_menu_items) return error.MenuTooLarge;
    const menu_id = next_id.*;
    next_id.* += 1;
    try flat.append(allocator, .{
        .id = menu_id,
        .parent_id = parent_id,
        .action_id = -1,
        .flags = FLAG_SUBMENU,
        .shortcut_modifiers = 0,
        .shortcut_key = 0,
        .label = (try allocator.dupeSentinel(u8, menu.title, 0)).ptr,
    });

    for (menu.items) |item| {
        switch (item) {
            .separator => {
                if (flat.items.len >= max_menu_items) return error.MenuTooLarge;
                const sid = next_id.*;
                next_id.* += 1;
                try flat.append(allocator, .{
                    .id = sid,
                    .parent_id = menu_id,
                    .action_id = -1,
                    .flags = FLAG_SEPARATOR,
                    .shortcut_modifiers = 0,
                    .shortcut_key = 0,
                    .label = (try allocator.dupeSentinel(u8, "", 0)).ptr,
                });
            },
            .action => |a| {
                if (a.action_id < 0) return error.ActionIdOutOfRange;
                if (flat.items.len >= max_menu_items) return error.MenuTooLarge;
                const aid = next_id.*;
                next_id.* += 1;
                var fl: u32 = 0;
                if (!a.enabled) fl |= FLAG_DISABLED;
                try flat.append(allocator, .{
                    .id = aid,
                    .parent_id = menu_id,
                    .action_id = a.action_id,
                    .flags = fl,
                    .shortcut_modifiers = if (a.shortcut) |shortcut| shortcutModifiers(shortcut) else 0,
                    .shortcut_key = if (a.shortcut) |shortcut| shortcut.key.keyEquivalentByte() else 0,
                    .label = (try allocator.dupeSentinel(u8, a.title, 0)).ptr,
                });
            },
        }
    }
}

pub fn installMainMenu(allocator: std.mem.Allocator, menu_bar: types.MenuBar) error{ DBusUnavailable, OutOfMemory, ActionIdOutOfRange, MenuAlreadyInstalled, MenuTooLarge }!void {
    if (menu_installed.load(.acquire)) return error.MenuAlreadyInstalled;

    var flat: std.ArrayList(LinuxItemC) = .empty;
    defer {
        freeFlatLabels(allocator, &flat);
        flat.deinit(allocator);
    }

    var next_id: i32 = undefined;
    try appendDbusMenuRoot(allocator, &flat, &next_id);
    for (menu_bar.menus) |menu| {
        try appendMenuAsChildOf(allocator, &flat, 0, menu, &next_id);
    }

    if (ztray_linux_dbus_init() == 0) return error.DBusUnavailable;
    errdefer ztray_linux_dbus_shutdown();

    if (ztray_linux_dbus_set_items(flat.items.ptr, @intCast(flat.items.len)) == 0) return error.DBusUnavailable;

    menu_installed.store(true, .release);
}

pub fn pollActionId() c_int {
    ztray_linux_dbus_dispatch();
    return ztray_linux_dbus_take_pending();
}

pub fn installTrayIcon(allocator: std.mem.Allocator, tooltip: []const u8, icon_name: ?[]const u8, icon_png: ?[]const u8) error{ TrayInstallFailed, TrayAlreadyInstalled, OutOfMemory }!void {
    if (icon_png) |png| if (png.len > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.TrayInstallFailed;
    if (tray_session_active.swap(true, .acq_rel)) return error.TrayAlreadyInstalled;
    errdefer _ = tray_session_active.store(false, .release);

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
        _ = tray_session_active.store(false, .release);
        return error.TrayInstallFailed;
    }
}

/// Same error cases as the public `setTrayMenu` on Linux (`InvalidWtf8` does not occur here).
pub fn setTrayMenu(allocator: std.mem.Allocator, menu: types.Menu) error{ OutOfMemory, MenuInstallFailed, ActionIdOutOfRange, DBusUnavailable, MenuTooLarge }!void {
    if (!tray_session_active.load(.acquire)) return error.MenuInstallFailed;

    var flat: std.ArrayList(LinuxItemC) = .empty;
    defer {
        freeFlatLabels(allocator, &flat);
        flat.deinit(allocator);
    }

    var next_id: i32 = undefined;
    try appendDbusMenuRoot(allocator, &flat, &next_id);
    try appendMenuAsChildOf(allocator, &flat, 0, menu, &next_id);

    if (ztray_linux_tray_set_items(flat.items.ptr, @intCast(flat.items.len)) == 0)
        return error.DBusUnavailable;
}

pub fn shutdownTray() void {
    if (!tray_session_active.swap(false, .acq_rel)) return;
    ztray_linux_tray_shutdown();
}

pub fn pollTrayActionId() c_int {
    ztray_linux_dbus_dispatch();
    return ztray_linux_tray_take_pending();
}

pub fn pumpLinuxDBus() void {
    ztray_linux_dbus_dispatch();
}

test "flattened menu preserves shortcut metadata" {
    const allocator = std.testing.allocator;
    var flat: std.ArrayList(LinuxItemC) = .empty;
    defer {
        freeFlatLabels(allocator, &flat);
        flat.deinit(allocator);
    }

    const menu: types.Menu = .{
        .title = "File",
        .items = &.{.{ .action = .{
            .title = "Open",
            .action_id = 7,
            .shortcut = .{ .key = .o, .primary = true, .shift = true },
        } }},
    };
    var next_id: i32 = undefined;
    try appendDbusMenuRoot(allocator, &flat, &next_id);
    try appendMenuAsChildOf(allocator, &flat, 0, menu, &next_id);

    try std.testing.expectEqual(@as(usize, 3), flat.items.len);
    try std.testing.expectEqual(@as(u8, 'o'), flat.items[2].shortcut_key);
    try std.testing.expectEqual(@as(u8, @intCast(types.modifierMask(.{ .key = .o, .primary = true, .shift = true }))), flat.items[2].shortcut_modifiers);
}

test "flattened menu returns MenuTooLarge at capacity" {
    const allocator = std.testing.allocator;
    var flat: std.ArrayList(LinuxItemC) = .empty;
    defer {
        freeFlatLabels(allocator, &flat);
        flat.deinit(allocator);
    }

    var next_id: i32 = undefined;
    try appendDbusMenuRoot(allocator, &flat, &next_id);
    while (flat.items.len < max_menu_items) {
        try flat.append(allocator, .{
            .id = next_id,
            .parent_id = 0,
            .action_id = -1,
            .flags = FLAG_SEPARATOR,
            .shortcut_modifiers = 0,
            .shortcut_key = 0,
            .label = (try allocator.dupeSentinel(u8, "", 0)).ptr,
        });
        next_id += 1;
    }

    try std.testing.expectError(error.MenuTooLarge, appendDbusMenuRoot(allocator, &flat, &next_id));
}
