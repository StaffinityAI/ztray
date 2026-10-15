# ztray

Cross-platform **menu bar** and **system tray** for Zig.

| Platform | Menu bar | Tray |
|----------|----------|------|
| macOS    | AppKit `NSMenu` | `NSStatusItem` |
| Windows  | Win32 `HMENU` + `comctl32` | `Shell_NotifyIcon` |
| Linux    | DBusMenu over D-Bus | StatusNotifierItem |

An optional **in-app** DVUI menu bar is available via `zmenu.dvui_menu` when you use `createZmenuDvuiModule`. The core module never imports DVUI. Tray is always native.

---

## Requirements

- Zig **0.17.0**

---

## Setup

Add a path (or fetched) dependency in `build.zig.zon`, then use matching
`target` / `optimize` values. Native module consumers do not enable the optional
DVUI or wio examples and do not acquire their dependencies.

### Native menus / tray only

```zig
const dep = b.dependency("ztray", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zmenu", dep.module("zmenu"));
exe.root_module.addImport("ztray", dep.module("ztray"));
```

### Native + DVUI in-app menu bar

```zig
const ztray = @import("ztray");

const zmenu_mod = ztray.createZmenuModule(b, target, optimize);
const ztray_mod = ztray.createZtrayModule(b, target, optimize, zmenu_mod);
const zmenu_dvui = ztray.createZmenuDvuiModule(
    b,
    target,
    optimize,
    zmenu_mod,
    dvui_mod,
    sdl_mod,
);
exe.root_module.addImport("zmenu", zmenu_dvui);
exe.root_module.addImport("ztray", ztray_mod);
```

Use `zmenu.dvui_menu` for in-app calls. Use `zmenu.installMainMenuForSdlDvuiWindow` to get the native `HWND` from SDL automatically on Windows.

### Optional window frame chrome (`zwindow`)

```zig
exe.root_module.addImport("zwindow", dep.module("zwindow"));
```

| OS | Call | Notes |
|----|------|-------|
| macOS | `zwindow.setFrameChrome(ns_window, policy)` | `.tray_compatible` / `.full_vibrancy` |
| Windows | `zwindow.setFrameChrome(hwnd, policy)` | |
| Linux | `zwindow.setFrameChrome(linux_frame_target, policy)` | X11: theme hint + opacity + KDE blur region; Wayland: clears opaque region, attaches KWin blur on `.full_vibrancy` |

`FrameChrome` support differs by platform:

| Platform | `r`, `g`, `b` | `a` | `dark` | `policy` |
|----------|---------------|-----|--------|----------|
| macOS | Tint | Tint opacity | Appearance hint | `.tray_compatible` or `.full_vibrancy` |
| Windows | Fixed DWM acrylic tint | Fixed opaque acrylic | Fixed dark DWM path | Ignored |
| Linux X11 | Ignored | `_NET_WM_WINDOW_OPACITY` | Ignored | KWin blur region for `.full_vibrancy` when available |
| Linux Wayland | Ignored | Opaque region is cleared; compositor decides blending | Ignored | KWin blur protocol for `.full_vibrancy` when available; up to 16 simultaneous blur surfaces |

Pass `-Dzwindow_unix_backends=x11,wayland` (default: both). Wayland support `dlopen`s `libwayland-client.so.0` at runtime — no static link needed.

`zwindow` is **not** re-exported from the core `ztray` module.

### Lifecycle and event handling

Call all zmenu, ztray, and zwindow APIs from the owning UI thread. Native backends use shared process-global state and are not safe for concurrent calls.

Install a native menubar once per process. A second `zmenu.installMainMenu` call returns `error.MenuAlreadyInstalled`. Tray icons can be removed with `ztray.shutdownTray`, after which they may be installed again.

Call `zmenu.pumpEvents()` or `ztray.pumpEvents()` each frame. On Windows, integrate message pumping with the framework loop; on macOS this runs a short Cocoa loop slice; on Linux it dispatches the shared session D-Bus connection.

`pollActionId` and `pollTrayActionId` clear one pending action. If multiple actions occur before polling, the newest action replaces prior unpolled actions. Action IDs must be non-negative; Linux D-Bus menus support at most 512 flattened items and otherwise return `error.MenuTooLarge`.

Menu titles, shortcut labels, tooltips, icon paths, and PNG bytes are copied or decoded during installation; callers may release them after the call returns. PNG icons on Windows and Linux are limited to 1024×1024 pixels and 4 MiB of decoded RGBA data.

On Linux, native menus require a session D-Bus and an AppMenu registrar. The combined DVUI module uses the in-app menubar only when registrar absence is known; while asynchronous discovery is pending, it installs the native menu. Linux tray icons require a StatusNotifier watcher supplied by the desktop environment; without one, installation still succeeds but no icon is displayed. Linux tray icons accept `linux_icon_name` for Freedesktop theme lookup and embedded PNG data, which is exposed as StatusNotifier `IconPixmap`.

---

## Supported targets

The native menu/tray compile CI matrix covers Linux x86_64 and aarch64, plus Windows x86_64 and ARM64. Example CI builds on current macOS, Windows, and Linux runners. Linux native builds require `libdbus-1-dev` and window chrome requires `libx11-dev`; desktop-visible menu, tray, and compositor behavior still requires smoke testing on the target environment.

```sh
zig build        # compile/link the native tray without launching
zig build test   # unit tests
zig build ci     # cross-compile native menu/tray without example dependencies
zig build -Dexamples=true    # install native examples without launching
```

### Build flags

| Flag | Meaning |
|------|---------|
| `-Dexamples=true` | Enable optional DVUI/wio examples and their dependencies |
| `-Dcross-examples=true` | Expose `ci-examples` with `-Dexamples=true`; target X11/desktop libraries must be available |
| `-Dforce_dvui_menu=true` | Force DVUI in-app menu bar in the `ztray-dvui` sample |
| `-Dzwindow_unix_backends` | Comma list: `x11`, `wayland` (default: `x11,wayland`) |

### Examples

Pass `-Dexamples=true` to each example command below. Running an example opens
native desktop windows or a tray; compilation and unit tests do not.

| Step | Binary | Notes |
|------|--------|-------|
| `zig build run-tray` | `ztray-minimal` | Tray icon + context menu only. |
| `zig build run-dvui` | `zmenu-dvui` | DVUI window + ztray. Native menu by default; `-Dforce_dvui_menu=true` for in-app. |
| `zig build run-wio` | `zmenu-wio` | [wio](https://github.com/ypsvlq/wio) window + native menus only. |
| `zig build run-wio-window` | `zwindow-wio` | wio + `zwindow.setFrameChrome(.full_vibrancy)`. |
| `zig build run-wio-tray` | `ztray-wio-tray` | wio + native menu bar + tray + `zwindow.setFrameChrome`. |

On Linux, wio and tray examples link dynamically where applicable.
