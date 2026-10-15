//! DVUI app + zmenu: native shell menu by default; in-app DVUI menu bar with `-Dforce_dvui_menu=true`
//! or on Linux when `com.canonical.AppMenu.Registrar` has no D-Bus owner.
const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
const zopts = @import("zmenu_dvui_opts");
const zmenu = @import("zmenu");

var hello_count: u32 = 0;

const DemoAction = enum(zmenu.ActionId) {
    say_hello = 0,
    toggle_demo = 1,
    quit_hint = 2,
};

const file_items = [_]zmenu.Item{
    .{ .action = .{ .title = "Say Hello", .action_id = @backingInt(DemoAction.say_hello), .shortcut = .{ .key = .a, .primary = true } } },
    .separator,
    .{ .action = .{ .title = "Toggle DVUI Demo Window", .action_id = @backingInt(DemoAction.toggle_demo), .shortcut = .{ .key = .d, .primary = true } } },
};
const help_items = [_]zmenu.Item{
    .{ .action = .{ .title = "About zmenu fallback", .action_id = @backingInt(DemoAction.quit_hint) } },
};
const menus = [_]zmenu.Menu{
    .{ .title = "File", .items = &file_items },
    .{ .title = "Help", .items = &help_items },
};
const menu_bar: zmenu.MenuBar = .{ .menus = &menus };

pub const dvui_app: dvui.App = .{ .config = .{ .options = .{
    .size = .{ .w = 720.0, .h = 480.0 },
    .min_size = .{ .w = 400.0, .h = 300.0 },
    .title = "zmenu + DVUI",
    .transparent = if (builtin.os.tag == .macos or builtin.os.tag == .windows) true else false,
} }, .frameFn = AppFrame, .initFn = AppInit, .deinitFn = AppDeinit };

pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

pub fn AppInit(win: *dvui.Window) !void {
    zmenu.installMainMenu(win.gpa, menu_bar, .{
        .force_dvui = zopts.force_dvui_menu,
    }) catch |err| {
        std.log.err("installMainMenu: {s}", .{@errorName(err)});
    };
}

pub fn AppDeinit(_: *dvui.Window) void {
    zmenu.shutdownMenu();
}

pub fn AppFrame() !dvui.App.Result {
    try zmenu.drawMenuBar();

    if (zmenu.pollAction(DemoAction)) |action| {
        switch (action) {
            .say_hello => {
                hello_count += 1;
                std.log.info("Hello from zmenu (#{d})", .{hello_count});
            },
            .toggle_demo => {
                dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
            },
            .quit_hint => std.log.info("Use the window close button or platform shortcut to quit.", .{}),
        }
    }

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer box.deinit();

    const hint =
        \\Default: native shell menu (Windows HMENU / macOS NSMenu / Linux D-Bus when an AppMenu registrar exists).
        \\On Linux without AppMenu registrar, falls back to in-app DVUI menu bar automatically.
        \\Force in-app DVUI menu: zig build run-dvui -Dexamples=true -Dforce_dvui_menu=true
    ;
    dvui.labelNoFmt(@src(), hint, .{}, .{ .expand = .horizontal });
    dvui.Examples.demo(.lite);
    return .ok;
}
