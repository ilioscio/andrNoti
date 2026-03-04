# Changelog

## [0.3.0] — 2026-03-03

### Server
- Added `--token` flag as alternative to `--token-file` (plain string token,
  less secure, intended for users without agenix)
- Both flags remain mutually exclusive; one is required

### Android App
- Fixed foreground service dying after ~6 hours: changed `foregroundServiceType`
  from `dataSync` to `remoteMessaging` in AndroidManifest.xml and updated the
  corresponding permission. Android 14+ caps `dataSync` services at 6 hours;
  `remoteMessaging` has no such limit.
- Added `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission and request it at
  startup (`FlutterForegroundTask.isIgnoringBatteryOptimizations` /
  `requestIgnoreBatteryOptimization()`). Prompts system dialog on first launch;
  no-ops if already granted. Prevents Doze mode / OEM task killers.
- Wrapped `_showAlert`'s fire-and-forget `_localNotifications.show()` future
  with `.catchError` to prevent uncaught async exceptions in the task isolate.
- Note: API in flutter_foreground_task 8.17.0 uses `isIgnoringBatteryOptimizations`
  (plural) and `requestIgnoreBatteryOptimization` (singular). Check if these
  change on upgrade to 9.x.

### Infrastructure (ilios.dev)
- Added `modules/alerts.nix` — server-side alerting via andrNoti:
  - **Boot notification**: `notify-boot.service` fires after
    `network-online.target` and `andr-noti.service` are up. Sends
    "ilios.dev online / Server came online".
  - **Disk space monitor**: `disk-space-alert.service` + `.timer` runs every
    30 minutes (first run 5 min after boot). Alerts at 85% usage on any
    non-virtual filesystem (`df --output=pcent,target -x tmpfs -x devtmpfs
    -x efivarfs`). Uses full Nix store paths for all binaries (coreutils,
    curl) to avoid PATH issues in systemd.
  - **Service failure template**: `notify-on-failure@.service` template unit.
    `OnFailure=notify-on-failure@%N.service` wired into: nginx, matrix-synapse,
    postgresql, coturn, postfix, dovecot (note: NixOS 25.11 renamed the
    systemd unit from `dovecot2` to `dovecot`), livekit, lk-jwt-service,
    matrix-authentication-service. Guards use `lib.mkIf
    (config.services.X.enable or false)` for standard NixOS services;
    matrix-authentication-service (defined directly via systemd.services in
    mas.nix) is always included.
  - All notification scripts use `|| true` so a dead andrNoti server does not
    cascade-fail the calling unit.
  - Template unit uses `after = ["andr-noti.service"]` (ordering only, not
    requires — notification still attempts even if andrNoti is down).
- Removed `./modules/andrNoti.nix` from configuration.nix imports; server
  config now comes from `andrNoti.nixosModules.default` in flake.nix.

### Nix / Repo
- Version bumped to 0.3.0 in `flake.nix` (`buildGoModule`) and
  `app/pubspec.yaml` (`0.3.0+3`).

---

## [0.2.0] — 2026-02-28

### Project Restructure
- Reorganised into monorepo at `github:ilioscio/andrNoti`:
  - `server/` — Go source (was `ilios.dev/andrNoti/`)
  - `app/` — Flutter Android app (was `~/Projects/andrNotiApp/`)
  - `flake.nix` — unified root flake replacing both `andrNotiApp/flake.nix`
    and `modules/andrNoti.nix`
- `andrNotiApp/flake.nix` deleted; its devShell and `buildApk` app merged
  into the root flake. `nix run .#buildApk` auto-detects whether it is run
  from repo root or `app/` subdirectory.
- `ilios.dev/flake.nix` updated: added `andrNoti` input
  (`inputs.nixpkgs.follows = "nixpkgs"`), added `andrNoti.nixosModules.default`
  with inline config block (agenix secret, `services.andrNoti`, `andr-notify`
  CLI tool).
- `ilios.dev/modules/andrNoti.nix` superseded by the flake module (kept on
  disk but no longer imported).
- `.gitignore` at repo root covers: `result`, `result-*` (Nix build outputs),
  `app/.metadata`. Subdirectory gitignores (`app/.gitignore`,
  `app/android/.gitignore`) handle the rest. `app/.git` (nested repo from
  copy) was manually deleted before first commit.

### NixOS Module (`nixosModules.default`)
- Options: `enable`, `port` (default 8086), `hostname` (nullable, enables
  nginx vhost + ACME when set), `tokenFile` (path, for agenix), `token`
  (plain string, less secure), `package`.
- `tokenFile` and `token` are mutually exclusive; assertions enforce this.
- nginx config included in module: rate limiting (`limit_req_zone
  andrnoti_ws:1m rate=5r/s`, `burst=10 nodelay`) on `/ws`, WebSocket upgrade
  headers, 3600s read/send timeouts.
- `overlays.default` exposes `andr-noti` package.

### Server Hardening
- nginx rate limiting: 5 req/s with burst=10 on `/ws` endpoint.
- WebSocket connection cap: `h.connectedCount() >= 15` checked before upgrade.
- `vendorHash` changed from `null` (vendor committed) to
  `sha256-M16ieYmUqzWJm5ZWFu4ISVD4553EHh31wT8oH1sJZX4=` (fetched by Nix).

### SSH / CLI Usage Note
- `andr-notify "multi word title" "multi word text"` works locally.
- Via SSH, must single-quote the whole remote command:
  `ssh server 'andr-notify "title" "text"'` — SSH flattens args into a flat
  string before the remote shell sees them; local quotes are stripped.

---

## [0.1.0] — 2026-02-27

### Initial Implementation

#### Server (`server/main.go`)
- Single-file Go HTTP server (~470 lines). Dependencies: `gorilla/websocket`,
  `modernc.org/sqlite` (pure-Go, no CGO, Nix-friendly).
- SQLite schema: `notifications(id, title, text, created_at, seen_at)`.
  `seen_at` added via `ALTER TABLE ... ADD COLUMN` migration (silently ignored
  if column exists, enabling safe re-deploy against existing DBs).
- Routes:
  - `POST /send` — Bearer auth, inserts row, broadcasts to WS hub
  - `GET /history?limit=N&offset=N` — Bearer auth, returns JSON array
  - `POST /mark-seen` — Bearer auth, body `{"ids":[...]}` or empty for all
  - `DELETE /notifications` — Bearer auth, deletes all records
  - `GET /ws?token=...` — query-param auth (WS clients can't set headers),
    sends history on connect then live notifications
  - `GET /health` — unauthenticated 200
- WebSocket hub: `map[*client]struct{}` + buffered broadcast channel.
  `readPump` / `writePump` / `pingPump` per client. 70s read deadline reset
  on pong; 30s ping interval.
- Flags: `--port`, `--token-file`, `--token`, `--db`.

#### Android App (`app/`)
- Flutter foreground service app. Key packages: `flutter_foreground_task`,
  `flutter_local_notifications`, `web_socket_channel` (actually uses
  `dart:io` WebSocket directly), `shared_preferences`, `http`.
- `FlutterForegroundTask.initCommunicationPort()` MUST be called in `main()`
  before anything else. Without it, `sendDataToMain` from the task isolate
  silently drops all messages (IsolateNameServer lookup returns null).
- `NotificationTaskHandler` runs in background isolate: connects WebSocket,
  exponential backoff reconnect (2s → 60s max), pings via WS keep-alive.
- `ForegroundTaskOptions`: `autoRunOnBoot: true`, `autoRunOnMyPackageReplaced:
  true`, `allowWakeLock: true`, `allowWifiLock: true`, repeat every 15s
  (health check / reconnect trigger).
- Home screen: two tabs (New / Old). New tab shows unseen notifications with
  swipe-to-dismiss (marks seen). Old tab is accordion grouped by year/month/day.
  FAB marks all seen. "Clear all history" button with confirmation dialog calls
  `DELETE /notifications`.
- `notificationStore` global map (`Map<int, AppNotification>`) populated in
  main isolate so `onNotificationResponse` (notification tap) can look up the
  full object and navigate to detail screen.
- App icon: `flutter_launcher_icons` with `assets/icon.png`. AppBar shows
  `assets/IconWhite.png` instead of text.
- Debug panel: toggle in settings screen (`showDebugPanel` in `AppConfig`),
  renders log output in HomeScreen when enabled.
- `app/android/.gitignore` already excludes `local.properties` (contains
  stale Nix store path for `flutter.sdk` — regenerated automatically on build).

#### NixOS Deployment
- Systemd service: `User=andr-noti`, `Group=andr-noti`, `StateDirectory=
  andr-noti`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`,
  `PrivateTmp`, `ReadWritePaths=["/var/lib/andr-noti"]`.
- Agenix secret: `secrets/andr-noti-token.age`, `owner=andr-noti`,
  `group=andr-noti`, `mode=0440`. ilios user added to `andr-noti` group in
  `configuration.nix` (`users.users.ilios.extraGroups`) for CLI access.
- `andr-notify` shell script in `environment.systemPackages`: wraps curl POST
  to `http://127.0.0.1:8086/send`.

---

## Architectural Notes (for future reference)

### Version bump checklist
1. `flake.nix` — `version = "X.Y.Z"` in `buildGoModule`
2. `app/pubspec.yaml` — `version: X.Y.Z+N` where N increments on every APK
   install (Android rejects equal or lower build numbers)
3. Commit and push to `github:ilioscio/andrNoti`
4. In `ilios.dev/`: `nix flake update andrNoti` then `nix run .`

### APK install
- Install over the top (no uninstall needed) as long as the signing key is
  unchanged and build number incremented. Data (config, token) is preserved.

### Key file locations
- Server source: `server/main.go`, `server/go.mod`
- App source: `app/lib/*.dart` (7 files: main, models, config, config_screen,
  home_screen, detail_screen, notification_manager)
- Root flake: `flake.nix` (server package, Flutter devShell, buildApk app,
  nixosModules.default, overlays.default)
- ilios.dev integration: `flake.nix` (andrNoti input + inline config),
  `modules/alerts.nix`
- Agenix secret: `secrets/andr-noti-token.age` (in ilios.dev repo)

### Known gotchas
- `dovecot2` NixOS service was renamed to `dovecot` in nixpkgs ~25.11.
  Use `systemd.services.dovecot` with `lib.mkIf config.services.dovecot2.enable`.
- Mixing `systemd.services.foo = ...` (dot notation) with
  `systemd.services = lib.mkMerge [...]` in the same NixOS module is a Nix
  language error (duplicate attribute). Use dot notation throughout.
- `flutter_foreground_task` 8.17.0: `isIgnoringBatteryOptimizations` (plural),
  `requestIgnoreBatteryOptimization` (singular). Verify on upgrade to 9.x.
- New files in ilios.dev must be `git add`ed before `nix build` — flake
  evaluation only copies git-tracked files to the Nix store.
- `lib.fakeHash` in `buildGoModule` triggers a hash mismatch error that prints
  the correct `vendorHash` to copy in.
