//! Minimal wio window using zmenu native menus.
const std = @import("std");
const builtin = @import("builtin");

const wio = @import("wio");
const zmenu = @import("zmenu");

pub const std_options = std.Options{ .log_level = .info, .logFn = wio.logFn };

comptime {
    _ = wio;
}

var window: wio.Window = undefined;
var events: wio.EventQueue = .empty;

const DemoAction = enum(zmenu.ActionId) {
    say_hello = 0,
    about = 1,
};

const file_items = [_]zmenu.Item{
    .{ .action = .{ .title = "Say Hello", .action_id = @backingInt(DemoAction.say_hello), .shortcut = .{ .key = .h, .primary = true } } },
};
const help_items = [_]zmenu.Item{
    .{ .action = .{ .title = "About", .action_id = @backingInt(DemoAction.about) } },
};
const menus = [_]zmenu.Menu{
    .{ .title = "File", .items = &file_items },
    .{ .title = "Help", .items = &help_items },
};
const menu_bar: zmenu.MenuBar = .{ .menus = &menus };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try wio.init(.{ .allocator = gpa, .io = io, .eventFn = wio.EventQueue.eventFn });

    window = try wio.Window.create(.{
        .event_fn_data = &events,
        .title = "zmenu + wio (native menus)",
        .scale = 1,
        .size = .{ .width = 560, .height = 360 },
    });

    zmenu.installMainMenu(gpa, menu_bar, .{
        .windows_hwnd = if (builtin.os.tag == .windows) @ptrCast(window.backend.window) else null,
    }) catch |err| {
        std.log.err("installMainMenu: {s}", .{@errorName(err)});
    };

    try wio.run(loop);
}

fn loop() !bool {
    while (events.pop()) |event| {
        switch (event) {
            .close => {
                window.destroy();
                events.deinit();
                wio.deinit();
                return false;
            },
            else => {},
        }
    }

    if (zmenu.pollAction(DemoAction)) |action| {
        switch (action) {
            .say_hello => std.log.info("Hello from native menu", .{}),
            .about => std.log.info("zmenu wio example.", .{}),
        }
    }

    wio.wait(.{ .timeout_ns = std.time.ns_per_ms });
    return true;
}
