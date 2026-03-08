# andrNoti

Self-hosted push notification system. A Go **relay server** stores notifications
in SQLite and broadcasts them over WebSocket. Remote servers send heartbeats to
the relay so it can alert you if they go silent. An Android app maintains a
persistent WebSocket connection and displays everything as system notifications.

```
[remote server]──POST /heartbeat──┐
[remote server]──POST /heartbeat──┤
                                  ▼
[curl / andr-notify / service]──POST /send
                                  │
                          Go relay server
                        (SQLite + WS hub)
                         heartbeat checker
                                  │ WSS /ws
                                  ▼
                         Android app
                  (foreground service + local notifications)
```

---

## Relay Server (NixOS flake)

The relay server runs the Go binary, manages the SQLite database, and optionally
configures nginx with TLS. Add it to any NixOS flake-based system.

### 1 — Add the flake input

```nix
inputs.andrNoti = {
  url = "github:ilioscio/andrNoti";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

### 2 — Import the module and configure

In your `nixosConfigurations` outputs, pass the input through and import
`andrNoti.nixosModules.default`, then configure it:

```nix
# In your flake.nix outputs, e.g. inside a nixosSystem specialArgs or modules list:
andrNoti.nixosModules.default

# Inline config (separate module or same block):
{
  services.andrNoti = {
    enable   = true;

    # Port the Go server binds on localhost. Default: 8086.
    port     = 8086;

    # When set, the module creates an nginx virtual host with ACME TLS,
    # rate limiting on /ws, and WebSocket upgrade headers. Set to null
    # to manage nginx yourself. Default: null.
    hostname = "notify.example.com";

    # Auth token — one of tokenFile or token is required (not both).
    # tokenFile is preferred: it is not baked into the Nix store.
    tokenFile = config.age.secrets.andr-noti-token.path;
    # token = "plain-string-token";  # less secure, OK for non-production

    # How many consecutive missed heartbeats from a remote source before
    # alerting. Default: 3. With interval=60 and missed=3, alert fires
    # after ~3 minutes of silence.
    heartbeatMissed = 3;
  };
}
```

The module creates:
- System user/group `andr-noti`
- `systemd.services.andr-noti` (hardened: `ProtectSystem=strict`, `PrivateTmp`,
  `NoNewPrivileges`, state in `/var/lib/andr-noti/`)
- nginx vhost with rate limiting (5 req/s, burst 10) on `/ws` when `hostname`
  is set

### 3 — Create the auth token secret

The token is a shared secret between the relay server and every client (Android
app, `andr-notify` CLI, remote heartbeat senders). Generate once and store
securely:

```bash
openssl rand -hex 32
```

With **agenix**:
```bash
# in your ilios.dev repo:
agenix -e secrets/andr-noti-token.age
# add to secrets/secrets.nix with owner = "andr-noti", group = "andr-noti", mode = "0440"
```

```nix
age.secrets.andr-noti-token = {
  file  = ./secrets/andr-noti-token.age;
  owner = "andr-noti";
  group = "andr-noti";
  mode  = "0440";
};
```

Add the `ilios` (or your admin) user to the `andr-noti` group so the CLI tool
can read the token file:

```nix
users.users.youruser.extraGroups = [ "andr-noti" ];
```

### 4 — Add the CLI tool

Add a shell wrapper to `environment.systemPackages` so you can send
notifications from the relay server's shell. Include `"source"` to identify
which machine sent the alert in the app:

```nix
environment.systemPackages = [
  (pkgs.writeShellScriptBin "andr-notify" ''
    TITLE="''${1:?Usage: andr-notify <title> [text]}"
    TEXT="''${2:-$1}"
    TOKEN="$(cat ${config.age.secrets.andr-noti-token.path})"
    curl -sf -X POST "http://127.0.0.1:8086/send" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"$TITLE\",\"text\":\"$TEXT\",\"source\":\"relay.example.com\"}"
  '')
];
```

Usage:

```bash
andr-notify "Deploy done" "v1.4 is live."

# Via SSH (single-quote the whole remote command — SSH flattens args):
ssh yourserver 'andr-notify "Deploy done" "v1.4 is live."'
```

### Firewall

Open ports 80 and 443 for nginx. The Go server only binds on `127.0.0.1` and
is never exposed directly.

---

## Remote Server Monitoring (heartbeat sender)

Any server you want monitored registers itself by POSTing to the relay's
`/heartbeat` endpoint on a regular interval. The relay tracks the last-seen
time; if a source goes silent for `interval × heartbeat-missed` seconds it
inserts an alert notification and broadcasts it to the app.

**Alert flow:**
- Source goes silent → relay alerts after `interval × heartbeatMissed` seconds
- Source comes back → relay sends a recovery notification automatically
- Relay itself goes down → app inserts an entry in the New tab and fires a
  local Android notification after a configurable grace period (default 60s);
  on reconnection the entry is replaced by a server record with exact outage
  duration, no server involvement needed during the outage itself

### Option A — NixOS flake

On the remote server, add the andrNoti input (same as above) and configure the
heartbeat sender. This creates a systemd oneshot service + persistent timer:

```nix
andrNoti.nixosModules.default   # import the module

{
  services.andrNoti.heartbeat = {
    enable   = true;

    # Name shown in alert titles: "work-server unreachable", "work-server recovered"
    source   = "work-server";

    # HTTP/HTTPS base URL of the relay server (no trailing slash).
    relayUrl = "https://notify.example.com";

    # Heartbeat interval in seconds. Timer fires at this cadence.
    # Must match what the relay uses for the alert threshold calculation:
    #   alert fires after: interval × relay.heartbeatMissed seconds of silence
    # Default: 60.
    interval = 60;

    # Auth token — same secret as the relay server uses.
    tokenFile = config.age.secrets.andr-noti-token.path;
    # token = "plain-string-token";  # alternative
  };
}
```

The module creates:
- `systemd.services.andr-noti-heartbeat` — oneshot, runs `curl POST /heartbeat`
- `systemd.timers.andr-noti-heartbeat` — fires every `interval` seconds,
  `Persistent=true` (catches up on missed beats after downtime), first run 30s
  after boot

The relay auto-registers the source on the first heartbeat it receives. No relay
configuration is needed per-source.

**Note:** `services.andrNoti.heartbeat.enable` is independent of
`services.andrNoti.enable`. A remote server only needs the heartbeat sender; it
does not run the relay.

### Option B — Non-NixOS / manual (cron or systemd timer)

From any machine with `curl`, POST to the relay every minute:

```bash
# /etc/cron.d/andr-noti-heartbeat  (or a systemd timer equivalent)
* * * * * root curl -sf \
  -X POST "https://notify.example.com/heartbeat" \
  -H "Authorization: Bearer $(cat /run/secrets/andr-noti-token)" \
  -H "Content-Type: application/json" \
  -d '{"source":"work-server","interval":60}' || true
```

The `interval` field tells the relay how often to expect a beat from this
source. Use the same value as your cron/timer period.

---

## API Reference

All endpoints except `/health` and `/ws` require `Authorization: Bearer <token>`.

| Method | Path | Auth | Body / Params | Description |
|--------|------|------|---------------|-------------|
| `POST` | `/send` | Bearer | `{"title":"…","text":"…","source":"…"}` | Send a notification. `source` is optional; shown as a label in the app. |
| `POST` | `/heartbeat` | Bearer | `{"source":"name","interval":60}` | Register or refresh a remote source. Auto-registers on first call. Sends recovery notification if source was previously alerted as down. |
| `GET` | `/history` | Bearer | `?limit=50&offset=0` | Fetch notification history, newest first. |
| `POST` | `/mark-seen` | Bearer | `{"ids":[1,2,3]}` or empty body | Mark specific (or all) notifications as seen. |
| `DELETE` | `/notifications` | Bearer | — | Delete all notification records. |
| `GET` | `/ws?token=…` | Query param | — | WebSocket. Receives full history on connect, then live notifications as they arrive. |
| `GET` | `/health` | None | — | Returns 200. |

### Source field

`"source"` is an optional string on `POST /send`. The relay also sets
`"source":"andrNoti"` on system-generated notifications (heartbeat alerts,
recovery messages). The app displays it as a small label chip on each
notification.

### Server flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | `8086` | TCP port (loopback only) |
| `--token-file` | — | Path to token file (mutually exclusive with `--token`) |
| `--token` | — | Plain-string token |
| `--db` | `notifications.db` | SQLite database path |
| `--heartbeat-missed` | `3` | Missed beats before alerting on a remote source |

---

## Android App

See [`app/README.md`](app/README.md) for setup instructions.

Build a release APK from the repo root:

```bash
nix run .#buildApk
# Output: app/build/app/outputs/flutter-apk/app-release.apk
```

Configure in the app's Settings screen:
- **Server WebSocket URL** — `wss://notify.example.com/ws`
- **Auth Token** — the same token the relay server uses
- **Relay-down grace period** — seconds to wait before firing a local
  "relay unreachable" notification and inserting an entry in the New tab
  (default 60s)

---

## Key File Locations

| Path | Description |
|------|-------------|
| `server/main.go` | Go relay server (single file) |
| `server/go.mod` | Go module, dependencies |
| `app/lib/*.dart` | Flutter app source (7 files) |
| `app/android/app/src/main/AndroidManifest.xml` | Android permissions + service declaration |
| `flake.nix` | Server package, Flutter devShell, buildApk app, `nixosModules.default`, `overlays.default` |
| `CHANGELOG.md` | Full version history and architectural notes |
