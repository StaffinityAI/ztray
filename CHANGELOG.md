# Changelog

All notable changes are documented here.

## Unreleased

### Added

- `trayHostAvailable()`: on Linux, whether an `org.kde.StatusNotifierWatcher` displays the tray icon (stock GNOME has none).

### Changed

- The Linux D-Bus backend loads `libdbus-1.so.3` at runtime instead of linking it. Builds need no D-Bus headers or pkg-config, and explicit glibc Linux targets (for example AppImage release builds) get the real tray instead of the stub.

## 0.1.0-dev.1

### Added

- Linux StatusNotifier `IconPixmap` support for embedded PNG tray icons.
- Cross-platform GitHub Actions CI and Zig formatting validation.
- Contribution and security reporting policies.

### Changed

- Native menubar lifecycle, Linux D-Bus validation, tray update safety, action delivery, and platform behavior are documented in the public API and README.
