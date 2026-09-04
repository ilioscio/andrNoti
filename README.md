# Aisthetron

*An instrument of perception* — a self-hosted bridge between wearables and
infrastructure (formerly **andrNoti**). A Go **relay server** stores
notifications, machine telemetry, and health samples in SQLite and broadcasts
over WebSocket; an **Android app** maintains a persistent connection and presents
three views — Notifications, Health, and Machines. Remote machines send
heartbeats so the relay tracks them and alerts you if they go silent or a watched
service fails; a paired Galaxy Watch streams health telemetry through the phone
to your own server; and the Machines view can pull a host's systemd logs on
demand, behind a biometric gate.

Everything runs on your own hardware. No FCM, no Samsung/Google cloud, no
third-party telemetry.

## What it does

- **Notifications relay** — `POST /send` from any host or script; the app shows
  it instantly over WebSocket and as a local Android notification.
- **Heartbeat monitoring** — remote machines register by beating on an interval;
  the relay alerts on silence and auto-sends a recovery notice on return.
- **Service (systemd) monitoring** — hosts report a declared set of units; a
  failed unit raises a push and shows red in the Machines view.
- **Remote logs** — pull a unit's `journalctl` / `systemctl status` from the
  phone through a relay-mediated command queue served by a read-only host agent,
  gated behind biometric auth + a separate control token.
- **Health telemetry** — a Galaxy Watch (native Wear OS collector) streams heart
  rate / steps / calories / distance through the phone into `/metrics`; the
  Health view charts current and historical readings.

```
                     wearable (Galaxy Watch, native collector)
                                    │ Wear Data Layer
                                    ▼
[remote host]──POST /heartbeat──┐   phone ──POST /metrics──┐
[remote host]──POST /heartbeat──┤   (health samples)       │
   (+ units status)             │                          │
[curl / CLI / service]──POST /send                         │
                                ▼                           ▼
                        Go relay server  (SQLite + WebSocket hub)
                        heartbeat checker · unit-failure alerts
                        fleet command queue (audit log)
                                │ WSS /ws          ▲
                                ▼                  │ /fleet/poll (long-poll)
                         Android app         aisthetron-agent (read-only, per host)
                  (Notifications · Health · Machines,
                   Material You, foreground service)
```

---

## Relay Server (NixOS flake)

The relay runs the Go binary, manages the SQLite database, and optionally
configures nginx with TLS. Add it to any flake-based NixOS system.

### 1 — Add the flake input

```nix
inputs.aisthetron = {
  url = "github:ilioscio/aisthetron";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

### 2 — Import the module and configure

```nix
aisthetron.nixosModules.default   # import the module

{
  services.aisthetron = {
    enable = true;

    # Port the Go server binds on localhost. Default: 8086.
    port = 8086;

    # When set, the module creates an nginx vhost with ACME TLS, WebSocket
    # upgrade headers, and rate limiting on /ws. null = manage nginx yourself.
    hostname = "notify.example.com";

    # Broadcast auth token — one of tokenFile or token (not both). tokenFile is
    # preferred: it is not baked into the Nix store.
    tokenFile = config.age.secrets.aisthetron-token.path;
    # token = "plain-string-token";   # less secure, OK for non-production

    # OPTIONAL elevated control token, distinct from the broadcast token above.
    # Gates the /fleet/command surface (remote logs, and later service control).
    # Unset ⇒ that surface returns 503 and the feature is off. Must differ from
    # the broadcast token. See docs/FLEET-MONITORING.md.
    # controlTokenFile = config.age.secrets.aisthetron-control-token.path;

    # Missed beats before alerting on a remote source. With interval=60 and
    # missed=3, an alert fires after ~3 minutes of silence. Default: 3.
    heartbeatMissed = 3;

    # SQLite directory. Default: /var/lib/aisthetron. Override to migrate onto a
    # pre-existing data dir in place (e.g. a legacy /var/lib/andr-noti).
    # dataDir = "/var/lib/aisthetron";
  };
}
```

The module creates:
- System user/group `aisthetron`
- `systemd.services.aisthetron` — hardened (`ProtectSystem=strict`, `PrivateTmp`,
  `NoNewPrivileges`), state in `dataDir`
- nginx vhost with rate limiting (5 req/s, burst 10) on `/ws` when `hostname` is
  set

### 3 — Create the auth token secret

The broadcast token is a shared secret between the relay and every client (the
app, the CLI, remote heartbeat senders). Generate once:

```bash
openssl rand -hex 32
```

With **agenix** (the secret name is your choice; the maintainer's live
deployments keep the legacy `andr-noti-token`):

```bash
agenix -e secrets/aisthetron-token.age
```

```nix
age.secrets.aisthetron-token = {
  file  = ./secrets/aisthetron-token.age;
  owner = "aisthetron";
  group = "aisthetron";
  mode  = "0440";
};
# Let your admin user read it for the CLI:
users.users.youruser.extraGroups = [ "aisthetron" ];
```

### 4 — Add the CLI tool

A shell wrapper to send notifications from the relay's shell. Include `"source"`
to label which machine sent the alert:

```nix
environment.systemPackages = [
  (pkgs.writeShellScriptBin "aisthetron-notify" ''
    TITLE="''${1:?Usage: aisthetron-notify <title> [text]}"
    TEXT="''${2:-$1}"
    TOKEN="$(cat ${config.age.secrets.aisthetron-token.path})"
    curl -sf -X POST "http://127.0.0.1:8086/send" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"$TITLE\",\"text\":\"$TEXT\",\"source\":\"relay.example.com\"}"
  '')
];
```

```bash
aisthetron-notify "Deploy done" "v1.4 is live."
# Via SSH — single-quote the whole remote command (SSH flattens args):
ssh yourserver 'aisthetron-notify "Deploy done" "v1.4 is live."'
```

### Firewall

Open 80/443 for nginx. The Go server only binds `127.0.0.1` and is never exposed
directly.

---

## Remote Server Monitoring (heartbeat sender)

Any server you want monitored registers itself by POSTing to `/heartbeat` on an
interval. If a source goes silent for `interval × heartbeatMissed` seconds the
relay inserts an alert and broadcasts it; on return it auto-sends a recovery.

**Alert flow:**
- Source silent → alert after `interval × heartbeatMissed` seconds
- Source back → automatic recovery notification
- Relay itself down → the app inserts an optimistic entry in the New tab and
  fires a local notification after a grace period; on reconnect it's replaced by
  a server record with the exact outage duration

### Option A — NixOS flake

On the remote host, add the `aisthetron` input (same as above) and configure the
heartbeat sender. This creates a oneshot service + persistent timer:

```nix
aisthetron.nixosModules.default   # import the module

{
  services.aisthetron.heartbeat = {
    enable = true;

    # Name shown in alerts ("work-server unreachable" / "… recovered") and used
    # by the app to address fleet commands. MUST be unique per host.
    source = "work-server";

    relayUrl = "https://notify.example.com";   # no trailing slash

    # Seconds between beats. Alert threshold = interval × relay.heartbeatMissed.
    interval = 60;

    # false for intermittent devices (laptops): status is tracked and shown, but
    # missed-heartbeat AND failed-unit pushes are suppressed. Default: true.
    # monitor = false;

    # OPTIONAL: systemd units to report each beat. Their ActiveState/SubState
    # shows in the Machines view; a failed unit raises a push. To also allow log
    # retrieval for them, mirror this list in services.aisthetron-agent.units.
    # units = [ "nginx.service" "postgresql.service" ];

    tokenFile = config.age.secrets.aisthetron-token.path;
  };
}
```

Creates `systemd.services.aisthetron-heartbeat` (oneshot `curl POST /heartbeat`)
and `systemd.timers.aisthetron-heartbeat` (fires every `interval`,
`Persistent=true`, first run 30s after boot). The relay auto-registers a source
on its first beat — no per-source relay config.

`services.aisthetron.heartbeat.enable` is independent of
`services.aisthetron.enable`: a remote host runs only the sender.

### Option B — Non-NixOS / manual

```bash
* * * * * root curl -sf \
  -X POST "https://notify.example.com/heartbeat" \
  -H "Authorization: Bearer $(cat /run/secrets/aisthetron-token)" \
  -H "Content-Type: application/json" \
  -d '{"source":"work-server","interval":60}' || true
```

---

## Fleet Service Monitoring & Remote Logs

Hosts report a declared set of systemd units, and you can pull a unit's journal
or `systemctl status` on demand from the phone. Logs flow through a
relay-mediated command queue served by a **read-only, unprivileged** host agent
(`services.aisthetron-agent`); a separate **control token** gates the elevated
`/fleet/command` endpoint, and the app puts the whole thing behind a biometric
gate. It is read-only by design — there is no start/stop/restart path.

**The common task — adding monitoring for a newly-deployed service — plus the
full security model, host setup, control-token generation, API, and
troubleshooting are in [`docs/FLEET-MONITORING.md`](docs/FLEET-MONITORING.md).**
In short: add the unit to **both** `services.aisthetron.heartbeat.units` and
`services.aisthetron-agent.units` on that host, then rebuild.

Minimal per-host agent:

```nix
services.aisthetron-agent = {
  enable    = true;
  relayUrl  = "https://notify.example.com";
  host      = "work-server";                 # = heartbeat.source
  tokenFile = config.age.secrets.aisthetron-agent-token.path;  # agent-readable
  units     = [ "nginx.service" "postgresql.service" ];        # local allowlist
};
```

The agent runs as an unprivileged `aisthetron-agent` user in the
`systemd-journal` group, heavily sandboxed, and re-validates every command
against its own allowlist before running anything via an explicit `exec` argv.

---

## Health Telemetry (wearable)

A paired Galaxy Watch runs a native Wear OS collector (Health Services passive
monitoring) and streams samples over the Wear Data Layer to the phone, which
forwards them to `POST /metrics`. No Samsung Health or Google cloud is involved.
The app's Health view shows current readings (`/metrics/latest`) and scrubbable
historical charts with calendar navigation (`/metrics?metric=&from=&to=`).

Samples are `{metric, value, unit, ts}` batches (e.g. `heart_rate` bpm, `steps`,
`calories`, `distance`). The relay stores them in a `samples` table indexed by
`(metric, ts)`.

---

## Android App

The Flutter app (Material You dynamic color, bundled JetBrains Mono, monospace
"cyberdeck" theme) presents:

- **Notifications** — live feed with calendar day-navigation and history.
- **Health** — current readings as instrument tiles + per-metric historical
  charts (scrub, pinch-zoom, calendar).
- **Machines** — the control view: status LEDs, a node tally, per-host detail
  with a SERVICES panel, and biometric-gated remote logs.

It holds a persistent WebSocket via an Android foreground service so alerts
arrive continuously. Configure in **Settings**:
- **Server WebSocket URL** — `wss://notify.example.com/ws`
- **Auth Token** — the broadcast token
- **Control Token** *(optional)* — the elevated token for remote logs; stored in
  the Android Keystore, gated by biometric

The app lives in `app/` (Flutter source, `android/`, and the native Wear OS
collector under `app/watch/`). Build a release APK from the repo root — the root
flake drives it:

```bash
nix run .#buildApk          # or: nix develop -c bash -c 'cd app && flutter build apk --release'
# Output: app/build/app/outputs/flutter-apk/app-release.apk
```

---

## API Reference

All endpoints except `/health` and `/ws` require `Authorization: Bearer <token>`.
The **control** scope uses the separate control token; everything else uses the
broadcast token.

| Method | Path | Scope | Body / Params | Description |
|--------|------|-------|---------------|-------------|
| `POST` | `/send` | broadcast | `{"title","text","source"}` | Send a notification (`source` optional, shown as a label). |
| `POST` | `/heartbeat` | broadcast | `{"source","interval","monitor"?,"health"?,"units"?}` | Register/refresh a source. `units:[{name,active,sub}]` updates status + alerts on failure. |
| `GET`  | `/history` | broadcast | `?limit=50&offset=0` | Notification history, newest first. |
| `POST` | `/mark-seen` | broadcast | `{"ids":[…]}` or empty | Mark specific (or all) notifications seen. |
| `DELETE` | `/notifications` | broadcast | — | Delete all notification records. |
| `GET`  | `/machines` | broadcast | — | Registry of heartbeat + event sources, with status, health, and a `units` array. |
| `POST` | `/metrics` | broadcast | `{"source","samples":[{metric,value,unit,ts}]}` | Batch-ingest health samples. |
| `GET`  | `/metrics` | broadcast | `?metric=&from=&to=&limit=` | Time-series query for one metric. |
| `GET`  | `/metrics/latest` | broadcast | — | Newest sample per metric. |
| `POST` | `/fleet/command` | **control** | `{"host","action","unit","lines"}` | Enqueue a command (`action` ∈ `journal`\|`unit-status`). Returns `{"id"}`. `503` if control scope off. |
| `GET`  | `/fleet/command?id=N` | **control** | — | Poll a command's status/result. |
| `GET`  | `/fleet/poll?host=X` | broadcast (host) | — | Agent long-poll for its next command; claims atomically. `204` on timeout. |
| `POST` | `/fleet/result` | broadcast (host) | `{"id","status","result","result_code"}` | Agent posts a claimed command's outcome. |
| `GET`  | `/ws?token=…` | query param | — | WebSocket: full history on connect, then live notifications. |
| `GET`  | `/health` | none | — | Returns 200. |

### Server flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | `8086` | TCP port (loopback only) |
| `--token-file` | — | Path to broadcast token file (mutually exclusive with `--token`) |
| `--token` | — | Plain-string broadcast token |
| `--control-token-file` | — | Path to the elevated control token. Must differ from the broadcast token; absent ⇒ `/fleet/command` disabled |
| `--db` | `notifications.db` | SQLite database path (opened with WAL + `busy_timeout`) |
| `--heartbeat-missed` | `3` | Missed beats before alerting on a remote source |

---

## Repository layout

| Path | Description |
|------|-------------|
| `server/main.go` | Go relay server (single file) |
| `agent/main.go` | Read-only host agent for the fleet command queue (pure stdlib) |
| `flake.nix` | Server + agent packages, Flutter devShell, `buildApk`, `nixosModules.default` (relay, heartbeat sender, `aisthetron-agent`), `overlays.default` |
| `docs/FLEET-MONITORING.md` | Service monitoring & remote logs runbook |
| `CHANGELOG.md` | Full version history and architectural notes |
| `app/` | Flutter app (`lib/`, `android/`) — Notifications / Health / Machines |
| `app/watch/` | Native Wear OS health collector (Kotlin, Health Services + Data Layer) |

### NixOS modules

- `services.aisthetron` — relay server (`enable`, `port`, `hostname`, `tokenFile`,
  `controlTokenFile`, `heartbeatMissed`, `dataDir`) and the heartbeat sender under
  `services.aisthetron.heartbeat` (`enable`, `source`, `relayUrl`, `interval`,
  `monitor`, `units`, `tokenFile`).
- `services.aisthetron-agent` — the read-only host agent (`enable`, `relayUrl`,
  `host`, `tokenFile`, `units`).
