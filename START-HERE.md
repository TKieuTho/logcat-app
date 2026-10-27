# Sun Firebase Event Log Studio — Download Bundle

This bundle contains the native macOS SwiftUI source starter and a double-click build/install script.

## Hosted viewer
Open: https://sun-firebase-event.hatchable.site
Hatchable console: https://hatchable.com/console/projects/sun-firebase-event

## Build the native macOS app
1. Unzip this bundle on the target Mac (Apple Silicon M2/M4; macOS 13+).
2. Open the `macOS-source` folder in Finder.
3. Double-click `Build and Install.command`.
4. If Xcode Command Line Tools are missing, install them before trying again.

The script attempts to build and install `Sun Firebase Event Studio.app` in `~/Applications`. It is not signed or notarized, and Gatekeeper may require approval.

## Important status
This is a SOURCE STARTER BUNDLE, not a precompiled `.app` or signed `.dmg`. It has not been compiled or tested against physical Android devices in this environment. A Mac build and two-device hardware test are still required before treating it as production-ready.

## Device safety
- The app prompts before changing Firebase debug properties and separately before relaunching a game.
- Clear View only clears the app's visible list; it must not clear the Android device log buffer.
- Firebase DebugView remains the source of truth; Logcat is auxiliary evidence.
