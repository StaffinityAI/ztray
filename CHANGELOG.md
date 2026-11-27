# Changelog

All notable changes are documented here.

## Unreleased

### Added

- `trayHostAvailable()`: on Linux, whether an `org.kde.StatusNotifierWatcher` displays the tray icon (stock GNOME has none).

### Fixed

- Linux `com.canonical.dbusmenu.GetLayout` replies with the revision and the layout as two values (`u(ia{sv}av)`); wrapping both in one struct made GDBus hosts such as GNOME's AppIndicator extension reject the menu.
- Linux dbusmenu implements `GetGroupProperties`, which GNOME uses to read menu item properties.
- Linux tray icons with a PNG report an empty `IconName`, so hosts draw the PNG instead of the generic fallback icon.
- Linux tray menus open directly with their items instead of a single submenu named after `TrayMenu.title`.
- Linux tray icons with a PNG no longer abort the process when a host reads `IconPixmap`: the pixel bytes are now appended inside their own `ay` container, as libdbus requires.
- Linux StatusNotifierItem answers `org.freedesktop.DBus.Properties.GetAll` (and exposes `ItemIsMenu`). GNOME's AppIndicator extension reads items only through `GetAll` and unregistered the icon right after registration, so no tray icon appeared on GNOME.

### Changed

- The Linux D-Bus backend loads `libdbus-1.so.3` at runtime instead of linking it. Builds need no D-Bus headers or pkg-config, and explicit glibc Linux targets (for example AppImage release builds) get the real tray instead of the stub.

## 0.1.0-dev.1

### Added

- Linux StatusNotifier `IconPixmap` support for embedded PNG tray icons.
- Cross-platform GitHub Actions CI and Zig formatting validation.
- Contribution and security reporting policies.

### Changed

- Native menubar lifecycle, Linux D-Bus validation, tray update safety, action delivery, and platform behavior are documented in the public API and README.
