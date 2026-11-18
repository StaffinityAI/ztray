//! [wio](https://github.com/ypsvlq/wio) window + **zwindow** only (no ztray menu or tray).
//! On Linux: `zwindow.LinuxFrameTarget` from `wio.backend` + `window.backend`.
const std = @import("std");
const builtin = @import("builtin");

const wio = @import("wio");
const zwindow = @import("zwindow");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = wio.logFn,
};

comptime {
    _ = wio;
}

var window: wio.Window = undefined;
var events: wio.EventQueue = .empty;

fn applyZwindowFrameChrome() void {
    switch (builtin.os.tag) {
        .windows, .macos => zwindow.setFrameChrome(
            @ptrCast(window.backend.window),
            .{ .r = 0.18, .g = 0.19, .b = 0.24, .dark = true, .policy = .full_vibrancy },
        ),
        .linux => {
            var frame = switch (wio.backend.active) {
                .x11 => zwindow.LinuxFrameTarget.fromX11(
                    @ptrCast(wio.backend.x11.globals.display),
                    window.backend.x11.window,
                ),
                .wayland => zwindow.LinuxFrameTarget.fromWayland(
                    @ptrCast(wio.backend.wayland.globals.display),
                    @ptrCast(window.backend.wayland.surface),
                ),
            };
            zwindow.setFrameChrome(@ptrCast(&frame), .{ .r = 0.18, .g = 0.19, .b = 0.24, .dark = true, .policy = .full_vibrancy });
        },
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try wio.init(.{ .allocator = gpa, .io = io, .eventFn = wio.EventQueue.eventFn });

    window = try wio.Window.create(.{
        .event_fn_data = &events,
        .title = "zwindow + wio",
        .scale = 1,
        .size = .{ .width = 520, .height = 340 },
    });

    applyZwindowFrameChrome();

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

    wio.wait(.{ .timeout_ns = std.time.ns_per_ms });
    return true;
}
