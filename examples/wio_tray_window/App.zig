//! wio window with zmenu native menubar and ztray system tray (icon + menu).
const std = @import("std");
const builtin = @import("builtin");

const wio = @import("wio");
const zmenu = @import("zmenu");
const ztray = @import("ztray");
const zwindow = @import("zwindow");

pub const std_options = std.Options{ .log_level = .info, .logFn = wio.logFn };

comptime {
    _ = wio;
}

extern fn NSApplicationLoad() void;

var window: wio.Window = undefined;
var events: wio.EventQueue = .empty;

const MenuBarAction = enum(zmenu.ActionId) {
    say_hello = 0,
    about = 1,
};

const TrayAction = enum(c_int) {
    hello = 1,
    quit = 2,
};

const file_items = [_]zmenu.Item{
    .{ .action = .{ .title = "Say Hello", .action_id = @backingInt(MenuBarAction.say_hello), .shortcut = .{ .key = .h, .primary = true } } },
};
const help_items = [_]zmenu.Item{
    .{ .action = .{ .title = "About", .action_id = @backingInt(MenuBarAction.about) } },
};
const menus = [_]zmenu.Menu{
    .{ .title = "File", .items = &file_items },
    .{ .title = "Help", .items = &help_items },
};
const menu_bar: zmenu.MenuBar = .{ .menus = &menus };

const tray_items = [_]zmenu.Item{
    .{ .action = .{ .title = "Say hello (tray)", .action_id = @backingInt(TrayAction.hello) } },
    .separator,
    .{ .action = .{ .title = "Quit", .action_id = @backingInt(TrayAction.quit) } },
};
const tray_menu: ztray.TrayMenu = .{ .title = "Tray", .items = &tray_items };

fn applyFrameChrome() void {
    switch (builtin.os.tag) {
        .windows, .macos => zwindow.setFrameChrome(
            @ptrCast(window.backend.window),
            .{ .r = 0.12, .g = 0.13, .b = 0.17, .dark = true },
        ),
        .linux => {
            var frame = switch (wio.backend.active) {
                .x11 => zwindow.LinuxFrameTarget.fromX11(@ptrCast(wio.backend.x11.globals.display), window.backend.x11.window),
                .wayland => zwindow.LinuxFrameTarget.fromWayland(@ptrCast(wio.backend.wayland.globals.display), @ptrCast(window.backend.wayland.surface)),
            };
            zwindow.setFrameChrome(@ptrCast(&frame), .{ .r = 0.12, .g = 0.13, .b = 0.17, .dark = true });
        },
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try wio.init(.{ .allocator = gpa, .io = io, .eventFn = wio.EventQueue.eventFn });
    if (builtin.os.tag == .macos) NSApplicationLoad();

    window = try wio.Window.create(.{
        .event_fn_data = &events,
        .title = "zmenu + ztray + wio",
        .scale = 1,
        .size = .{ .width = 560, .height = 360 },
    });

    const win_hwnd: ?*anyopaque = if (builtin.os.tag == .windows) @ptrCast(window.backend.window) else null;

    zmenu.installMainMenu(gpa, menu_bar, .{ .windows_hwnd = win_hwnd }) catch |err| {
        std.log.err("installMainMenu: {s}", .{@errorName(err)});
    };

    ztray.installTrayIcon(gpa, .{
        .tooltip = "zmenu + ztray wio",
        .icon_png = if (builtin.os.tag == .linux) null else ztray.zig_favicon_png,
        .linux_icon_name = if (builtin.os.tag == .linux) "applications-utilities" else null,
        .windows_hwnd = win_hwnd,
    }) catch |err| {
        std.log.err("installTrayIcon: {s}", .{@errorName(err)});
        window.destroy();
        wio.deinit();
        return;
    };

    ztray.setTrayMenu(gpa, tray_menu) catch |err| {
        std.log.err("setTrayMenu: {s}", .{@errorName(err)});
        ztray.shutdownTray();
        window.destroy();
        wio.deinit();
        return;
    };

    applyFrameChrome();
    try wio.run(loop);
}

fn loop() !bool {
    while (events.pop()) |event| {
        switch (event) {
            .close => {
                ztray.shutdownTray();
                window.destroy();
                events.deinit();
                wio.deinit();
                return false;
            },
            else => {},
        }
    }

    ztray.pumpEvents();

    if (ztray.pollTrayAction(TrayAction)) |action| {
        switch (action) {
            .hello => std.log.info("Hello from tray", .{}),
            .quit => {
                ztray.shutdownTray();
                window.destroy();
                wio.deinit();
                return false;
            },
        }
    }

    if (zmenu.pollAction(MenuBarAction)) |action| {
        switch (action) {
            .say_hello => std.log.info("Hello from native menu", .{}),
            .about => std.log.info("zmenu + ztray wio example.", .{}),
        }
    }

    wio.wait(.{ .timeout_ns = std.time.ns_per_ms });
    return true;
}
