# Swoosh

Swoosh is a macOS window gesture app for people who want fast, fluid window control from the trackpad. It lets you move, snap, resize, restore, and fullscreen windows with simple multi-touch gestures while keeping the app lightweight and out of the way.

The goal is to make window management feel natural on macOS: quick gestures, clear previews, sensible settings, and a menu bar app that stays quiet until you need it.

## Features

- Trackpad gestures for common window actions
- Window snapping to halves, corners, center, restore, and fullscreen
- Smooth continuous gesture transitions
- Visual previews before actions are committed
- Configurable gesture timing, sensitivity, and preview behavior
- Optional global keyboard shortcuts
- Launch at login support
- Built-in permission and diagnostics view

## Tech Stack

- Swift
- SwiftUI for the settings interface
- AppKit for the menu bar app and macOS integration
- macOS Accessibility APIs for window targeting
- CoreGraphics and ApplicationServices for display and window geometry
- Swift Package Manager for building and testing

## Build

Build the app bundle:

```bash
scripts/build_app.sh
```

Build and install to `/Applications`:

```bash
scripts/build_app.sh --install
```

If you have a stable signing certificate, the build script will use it automatically when there is exactly one valid code-signing identity. You can also pass it directly:

```bash
scripts/build_app.sh --install --identity "Apple Development: Your Name (TEAMID)"
```

## Permissions

Swoosh needs macOS permissions for gesture capture and window control:

- Accessibility
- Input Monitoring

After installing a newly signed app for the first time, open Swoosh and follow the setup prompts. Future rebuilds should keep permissions when the bundle identifier, signing identity, and install path stay the same.

## Development

Run the test suite:

```bash
swift test
```

Build the command-line products:

```bash
swift build
```

## Project

- Author: Yudhna
- Repository: https://github.com/yudhnaa/swoosh
- Contact: hoanganhduy75@gmail.com
