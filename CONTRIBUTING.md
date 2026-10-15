# Contributing

## Prerequisites

- Zig 0.17.0 (see `.zigversion`)
- On Linux, `libdbus-1-dev` for the native D-Bus backend and `libx11-dev` for window chrome

## Before opening a pull request

Run:

```sh
zig fmt --check build.zig build.zig.zon src examples
zig build test check
zig build ci
zig build -Dexamples=true
```

The default build and `check` compile and link the native tray without launching
it. `ci` cross-compiles and links native menu/tray binaries for Linux and Windows
on x86_64 and aarch64. Optional examples enable DVUI and wio dependencies.
Cross-building the window examples additionally requires target system libraries;
use `zig build ci-examples -Dexamples=true -Dcross-examples=true` with an appropriate
sysroot. Compile checks do not establish native desktop behavior.

Keep changes scoped, include tests for behavior changes where practical, and update `README.md` or `TASKS.md` when public behavior or backlog status changes.

## Platform changes

Native code must preserve behavior on macOS, Windows, and Linux. Linux D-Bus changes should be exercised on a native Linux session bus; macOS and Windows integrations should be smoke-tested on their native platforms.
