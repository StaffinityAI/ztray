//! Wayland frame chrome for zwindow: best-effort transparency + optional KDE blur.
//!
//! Loads `libwayland-client.so.0` at runtime via `std.DynLib`, so the ztray build does not have to link the Wayland client library (the cross-CI build from macOS therefore stays portable). On success we
//! 1. clear the surface's opaque region (`wl_surface.set_opaque_region(NULL)` + `wl_surface.commit`) so a compositing compositor can blend translucent content, and
//! 2. when `policy == .full_vibrancy` AND the compositor advertises `org_kde_kwin_blur_manager` (KWin), create a blur object for the surface and commit it.
//!
//! The colour channels `red` / `green` / `blue` and `dark` are accepted for API parity with macOS/Windows; on Wayland the title bar is drawn by libdecor (wio) and we only manipulate compositing flags here. Blur is best-effort: GNOME / wlroots compositors will silently fall through to the opaque-region clear without a blur.

const std = @import("std");
const common = @import("window_common.zig");

const log = std.log.scoped(.zwindow);

const Proxy = anyopaque;

const WlMessage = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const WlInterface,
};

const WlInterface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const WlMessage,
    event_count: c_int,
    events: ?[*]const WlMessage,
};

// `WL_MARSHAL_FLAG_DESTROY`: tells libwayland to destroy the proxy after sending the request. Used when invoking the protocol-defined destructor.
const WL_MARSHAL_FLAG_DESTROY: u32 = 1;

// wl_display request opcodes (built into libwayland; we only need GET_REGISTRY).
const OP_DISPLAY_GET_REGISTRY: u32 = 1;
// wl_registry request opcodes.
const OP_REGISTRY_BIND: u32 = 0;
// wl_surface request opcodes from the core wayland protocol.
const OP_SURFACE_SET_OPAQUE_REGION: u32 = 4;
const OP_SURFACE_COMMIT: u32 = 6;
// org_kde_kwin_blur_manager request opcodes.
const OP_BLUR_MGR_CREATE: u32 = 0;
// org_kde_kwin_blur request opcodes.
const OP_BLUR_COMMIT: u32 = 0;
const OP_BLUR_RELEASE: u32 = 2;

// Static wl_interface descriptors for the proxies WE create. Proxies that wio creates (wl_display, wl_surface) already carry libwayland's built-in descriptors and we never look at those here.

const registry_bind_types: [4]?*const WlInterface = .{ null, null, null, null };
const registry_global_types: [3]?*const WlInterface = .{ null, null, null };
const registry_global_remove_types: [1]?*const WlInterface = .{null};

const registry_requests = [_]WlMessage{
    .{ .name = "bind", .signature = "usun", .types = &registry_bind_types },
};
const registry_events = [_]WlMessage{
    .{ .name = "global", .signature = "usu", .types = &registry_global_types },
    .{ .name = "global_remove", .signature = "u", .types = &registry_global_remove_types },
};

const wl_registry_interface: WlInterface = .{
    .name = "wl_registry",
    .version = 1,
    .method_count = registry_requests.len,
    .methods = &registry_requests,
    .event_count = registry_events.len,
    .events = &registry_events,
};

const blur_set_region_types: [1]?*const WlInterface = .{null};
const blur_requests = [_]WlMessage{
    .{ .name = "commit", .signature = "", .types = null },
    .{ .name = "set_region", .signature = "?o", .types = &blur_set_region_types },
    .{ .name = "release", .signature = "", .types = null },
};

const org_kde_kwin_blur_interface: WlInterface = .{
    .name = "org_kde_kwin_blur",
    .version = 1,
    .method_count = blur_requests.len,
    .methods = &blur_requests,
    .event_count = 0,
    .events = null,
};

const blur_mgr_create_types: [2]?*const WlInterface = .{ &org_kde_kwin_blur_interface, null };
const blur_mgr_unset_types: [1]?*const WlInterface = .{null};
const blur_mgr_requests = [_]WlMessage{
    .{ .name = "create", .signature = "no", .types = &blur_mgr_create_types },
    .{ .name = "unset", .signature = "o", .types = &blur_mgr_unset_types },
};

const org_kde_kwin_blur_manager_interface: WlInterface = .{
    .name = "org_kde_kwin_blur_manager",
    .version = 1,
    .method_count = blur_mgr_requests.len,
    .methods = &blur_mgr_requests,
    .event_count = 0,
    .events = null,
};

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*Proxy, u32, [*c]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

const Fns = struct {
    wl_proxy_marshal_flags: *const fn (?*Proxy, u32, ?*const WlInterface, u32, u32, ...) callconv(.c) ?*Proxy,
    wl_proxy_get_version: *const fn (?*Proxy) callconv(.c) u32,
    wl_proxy_add_listener: *const fn (?*Proxy, [*c]?*const fn () callconv(.c) void, ?*anyopaque) callconv(.c) c_int,
    wl_proxy_destroy: *const fn (?*Proxy) callconv(.c) void,
    wl_display_roundtrip: *const fn (?*Proxy) callconv(.c) c_int,
};

const InitStatus = enum { uninit, ok, failed };

const BLUR_CACHE_CAP = 16;
const BlurCacheEntry = struct {
    surface: ?*anyopaque = null,
    blur: ?*Proxy = null,
};

var state: struct {
    dyn: std.DynLib = undefined,
    fns: Fns = undefined,
    init_status: InitStatus = .uninit,
    display: ?*Proxy = null,
    blur_manager: ?*Proxy = null,
    blur_cache: [BLUR_CACHE_CAP]BlurCacheEntry = @splat(BlurCacheEntry{}),
} = .{};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*Proxy,
    name: u32,
    interface_c: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = data;
    if (state.blur_manager != null) return;
    const interface = std.mem.span(@as([*:0]const u8, @ptrCast(interface_c)));
    if (!std.mem.eql(u8, interface, "org_kde_kwin_blur_manager")) return;

    const bind_version: u32 = @min(version, 1);
    const proxy = state.fns.wl_proxy_marshal_flags(
        registry,
        OP_REGISTRY_BIND,
        &org_kde_kwin_blur_manager_interface,
        bind_version,
        0,
        name,
        @as([*:0]const u8, "org_kde_kwin_blur_manager"),
        bind_version,
        @as(?*Proxy, null),
    ) orelse {
        log.debug("zwindow: failed to bind org_kde_kwin_blur_manager (name {d})", .{name});
        return;
    };
    state.blur_manager = proxy;
    log.debug("zwindow: bound org_kde_kwin_blur_manager (v{d})", .{bind_version});
}

fn registryGlobalRemove(
    data: ?*anyopaque,
    registry: ?*Proxy,
    name: u32,
) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const registry_listener: RegistryListener = .{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
};

fn loadLib() ?std.DynLib {
    const candidates = [_][:0]const u8{
        "libwayland-client.so.0",
        "libwayland-client.so",
    };
    for (candidates) |name| {
        if (std.DynLib.openZ(name)) |lib| return lib else |_| {}
    }
    return null;
}

fn lookupFns(lib: *std.DynLib) ?Fns {
    var out: Fns = undefined;
    inline for (@typeInfo(Fns).@"struct".field_names) |name| {
        const sym = lib.lookup(@FieldType(Fns, name), name) orelse {
            log.debug("zwindow: missing symbol {s} in libwayland-client", .{name});
            return null;
        };
        @field(out, name) = sym;
    }
    return out;
}

/// One-time init for `display`. On success leaves `state.init_status = .ok`; on any failure `.failed` and the public API behaves as a no-op. Safe to call repeatedly with the same `display`. Multiple distinct displays in one process are not supported (logged once).
fn ensureInit(display: *Proxy) bool {
    switch (state.init_status) {
        .ok => {
            if (state.display != display) {
                log.debug("zwindow: ignoring secondary wl_display (only one supported)", .{});
            }
            return state.display == display;
        },
        .failed => return false,
        .uninit => {},
    }

    state.dyn = loadLib() orelse {
        log.debug("zwindow: libwayland-client.so.0 not found; Wayland frame chrome disabled", .{});
        state.init_status = .failed;
        return false;
    };

    state.fns = lookupFns(&state.dyn) orelse {
        state.dyn.close();
        state.init_status = .failed;
        return false;
    };

    const registry = state.fns.wl_proxy_marshal_flags(
        display,
        OP_DISPLAY_GET_REGISTRY,
        &wl_registry_interface,
        state.fns.wl_proxy_get_version(display),
        0,
        @as(?*Proxy, null),
    ) orelse {
        log.debug("zwindow: wl_display.get_registry returned null", .{});
        state.dyn.close();
        state.init_status = .failed;
        return false;
    };

    const impl_ptr: [*c]?*const fn () callconv(.c) void = @ptrCast(@constCast(&registry_listener));
    if (state.fns.wl_proxy_add_listener(registry, impl_ptr, null) != 0) {
        log.debug("zwindow: wl_proxy_add_listener on registry failed", .{});
        state.fns.wl_proxy_destroy(registry);
        state.dyn.close();
        state.init_status = .failed;
        return false;
    }

    _ = state.fns.wl_display_roundtrip(display);

    // Registry proxy is intentionally kept alive for process lifetime — releasing it would stop us from learning about late `global` advertisements, and we don't expect to be unloaded.

    state.display = display;
    state.init_status = .ok;
    return true;
}

fn cacheFind(surface: *anyopaque) ?usize {
    for (&state.blur_cache, 0..) |entry, i| {
        if (entry.surface == surface) return i;
    }
    return null;
}

fn cacheFindEmpty() ?usize {
    for (&state.blur_cache, 0..) |entry, i| {
        if (entry.surface == null) return i;
    }
    return null;
}

fn cachePut(surface: *anyopaque, blur: *Proxy) bool {
    if (cacheFind(surface)) |idx| {
        state.blur_cache[idx].blur = blur;
        return true;
    }
    if (cacheFindEmpty()) |idx| {
        state.blur_cache[idx] = .{ .surface = surface, .blur = blur };
        return true;
    }
    log.debug("zwindow: Wayland blur cache full (cap={d}); blur disabled for surface", .{BLUR_CACHE_CAP});
    return false;
}

fn cacheTake(surface: *anyopaque) ?*Proxy {
    const idx = cacheFind(surface) orelse return null;
    const b = state.blur_cache[idx].blur;
    state.blur_cache[idx] = .{};
    return b;
}

fn surfaceClearOpaqueRegion(surface: *Proxy) void {
    _ = state.fns.wl_proxy_marshal_flags(
        surface,
        OP_SURFACE_SET_OPAQUE_REGION,
        null,
        state.fns.wl_proxy_get_version(surface),
        0,
        @as(?*Proxy, null),
    );
    _ = state.fns.wl_proxy_marshal_flags(
        surface,
        OP_SURFACE_COMMIT,
        null,
        state.fns.wl_proxy_get_version(surface),
        0,
    );
}

fn applyKdeBlur(surface: *Proxy) void {
    const manager = state.blur_manager orelse {
        log.debug("zwindow: org_kde_kwin_blur_manager not advertised; skipping blur", .{});
        return;
    };
    if (cacheFind(surface)) |_| return; // already enabled
    const blur = state.fns.wl_proxy_marshal_flags(
        manager,
        OP_BLUR_MGR_CREATE,
        &org_kde_kwin_blur_interface,
        state.fns.wl_proxy_get_version(manager),
        0,
        @as(?*Proxy, null),
        surface,
    ) orelse {
        log.debug("zwindow: failed to create org_kde_kwin_blur for surface", .{});
        return;
    };
    _ = state.fns.wl_proxy_marshal_flags(
        blur,
        OP_BLUR_COMMIT,
        null,
        state.fns.wl_proxy_get_version(blur),
        0,
    );
    if (!cachePut(surface, blur)) {
        _ = state.fns.wl_proxy_marshal_flags(
            blur,
            OP_BLUR_RELEASE,
            null,
            state.fns.wl_proxy_get_version(blur),
            WL_MARSHAL_FLAG_DESTROY,
        );
    }
}

fn releaseKdeBlur(surface: *Proxy) void {
    const blur = cacheTake(surface) orelse return;
    _ = state.fns.wl_proxy_marshal_flags(
        blur,
        OP_BLUR_RELEASE,
        null,
        state.fns.wl_proxy_get_version(blur),
        WL_MARSHAL_FLAG_DESTROY,
    );
}

pub fn applyTransparentTitlebar(ref: *const common.LinuxWaylandWindowRef) void {
    const display: *Proxy = @ptrCast(@alignCast(ref.display));
    const surface: *Proxy = @ptrCast(@alignCast(ref.surface));
    if (!ensureInit(display)) return;
    surfaceClearOpaqueRegion(surface);
}

pub fn setFrameChrome(ref: *const common.LinuxWaylandWindowRef, chrome: common.FrameChrome) void {
    const display: *Proxy = @ptrCast(@alignCast(ref.display));
    const surface: *Proxy = @ptrCast(@alignCast(ref.surface));
    if (!ensureInit(display)) return;
    surfaceClearOpaqueRegion(surface);
    switch (chrome.policy) {
        .full_vibrancy => applyKdeBlur(surface),
        .tray_compatible => releaseKdeBlur(surface),
    }
}
