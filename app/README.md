# andrNoti — Android App

Android client for the andrNoti push notification server. Runs a foreground service that maintains a persistent WebSocket connection and surfaces incoming notifications via the system notification tray.

## Features

- Persistent WebSocket connection that survives screen-off and background
- System notifications for each incoming message
- **New** tab — unseen notifications, swipe right to mark one seen, or tap the checkmark FAB to mark all
- **Old** tab — seen notifications grouped by date, with a clear-all option
- Tap any notification (in-app or tray) to open the full message
- Settings screen to configure server URL and token

## First-time setup

1. Install the APK on your device.
2. Open the app and tap the settings icon (top right).
3. Enter your server WebSocket URL, e.g. `wss://notify.example.com/ws`
4. Enter your auth token.
5. Tap **Save** — the foreground service starts and connects immediately.

Grant notification permission when prompted on Android 13+.

## Building

From the repo root:

```bash
nix develop       # enter the Flutter dev environment
nix run .#buildApk  # build a release APK
```

APK output: `build/app/outputs/flutter-apk/app-release.apk`

For development with a connected device:

```bash
nix develop
cd app
flutter run
```
