const std = @import("std");

/// Which Unix display backends the **zwindow** Linux module compiles in. Parse from `-Dzwindow_unix_backends`.
pub const ZwindowUnixBackends = enum {
    x11,
    wayland,
    both,

    pub fn parse(backends_str: []const u8) ZwindowUnixBackends {
        var enable_x11 = false;
        var enable_wayland = false;
        var iter = std.mem.tokenizeScalar(u8, backends_str, ',');
        while (iter.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r\n");
            if (t.len == 0) continue;
            if (std.mem.eql(u8, t, "x11")) {
                enable_x11 = true;
            } else if (std.mem.eql(u8, t, "wayland")) {
                enable_wayland = true;
            } else {
                @panic("invalid zwindow_unix_backends token (expected x11 and/or wayland)");
            }
        }
        if (!enable_x11 and !enable_wayland) return .both;
        if (enable_x11 and enable_wayland) return .both;
        if (enable_x11) return .x11;
        return .wayland;
    }

    pub fn x11Enabled(self: ZwindowUnixBackends) bool {
        return self != .wayland;
    }
    pub fn waylandEnabled(self: ZwindowUnixBackends) bool {
        return self != .x11;
    }
};

fn linkNativeMenuBar(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .macos => {
            mod.addCSourceFile(.{ .file = b.path("src/macos_menu.m") });
            mod.linkFramework("AppKit", .{});
        },
        .windows => {
            mod.linkSystemLibrary("comctl32", .{});
            mod.linkSystemLibrary("user32", .{});
        },
        .linux => {
            const native_linux = b.graph.host.result.os.tag == .linux and
                b.graph.host.result.cpu.arch == target.result.cpu.arch and
                b.graph.host.result.abi == target.result.abi;
            if (native_linux) {
                mod.addCSourceFile(.{ .file = b.path("src/linux_dbus_menu.c") });
                mod.addCSourceFile(.{ .file = b.path("src/linux_tray_png.c") });
                mod.linkSystemLibrary("dbus-1", .{});
            } else {
                mod.addCSourceFile(.{ .file = b.path("src/linux_dbus_stub.c") });
            }
        },
        else => {},
    }
}

fn linkNativeTray(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .macos => {
            mod.addCSourceFile(.{ .file = b.path("src/macos_tray.m") });
            mod.linkFramework("AppKit", .{});
        },
        .windows => {
            mod.addCSourceFile(.{ .file = b.path("src/windows_tray_png.c") });
            mod.linkSystemLibrary("shell32", .{});
            mod.linkSystemLibrary("comctl32", .{});
            mod.linkSystemLibrary("gdi32", .{});
        },
        .linux => {}, // linux_dbus_menu.c linked via zmenu dependency
        else => {},
    }
}

/// Native menu bar module (no DVUI). Import as `addImport("zmenu", …)`.
pub fn createZmenuModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/zmenu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = switch (target.result.os.tag) {
            .windows, .linux => true,
            else => null,
        },
    });
    linkNativeMenuBar(mod, b, target);
    return mod;
}

/// System tray module. Requires `zmenu_mod` for shared types. Import as `addImport("ztray", …)`.
pub fn createZtrayModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zmenu_mod: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/ztray.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (target.result.os.tag == .windows) true else null,
    });
    mod.addImport("zmenu", zmenu_mod);
    linkNativeTray(mod, b, target);
    return mod;
}

/// Optional native window frame styling. Import as `addImport("zwindow", …)`.
pub fn createZwindowModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    unix_backends: ZwindowUnixBackends,
) *std.Build.Module {
    const zwindow_mod = b.createModule(.{
        .root_source_file = b.path("src/window_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) {
        zwindow_mod.addCSourceFile(.{ .file = b.path("src/macos_window.m") });
        zwindow_mod.linkFramework("AppKit", .{});
    }
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("win32", .{})) |dep| {
            zwindow_mod.addImport("win32", dep.module("win32"));
        }
        zwindow_mod.linkSystemLibrary("dwmapi", .{});
        zwindow_mod.linkSystemLibrary("comctl32", .{});
        zwindow_mod.linkSystemLibrary("user32", .{});
        zwindow_mod.linkSystemLibrary("gdi32", .{});
    }
    if (target.result.os.tag == .linux) {
        const zwindow_opts = b.addOptions();
        zwindow_opts.addOption(bool, "x11", unix_backends.x11Enabled());
        zwindow_opts.addOption(bool, "wayland", unix_backends.waylandEnabled());
        zwindow_mod.addOptions("zwindow_build_options", zwindow_opts);
        if (unix_backends.x11Enabled()) zwindow_mod.linkSystemLibrary("X11", .{});
        zwindow_mod.link_libc = true;
    }
    return zwindow_mod;
}

/// Unified zmenu + DVUI in-app menu bar. Same public API as zmenu plus `zmenu.dvui_menu`. Import as `addImport("zmenu", …)`.
pub fn createZmenuDvuiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zmenu_mod: *std.Build.Module,
    dvui_mod: *std.Build.Module,
    sdl_mod: *std.Build.Module,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/zmenu_with_dvui.zig"),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("zmenu_core", zmenu_mod);
    m.addImport("dvui", dvui_mod);
    m.addImport("sdl-backend", sdl_mod);
    return m;
}

const DvuiImports = struct {
    dvui: *std.Build.Module,
    sdl: *std.Build.Module,
};

fn dvuiImportsFromDep(dep: *std.Build.Dependency) DvuiImports {
    return .{ .dvui = dep.module("dvui_sdl3"), .sdl = dep.module("sdl3") };
}

fn dvuiExampleOptsModule(b: *std.Build, force_dvui_menu: bool) *std.Build.Module {
    const zopts = b.addOptions();
    zopts.addOption(bool, "force_dvui_menu", force_dvui_menu);
    return zopts.createModule();
}

fn addDvuiExampleExe(
    b: *std.Build,
    zmenu_dvui_mod: *std.Build.Module,
    example_opts_mod: *std.Build.Module,
    d: DvuiImports,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.Compile {
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/dvui_fallback/App.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("dvui", d.dvui);
    example_mod.addImport("sdl-backend", d.sdl);
    example_mod.addImport("zmenu", zmenu_dvui_mod);
    example_mod.addImport("zmenu_dvui_opts", example_opts_mod);
    return b.addExecutable(.{ .name = exe_name, .root_module = example_mod });
}

fn addWioMenuExe(
    b: *std.Build,
    zmenu_mod: *std.Build.Module,
    wio_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.Compile {
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/wio_menu/App.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("wio", wio_mod);
    example_mod.addImport("zmenu", zmenu_mod);
    return b.addExecutable(.{ .name = exe_name, .root_module = example_mod });
}

fn addWioTrayExe(
    b: *std.Build,
    zmenu_mod: *std.Build.Module,
    ztray_mod: *std.Build.Module,
    zwindow_mod: *std.Build.Module,
    wio_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.Compile {
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/wio_tray_window/App.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("wio", wio_mod);
    example_mod.addImport("zmenu", zmenu_mod);
    example_mod.addImport("ztray", ztray_mod);
    example_mod.addImport("zwindow", zwindow_mod);
    return b.addExecutable(.{ .name = exe_name, .root_module = example_mod });
}

fn addWioWindowExe(
    b: *std.Build,
    zwindow_mod: *std.Build.Module,
    wio_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.Compile {
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/wio_window/App.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("wio", wio_mod);
    example_mod.addImport("zwindow", zwindow_mod);
    return b.addExecutable(.{ .name = exe_name, .root_module = example_mod });
}

fn addTrayMinimalExe(
    b: *std.Build,
    ztray_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.Compile {
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/tray_minimal/App.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("ztray", ztray_mod);
    return b.addExecutable(.{ .name = exe_name, .root_module = example_mod });
}

fn linkLinuxDynamic(exe: *std.Build.Step.Compile, host_os: std.Target.Os.Tag, target_os: std.Target.Os.Tag) void {
    if (target_os == .linux and host_os == .linux) exe.linkage = .dynamic;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const force_dvui_menu = b.option(bool, "force_dvui_menu", "DVUI sample only: use in-app menu bar instead of native shell menus") orelse false;

    const zmenu_mod = createZmenuModule(b, target, optimize);
    const ztray_mod = createZtrayModule(b, target, optimize, zmenu_mod);
    const zwindow_mod = createZwindowModule(b, target, optimize, ZwindowUnixBackends.parse(b.option(
        []const u8,
        "zwindow_unix_backends",
        "Comma-separated zwindow Linux backends: x11, wayland (default: x11,wayland)",
    ) orelse "x11,wayland"));
    b.modules.put(b.allocator, "zmenu", zmenu_mod) catch @panic("out of memory");
    b.modules.put(b.allocator, "ztray", ztray_mod) catch @panic("out of memory");
    b.modules.put(b.allocator, "zwindow", zwindow_mod) catch @panic("out of memory");

    const examples = b.option(bool, "examples", "Build optional DVUI and wio examples") orelse false;
    if (examples) {
        if (b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3, .@"tree-sitter" = false, .accesskit = .off })) |dvui_dep| {
            const d = dvuiImportsFromDep(dvui_dep);
            const example_opts_mod = dvuiExampleOptsModule(b, force_dvui_menu);
            const zmenu_dvui_mod = createZmenuDvuiModule(b, target, optimize, zmenu_mod, d.dvui, d.sdl);

            const example_exe = addDvuiExampleExe(b, zmenu_dvui_mod, example_opts_mod, d, target, optimize, "zmenu-dvui");
            b.installArtifact(example_exe);

            const run_cmd = b.addRunArtifact(example_exe);
            run_cmd.step.dependOn(b.getInstallStep());
            const run_step = b.step("run-dvui", "Run the DVUI + zmenu sample");
            run_step.dependOn(&run_cmd.step);
            run_cmd.addPassthruArgs();
        }

        if (b.lazyDependency("wio", .{ .target = target, .optimize = optimize })) |wio_dep| {
            const wio_mod = wio_dep.module("wio");

            {
                const exe = addWioMenuExe(b, zmenu_mod, wio_mod, target, optimize, "zmenu-wio");
                linkLinuxDynamic(exe, b.graph.host.result.os.tag, target.result.os.tag);
                b.installArtifact(exe);
                const run_cmd = b.addRunArtifact(exe);
                run_cmd.step.dependOn(b.getInstallStep());
                const run_step = b.step("run-wio", "Run the zmenu + wio native menu sample");
                run_step.dependOn(&run_cmd.step);
                run_cmd.addPassthruArgs();
            }

            {
                const exe = addWioTrayExe(b, zmenu_mod, ztray_mod, zwindow_mod, wio_mod, target, optimize, "ztray-wio-tray");
                linkLinuxDynamic(exe, b.graph.host.result.os.tag, target.result.os.tag);
                b.installArtifact(exe);
                const run_cmd = b.addRunArtifact(exe);
                run_cmd.step.dependOn(b.getInstallStep());
                const run_step = b.step("run-wio-tray", "Run the zmenu + ztray + wio sample");
                run_step.dependOn(&run_cmd.step);
                run_cmd.addPassthruArgs();
            }

            if (target.result.os.tag == .macos) {
                const exe = addWioWindowExe(b, zwindow_mod, wio_mod, target, optimize, "zwindow-wio");
                b.installArtifact(exe);
                const run_cmd = b.addRunArtifact(exe);
                run_cmd.step.dependOn(b.getInstallStep());
                const run_step = b.step("run-wio-window", "Run wio + zwindow only");
                run_step.dependOn(&run_cmd.step);
                run_cmd.addPassthruArgs();
            }
        }

        {
            const exe = addTrayMinimalExe(b, ztray_mod, target, optimize, "ztray-minimal");
            linkLinuxDynamic(exe, b.graph.host.result.os.tag, target.result.os.tag);
            b.installArtifact(exe);
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            const run_step = b.step("run-tray", "Run the tray-only ztray sample");
            run_step.dependOn(&run_cmd.step);
            run_cmd.addPassthruArgs();
        }
    }

    const types_test_mod = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const types_tests = b.addTest(.{ .name = "zmenu-types-tests", .root_module = types_test_mod });
    const run_types_tests = b.addRunArtifact(types_tests);

    const linux_test_mod = b.createModule(.{
        .root_source_file = b.path("src/linux.zig"),
        .target = target,
        .optimize = optimize,
    });
    const linux_tests = b.addTest(.{ .name = "zmenu-linux-tests", .root_module = linux_test_mod });
    const run_linux_tests = b.addRunArtifact(linux_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_types_tests.step);
    test_step.dependOn(&run_linux_tests.step);

    const check = b.step("check", "Compile and link the native tray without launching it");
    const smoke = addTrayMinimalExe(b, ztray_mod, target, optimize, "ztray-native-check");
    linkLinuxDynamic(smoke, b.graph.host.result.os.tag, target.result.os.tag);
    check.dependOn(&smoke.step);
    _ = smoke.getEmittedBin();
    b.default_step = if (examples) b.getInstallStep() else check;
    const ci_step = b.step("ci", "Compile native tray contracts for supported targets without device access");
    ci_step.dependOn(check);
    setupZtrayCi(b, ci_step);
    if (b.option(bool, "cross-examples", "Cross-build examples (requires target system libraries and examples=true)") orelse false) {
        if (!examples) @panic("cross-examples requires examples=true");
        setupZtrayExampleCi(b, b.step("ci-examples", "Cross-build examples with target system libraries"), force_dvui_menu);
    }
}

fn setupZtrayCi(b: *std.Build, ci_step: *std.Build.Step) void {
    for ([_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
    }) |query| {
        const resolved = b.resolveTargetQuery(query);
        const menu = createZmenuModule(b, resolved, .debug);
        const tray = createZtrayModule(b, resolved, .debug, menu);
        const exe = addTrayMinimalExe(b, tray, resolved, .debug, b.fmt("ztray-check-{s}-{s}", .{ @tagName(query.cpu_arch.?), @tagName(query.os_tag.?) }));
        linkLinuxDynamic(exe, b.graph.host.result.os.tag, resolved.result.os.tag);
        ci_step.dependOn(&exe.step);
        _ = exe.getEmittedBin();
    }
}

fn setupZtrayExampleCi(b: *std.Build, ci_step: *std.Build.Step, force_dvui_menu: bool) void {
    const optimize: std.builtin.OptimizeMode = .debug;

    const cross_targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
    };

    for (cross_targets) |q| {
        addZtrayCiExamplesForTarget(b, ci_step, b.resolveTargetQuery(q), optimize, force_dvui_menu);
    }

    if (b.graph.host.result.os.tag == .macos) {
        addZtrayCiExamplesForTarget(b, ci_step, b.graph.host, optimize, force_dvui_menu);
    }
}

fn addZtrayCiExamplesForTarget(
    b: *std.Build,
    ci_step: *std.Build.Step,
    resolved: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    force_dvui_menu: bool,
) void {
    const dvui_dep = b.lazyDependency("dvui", .{ .target = resolved, .optimize = optimize, .backend = .sdl3, .@"tree-sitter" = false, .accesskit = .off }) orelse return;
    const wio_dep = b.lazyDependency("wio", .{ .target = resolved, .optimize = optimize }) orelse return;

    const zmenu_mod = createZmenuModule(b, resolved, optimize);
    const ztray_mod = createZtrayModule(b, resolved, optimize, zmenu_mod);
    const d = dvuiImportsFromDep(dvui_dep);
    const zmenu_dvui_mod = createZmenuDvuiModule(b, resolved, optimize, zmenu_mod, d.dvui, d.sdl);
    const example_opts_mod = dvuiExampleOptsModule(b, force_dvui_menu);
    const wio_mod = wio_dep.module("wio");

    const os_tag = @tagName(resolved.result.os.tag);
    const arch_tag = @tagName(resolved.result.cpu.arch);

    ci_step.dependOn(&addDvuiExampleExe(b, zmenu_dvui_mod, example_opts_mod, d, resolved, optimize, b.fmt("zmenu-dvui-{s}-{s}", .{ arch_tag, os_tag })).step);

    {
        const exe = addWioMenuExe(b, zmenu_mod, wio_mod, resolved, optimize, b.fmt("zmenu-wio-{s}-{s}", .{ arch_tag, os_tag }));
        linkLinuxDynamic(exe, b.graph.host.result.os.tag, resolved.result.os.tag);
        ci_step.dependOn(&exe.step);
    }

    if (resolved.result.os.tag == .linux) {
        inline for (std.enums.values(ZwindowUnixBackends)) |zwb| {
            const zwindow_ci = createZwindowModule(b, resolved, optimize, zwb);
            const exe = addWioTrayExe(b, zmenu_mod, ztray_mod, zwindow_ci, wio_mod, resolved, optimize, b.fmt("ztray-wio-tray-{s}-{s}-zw-{s}", .{ arch_tag, os_tag, @tagName(zwb) }));
            linkLinuxDynamic(exe, b.graph.host.result.os.tag, resolved.result.os.tag);
            ci_step.dependOn(&exe.step);
        }
    } else {
        const zwindow_mod = createZwindowModule(b, resolved, optimize, .both);
        const exe = addWioTrayExe(b, zmenu_mod, ztray_mod, zwindow_mod, wio_mod, resolved, optimize, b.fmt("ztray-wio-tray-{s}-{s}", .{ arch_tag, os_tag }));
        linkLinuxDynamic(exe, b.graph.host.result.os.tag, resolved.result.os.tag);
        ci_step.dependOn(&exe.step);
    }

    if (resolved.result.os.tag == .macos) {
        const zwindow_mod = createZwindowModule(b, resolved, optimize, .both);
        const exe = addWioWindowExe(b, zwindow_mod, wio_mod, resolved, optimize, b.fmt("zwindow-wio-{s}-{s}", .{ arch_tag, os_tag }));
        ci_step.dependOn(&exe.step);
    }

    {
        const exe = addTrayMinimalExe(b, ztray_mod, resolved, optimize, b.fmt("ztray-minimal-{s}-{s}", .{ arch_tag, os_tag }));
        linkLinuxDynamic(exe, b.graph.host.result.os.tag, resolved.result.os.tag);
        ci_step.dependOn(&exe.step);
    }
}
