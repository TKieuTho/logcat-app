# Sun Firebase Event Studio (macOS)

A native SwiftUI macOS app starter for Sun Studio QA. Targets macOS 13+ and Apple Silicon M2/M4.

## User experience
- Detects connected Android devices with USB debugging enabled; device list refreshes every 3 seconds.
- Supports independent selection of two or more connected devices.
- Downloads Google's official macOS Android Platform Tools on first launch when no `adb` is found.
- Selects one of the five Sun game package IDs.
- Asks for confirmation before changing Firebase debug properties and separately before force-stopping/relaunching a game.
- Streams `FA` and `FA-SVC` Logcat lines concurrently from all authorized connected devices, with timestamps and raw lines. Each stream is scoped to its own ADB serial.
- Search/filter, inspect/copy raw event, copy visible logs, export visible logs.
- **Clear View only** removes rows from this app's display. A separate destructive menu action is required to clear the Android device's log buffer.
- Does not fabricate sample device events. Firebase DebugView remains the official source of truth.

## Build and install without typing Terminal commands
1. On a Mac, unzip this folder.
2. Double-click `Build and Install.command` in Finder.
3. If macOS asks, approve opening the script. It uses Apple's installed Swift toolchain to build and copies the app to `~/Applications`.
4. If the Mac does not have Xcode Command Line Tools / Xcode installed, install them first; the script will show a dialog rather than asking the user to type commands.

This source project has not been compiled or hardware-tested in this environment. USB access, Google download availability, macOS Gatekeeper behavior, and real-device log streaming must be verified on the target Mac before production use.

## Important technical limitations in this starter
- The stream list combines lines from all connected authorized devices; selecting a device filters the list to that device. Separate side-by-side panes are not implemented yet.
- Google Platform Tools are fetched from Google's official download endpoint on first launch if not already present. Internet is required for this first setup.
- This starter is unsigned and not notarized. Gatekeeper may require approval. A distributable DMG requires signing/notarization with the developer's Apple credentials.
- ADB's `setprop` changes are made only after the user confirms. Restarting the game requires a second confirmation.
- `Clear View` does not invoke `adb logcat -c`.

## Included package IDs
- Mahjong Classic — `studio.sun.mahjong.classic.casual.tile.matching`
- Tile Adventure — `studio.sun.tileadventure`
- Snake Escape — `studio.sun.snake.escape.puzzle`
- Blossom Master — `com.blossom.tile.match.puzzle`
- Solitaire Classic — `studio.sun.solitaire.classic.card.klondike.patience`
