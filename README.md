# Logcat — Sun Firebase Event Studio (macOS)

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

## Cài bản tải về (.zip) và xử lý khi macOS chặn
App chưa được Apple ký/notarize, nên lần đầu mở macOS có thể báo **"Logcat can't be opened"** hoặc **"Logcat is damaged"**. Đây là Gatekeeper, không phải lỗi app.

1. Giải nén zip, kéo **Logcat.app** vào **Applications** (khi cập nhật chọn Replace).
2. Mở Terminal, chạy lệnh sau để bỏ cờ quarantine rồi mở lại app:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Logcat.app
   ```
   Nếu để app ở `~/Applications` thì đổi đường dẫn tương ứng.
3. Hoặc không dùng Terminal: bấm chuột phải vào Logcat.app → **Open** → **Open**; hoặc vào **System Settings → Privacy & Security**, kéo xuống bấm **Open Anyway**.

Chỉ cần làm một lần cho mỗi bản tải mới. Build bằng `Build and Install.command` thì không bị chặn vì script đã tự gỡ quarantine.

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
