# andrNoti

Self-hosted push notification system. A Go server stores notifications in SQLite and broadcasts them over WebSocket. An Android app maintains a persistent connection and displays them as system notifications.

```
[curl / andr-notify CLI]
        │ POST /send
        ▼
  Go server (SQLite + WebSocket hub)
        │ WSS
        ▼
  Android app (foreground service + local notifications)
```

## Server

### NixOS (flake)

Add the input to your flake:

```nix
inputs.andrNoti = {
  url = "github:ilioscio/andrNoti";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Add the module and configure it:

```nix
andrNoti.nixosModules.default

# inline config block:
{
  services.andrNoti = {
    enable   = true;
    port     = 8086;          # optional, default 8086
    hostname = "notify.example.com";  # enables nginx vhost + ACME
    tokenFile = "/run/secrets/andr-noti-token";  # path to token file
    # token = "plain-string";  # alternative — less secure
  };
}
```

`tokenFile` and `token` are mutually exclusive. `tokenFile` is recommended — point it at an [agenix](https://github.com/ryantm/agenix) secret or any file readable by the `andr-noti` service user.

When `hostname` is set the module configures an nginx reverse proxy with TLS and rate limiting on the `/ws` endpoint automatically.

### Sending notifications

From the server (or any host with network access):

```bash
curl -X POST https://notify.example.com/send \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"title": "Deploy", "text": "Production deploy finished."}'
```

The optional `andr-notify` shell wrapper (add it to `environment.systemPackages`):

```bash
andr-notify "Deploy" "Production deploy finished."
```

When calling via SSH, single-quote the whole remote command to preserve argument boundaries:

```bash
ssh yourserver 'andr-notify "Deploy" "Production deploy finished."'
```

### API

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/send` | Bearer | Send a notification. Body: `{"title":"…","text":"…"}` |
| `GET` | `/history` | Bearer | Fetch history. Params: `limit` (default 50), `offset` |
| `POST` | `/mark-seen` | Bearer | Mark as seen. Body: `{"ids":[1,2,3]}` or empty to mark all |
| `DELETE` | `/notifications` | Bearer | Delete all records |
| `GET` | `/ws?token=…` | Query param | WebSocket — receives history on connect, live notifications after |
| `GET` | `/health` | None | Returns 200 |

## Android App

See [`app/`](app/) for the Flutter source and [`app/README.md`](app/README.md) for setup instructions.

Build a release APK from the repo root:

```bash
nix run .#buildApk
```

The APK will be at `app/build/app/outputs/flutter-apk/app-release.apk`.
