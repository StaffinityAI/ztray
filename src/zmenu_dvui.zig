//! In-app menu bar using DVUI. Included as [`zmenu.dvui_menu`] when using `createZmenuDvuiModule`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const zmenu = @import("zmenu_core");

var pending_action: std.atomic.Value(zmenu.ActionId) = .init(-1);

var menu_arena: std.heap.ArenaAllocator = undefined;
var menu_arena_init: bool = false;
var stored_bar: ?zmenu.MenuBar = null;

var menu_serial: u32 = 0;
var synced_serial: u32 = 0;

var shortcut_ids: []zmenu.ActionId = &.{};

var last_win: ?*dvui.Window = null;

fn dupMenuBar(a: std.mem.Allocator, menu_bar: zmenu.MenuBar) !zmenu.MenuBar {
    var menus = try a.alloc(zmenu.Menu, menu_bar.menus.len);
    for (menu_bar.menus, 0..) |src_menu, mi| {
        const title = try a.dupe(u8, src_menu.title);
        var items = try a.alloc(zmenu.Item, src_menu.items.len);
        for (src_menu.items, 0..) |src_item, ii| {
            items[ii] = switch (src_item) {
                .separator => .separator,
                .action => |act| .{ .action = .{
                    .title = try a.dupe(u8, act.title),
                    .action_id = act.action_id,
                    .shortcut = act.shortcut,
                    .shortcut_display = if (act.shortcut_display) |sd| try a.dupe(u8, sd) else null,
                    .enabled = act.enabled,
                } },
            };
        }
        menus[mi] = .{ .title = title, .items = items };
    }
    return .{ .menus = menus };
}

pub fn installMainMenu(parent_allocator: std.mem.Allocator, menu_bar: zmenu.MenuBar) error{OutOfMemory}!void {
    if (last_win) |win| {
        removeRegisteredKeybinds(win);
        last_win = null;
    }
    shortcut_ids = &.{};
    synced_serial = 0;

    if (menu_arena_init) {
        menu_arena.deinit();
        menu_arena_init = false;
        stored_bar = null;
    }
    menu_arena = std.heap.ArenaAllocator.init(parent_allocator);
    menu_arena_init = true;
    errdefer {
        menu_arena.deinit();
        menu_arena_init = false;
    }
    stored_bar = try dupMenuBar(menu_arena.allocator(), menu_bar);
    menu_serial +%= 1;
}

pub fn shutdownMenu() void {
    if (last_win) |win| {
        removeRegisteredKeybinds(win);
        last_win = null;
    }
    shortcut_ids = &.{};
    synced_serial = 0;
    if (menu_arena_init) {
        menu_arena.deinit();
        menu_arena_init = false;
        stored_bar = null;
    }
}

fn menuBindName(buf: *[64]u8, action_id: zmenu.ActionId) []const u8 {
    return std.fmt.bufPrint(buf[0..], "zmenu_action_{d}", .{action_id}) catch unreachable;
}

fn removeRegisteredKeybinds(win: *dvui.Window) void {
    var buf: [64]u8 = undefined;
    for (shortcut_ids) |action_id| {
        const name = menuBindName(&buf, action_id);
        _ = win.keybinds.remove(name);
    }
}

fn shortcutKeyToDvuiKey(key: zmenu.ShortcutKey) dvui.enums.Key {
    return switch (key) {
        inline else => |k| @field(dvui.enums.Key, @tagName(k)),
    };
}

fn shortcutToKeybind(sc: zmenu.Shortcut) dvui.enums.Keybind {
    var kb: dvui.enums.Keybind = .{ .key = shortcutKeyToDvuiKey(sc.key) };
    if (sc.shift) kb.shift = true;
    if (sc.alt) kb.alt = true;
    if (sc.ctrl) kb.control = true;
    if (sc.primary) {
        if (builtin.os.tag == .macos) kb.command = true else kb.control = true;
    }
    if (sc.super) kb.command = true;
    return kb;
}

/// Register menu shortcuts on `dvui.Window.keybinds`. Call after `installMainMenu`.
pub fn syncMenuShortcuts(win: *dvui.Window) !void {
    try syncMenuKeybinds(win);
}

fn syncMenuKeybinds(win: *dvui.Window) !void {
    if (menu_serial == synced_serial) return;

    removeRegisteredKeybinds(win);
    shortcut_ids = &.{};

    const mb = stored_bar orelse return;

    var new_shortcut_ids: std.ArrayList(zmenu.ActionId) = .empty;
    const arena = menu_arena.allocator();
    var buf: [64]u8 = undefined;
    errdefer {
        for (new_shortcut_ids.items) |action_id| {
            const name = menuBindName(&buf, action_id);
            _ = win.keybinds.remove(name);
        }
    }
    for (mb.menus) |menu| {
        for (menu.items) |item| {
            switch (item) {
                .separator => {},
                .action => |act| {
                    if (!act.enabled) continue;
                    const sc = act.shortcut orelse continue;
                    const kb = shortcutToKeybind(sc);
                    const name = try std.fmt.bufPrint(buf[0..], "zmenu_action_{d}", .{act.action_id});
                    try win.keybinds.put(win.gpa, name, kb);
                    try new_shortcut_ids.append(arena, act.action_id);
                },
            }
        }
    }
    shortcut_ids = try new_shortcut_ids.toOwnedSlice(arena);
    synced_serial = menu_serial;
    last_win = win;
}

fn dispatchMenuShortcuts() void {
    var keybind_buf: [64]u8 = undefined;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |ke| {
                if (ke.action != .down and ke.action != .repeat) continue;
                for (shortcut_ids) |action_id| {
                    const name = menuBindName(&keybind_buf, action_id);
                    if (ke.matchBind(name)) {
                        queueAction(action_id);
                        break;
                    }
                }
            },
            else => {},
        }
    }
}

fn bracketedShortcutText(allocator: std.mem.Allocator, item: zmenu.Item.ActionItem) error{OutOfMemory}!?[]const u8 {
    const sc = item.shortcut orelse return null;
    const shortcut_txt = if (item.shortcut_display) |d|
        d
    else
        try zmenu.formatShortcutMenuLabel(allocator, sc);
    defer if (item.shortcut_display == null) allocator.free(shortcut_txt);
    return try std.fmt.allocPrint(allocator, "[{s}]", .{shortcut_txt});
}

fn queueAction(id: zmenu.ActionId) void {
    pending_action.store(id, .release);
}

pub fn pollActionId() ?zmenu.ActionId {
    const v = pending_action.swap(-1, .acq_rel);
    if (v < 0) return null;
    return v;
}

/// Typed poll: returns the queued action cast to `T`, or null if none pending.
pub fn pollAction(comptime T: type) ?T {
    const id = pollActionId() orelse return null;
    return std.enums.fromInt(T, id);
}

fn topMenuBarItemId(menu_index: usize) usize {
    return 1 + menu_index;
}
fn submenuRowId(menu_index: usize, item_index: usize) usize {
    return 0x10_0000 + menu_index * 4096 + item_index;
}
fn submenuPopupId(menu_index: usize, slot: u2) usize {
    return 0x20_0000 + menu_index * 8 + @as(usize, @intCast(slot));
}

/// Call every frame to render the in-app DVUI menu bar.
pub fn drawMenuBar() !void {
    const menu_bar = stored_bar orelse return;

    const win = dvui.currentWindow();
    try syncMenuKeybinds(win);
    dispatchMenuShortcuts();

    const bg_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .color_fill = .{ .color = dvui.themeGet().color(.control, .fill) } });
    defer bg_box.deinit();

    var m = dvui.menu(@src(), .horizontal, .{});
    defer m.deinit();

    const current_highlight_style = dvui.themeGet().highlight;
    var theme = dvui.themeGet();
    theme.highlight.fill = theme.color(.control, .fill_hover);
    dvui.themeSet(theme);
    defer {
        theme.highlight = current_highlight_style;
        dvui.themeSet(theme);
    }

    const alloc = menu_arena.allocator();

    for (menu_bar.menus, 0..) |menu, mi| {
        if (menuItemTop(@src(), menu.title, .{ .submenu = true }, .{
            .expand = .horizontal,
            .color_text = .{ .color = dvui.themeGet().color(.control, .text) },
            .id_extra = topMenuBarItemId(mi),
        })) |r| {
            var animator = dvui.animate(@src(), .{ .kind = .alpha, .duration = 250_000 }, .{
                .expand = .both,
                .id_extra = submenuPopupId(mi, 0),
            });
            defer animator.deinit();

            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = submenuPopupId(mi, 1) });
            defer fw.deinit();

            for (menu.items, 0..) |item, ii| {
                const row_id = submenuRowId(mi, ii);
                switch (item) {
                    .separator => {
                        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = row_id });
                    },
                    .action => |act| {
                        const shortcut_bracketed = try bracketedShortcutText(alloc, act);
                        defer if (shortcut_bracketed) |s| alloc.free(s);

                        if (menuLeafAction(@src(), act.title, shortcut_bracketed, act.enabled, .{
                            .expand = .horizontal,
                            .id_extra = row_id,
                        }) != null) {
                            if (act.enabled) {
                                queueAction(act.action_id);
                                fw.close();
                            }
                        }
                    },
                }
            }
        }
    }
}

fn menuItemTop(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: dvui.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);
    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| ret = r;
    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);
    dvui.labelNoFmt(@src(), label_str, .{}, label_opts);
    mi.deinit();
    return ret;
}

fn menuLeafAction(src: std.builtin.SourceLocation, title: []const u8, shortcut_bracketed: ?[]const u8, enabled: bool, opts: dvui.Options) ?dvui.Rect.Natural {
    const init: dvui.MenuItemWidget.InitOptions = .{};
    var mi = dvui.menuItem(src, init, opts);
    defer mi.deinit();
    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| ret = r;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = dvui.Rect.all(0), .padding = dvui.Rect.all(0) });
    defer row.deinit();

    var title_opts = opts.strip();
    title_opts.expand = .none;
    title_opts.margin = dvui.Rect.all(0);
    title_opts.padding = dvui.Rect.all(0);
    title_opts.gravity_y = 0.5;
    if (!enabled) title_opts.color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.35) };
    dvui.labelNoFmt(@src(), title, .{}, title_opts);

    if (shortcut_bracketed) |sc| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .width(10) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        var sc_opts = opts.strip();
        sc_opts.expand = .none;
        sc_opts.margin = dvui.Rect.all(0);
        sc_opts.padding = dvui.Rect.all(0);
        sc_opts.gravity_y = 0.5;
        const base = dvui.themeGet().color(.control, .text);
        sc_opts.color_text = .{ .color = if (enabled) base.opacity(0.48) else base.opacity(0.28) };
        dvui.labelNoFmt(@src(), sc, .{}, sc_opts);
    }

    return ret;
}

/// Installs the native shell menu for an SDL-backed DVUI window (resolves `HWND` on Windows from SDL properties).
pub fn installMainMenuForSdlDvuiWindow(allocator: std.mem.Allocator, menu_bar: zmenu.MenuBar, win: *dvui.Window) zmenu.InstallMainMenuError!void {
    const hwnd = if (builtin.os.tag == .windows) blk: {
        const sdl3 = @import("sdl-backend").c;
        const raw = sdl3.SDL_GetPointerProperty(
            sdl3.SDL_GetWindowProperties(win.backend.impl.window),
            sdl3.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
            null,
        );
        break :blk if (raw != null) @as(?*anyopaque, @ptrCast(raw)) else null;
    } else null;
    return zmenu.installMainMenu(allocator, menu_bar, .{ .windows_hwnd = hwnd });
}
