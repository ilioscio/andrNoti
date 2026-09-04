# Fleet Service Monitoring & Remote Logs

This extends the machines view from a live/down status board into a control view:
each host reports the state of a declared set of **systemd units**, a failed unit
raises a push notification, and you can pull a unit's **journal or `systemctl
status`** on demand from the phone — behind a biometric gate.

It is **read-only by design.** The only remote actions are `journal` and
`unit-status`. There is deliberately no start/stop/restart path yet (see
[Future: service control](#future-service-control)).

> Module names are `services.aisthetron` (relay + heartbeat sender) and
> `services.aisthetron-agent` (the read-only host worker). The rest of this repo's
> older README still uses the pre-rebrand `services.andrNoti` names in places;
> the options below are the current ones.

---

## How it works

Two independent data paths, one per need:

```
STATUS  (always-on, push)                 LOGS  (on-demand, pull)
───────────────────────────               ─────────────────────────────────
host heartbeat timer                       phone ──POST /fleet/command──▶ relay
  every 60s, includes                        (CONTROL token)               │
  units:[{name,active,sub}] ──▶ relay                                      │ queue
                              │            relay ◀──GET /fleet/poll──── aisthetron-agent
  relay upserts unit_status  │              (long-poll, HOST token)     on the host
  fires push on ok→failed    │                                             │ runs journalctl
                             ▼            relay ◀──POST /fleet/result───────┘ (allowlist-checked)
                    GET /machines                       │
                    (units[] per host)      phone ◀──GET /fleet/command?id──┘  renders log
```

- **Status** rides the existing heartbeat — no new inbound ports anywhere.
- **Logs** go through a relay-mediated command queue: the phone drops a request,
  the host long-polls and answers. This works even for hosts behind NAT, and it
  is the substrate future control actions will reuse.

### Security model (the important part)

- **Two token tiers.** The *broadcast* token (`andr-noti-token`, on every host,
  used for heartbeats and reads) is **never** enough to read a log. A separate
  *control* token (`aisthetron-control-token`) gates `/fleet/command`. If no
  control token is configured on the relay, `/fleet/command` returns `503` — the
  feature is off by default.
- **The relay is a mailbox, not an executor.** It never runs anything on a host
  and never holds host privileges. It only queues requests and stores results.
- **The host is the final authority.** `aisthetron-agent` re-validates every
  command against its **own local unit allowlist** and a **closed action enum**
  before running anything, using an explicit `exec` argv (never a shell). A
  compromised relay cannot make a host run something the host didn't opt into.
- **The agent is unprivileged.** It runs as the `aisthetron-agent` user in the
  `systemd-journal` group (enough to read journals), heavily sandboxed
  (`CapabilityBoundingSet=""`, `SystemCallFilter=@system-service`,
  `ProtectSystem=strict`). Reading journals/status needs no root.
- **The biometric gate is a convenience barrier, not the boundary.** In the app,
  `local_auth` (fingerprint / PIN) unlocks the control token stored in the
  Android Keystore. The real boundary is the server's control scope; the gate
  just stops someone holding your unlocked phone from reaching your servers.
- **Everything is audited.** Every command is a permanent row in the `commands`
  table: what, which host, which requester, when claimed, when answered, result.

---

## Adding a monitored service to an existing host

This is the routine task: a new service is deployed to a host and you want it
watched. It's two edits **in the same file** and a rebuild.

### 1 — Find the real unit name

On the host, unit names are not always what you'd guess (e.g. Samba is
`samba-smbd.service`, not `smbd.service`):

```bash
# On the host:
systemctl list-units --type=service --state=running   # what's actually running
systemctl status <guess>                               # confirm a specific name
```

### 2 — Add it to BOTH lists

In that host's aisthetron config (e.g. `octopus/aisthetron.nix`), add the unit to
**`services.aisthetron.heartbeat.units`** (so it's reported + alerts) **and**
**`services.aisthetron-agent.units`** (so its logs are retrievable). They must
mirror each other:

```nix
services.aisthetron.heartbeat.units = [
  "jellyfin.service"
  "samba-smbd.service"
  "transmission.service"
  "sshd.service"
  "sonarr.service"        # ← new
];

services.aisthetron-agent.units = [
  "jellyfin.service"
  "samba-smbd.service"
  "transmission.service"
  "sshd.service"
  "sonarr.service"        # ← new (same list)
];
```

> **Why both?** `heartbeat.units` is what gets *reported* to the relay (status +
> alerts). `agent.units` is the host's **own allowlist** — the final authority on
> what logs it will serve. A unit in the heartbeat list but not the agent list
> shows status but returns *"unit … is not in this host's allowlist"* when you tap
> it. A unit in the agent list but not the heartbeat list is log-retrievable but
> never shown or alerted. Keep them identical unless you deliberately want one of
> those asymmetries.

To avoid drift you can define the list once with `let` and reference it twice:

```nix
let
  monitoredUnits = [
    "jellyfin.service" "samba-smbd.service"
    "transmission.service" "sshd.service" "sonarr.service"
  ];
in {
  services.aisthetron.heartbeat.units = monitoredUnits;
  services.aisthetron-agent.units     = monitoredUnits;
}
```

### 3 — Rebuild the host

```bash
cd ~/Projects/<host-repo>
nixos-rebuild switch --flake .#<host>     # or `nix run .#` for remote hosts
```

The new unit appears on the next heartbeat (≤60s). No relay change is needed —
the relay stores whatever a host reports.

### 4 — Verify

In the app: open the host → the **SERVICES** panel lists the new unit with a
status LED; tap it (fingerprint) to pull its log. Or from a shell:

```bash
BRD=$(ssh root@<relay> cat /run/agenix/andr-noti-token)
curl -s https://notify.example.com/machines -H "Authorization: Bearer $BRD" | jq '.[]|{source,units}'
```

---

## Adding a brand-new host

A host needs three things beyond the heartbeat it already has: the units lists, a
running agent, and a token the (unprivileged) agent can read.

```nix
{ config, ... }:
let
  monitoredUnits = [ "nginx.service" "postgresql.service" "sshd.service" ];
in {
  # Broadcast token (already present for the heartbeat), owned however you need.
  age.secrets.andr-noti-token = {
    file = ./secrets/andr-noti-token.age;
    owner = "root"; group = "users"; mode = "0440";
  };

  # A SECOND decrypt of the SAME token, readable by the unprivileged agent user.
  # (agenix can decrypt one .age file to multiple paths with different owners.)
  age.secrets.aisthetron-agent-token = {
    file = ./secrets/andr-noti-token.age;
    owner = "aisthetron-agent"; group = "aisthetron-agent"; mode = "0400";
  };

  services.aisthetron.heartbeat = {
    enable    = true;
    source    = "newhost";                       # MUST match agent.host below
    relayUrl  = "https://notify.example.com";
    tokenFile = config.age.secrets.andr-noti-token.path;
    units     = monitoredUnits;
    # monitor = false;   # for laptops/intermittent hosts: status only, no push
  };

  services.aisthetron-agent = {
    enable    = true;
    relayUrl  = "https://notify.example.com";     # loopback on the relay host itself
    host      = "newhost";                        # MUST match heartbeat.source
    tokenFile = config.age.secrets.aisthetron-agent-token.path;
    units     = monitoredUnits;
  };
}
```

Notes:
- **`host` must equal `heartbeat.source`** — the app addresses commands by that
  name.
- No `secrets.nix` change is needed for `aisthetron-agent-token`: it reuses the
  existing `andr-noti-token.age` file, which is already keyed there.
- `monitor = false` (e.g. a laptop) still tracks unit status and shows it, but
  suppresses both missed-heartbeat and failed-unit **pushes** for that host.

---

## Control token & the app

The control token is the elevated credential for `/fleet/command`. Generate it
once, encrypt it for the relay, and paste the **plaintext** into the app.

### 1 — Generate on the relay repo (e.g. `ilios.dev`)

Run in the agenix devshell. This snippet is paste-safe — `printf` writes **only**
the token to the temp file, and `echo` is separated at the end:

```bash
TOKEN=$(openssl rand -hex 32); printf '%s' "$TOKEN" > /tmp/ctl; \
  EDITOR="cp /tmp/ctl" agenix -e secrets/aisthetron-control-token.age; \
  rm -f /tmp/ctl; echo "CONTROL TOKEN → $TOKEN"
```

> ⚠️ Do **not** build the temp file with `echo "...$TOKEN" printf ...` on one
> line — `echo` will swallow the rest as arguments and encrypt the whole string.
> The secret must be exactly the 64-char hex, nothing else.

Add the rules entry (`secrets/secrets.nix`) and the secret declaration:

```nix
# secrets.nix
"secrets/aisthetron-control-token.age".publicKeys = allKeys;

# host config
age.secrets.aisthetron-control-token = {
  file = ./secrets/aisthetron-control-token.age;
  owner = "aisthetron"; group = "aisthetron"; mode = "0440";
};
services.aisthetron.controlTokenFile = config.age.secrets.aisthetron-control-token.path;
```

### 2 — Deploy AND restart the relay

The `.age` file is only tracked/decrypted on rebuild, and the server reads the
token at **startup**, so a content-only change needs an explicit restart:

```bash
git add secrets/aisthetron-control-token.age    # flakes only see tracked files
nix run .#                                       # re-decrypts /run/agenix
ssh root@<relay> systemctl restart aisthetron    # reload the token into the server
```

Confirm the decrypted value is clean (64 hex chars, nothing else):

```bash
ssh root@<relay> cat /run/agenix/aisthetron-control-token
```

### 3 — Enter it in the app

Settings → **Control Token** → paste the plaintext (the `cat` output above, or
`agenix -d secrets/aisthetron-control-token.age`) → **Save & Reconnect**. It's
stored in the Android Keystore, not SharedPreferences. Leaving it blank simply
disables log retrieval.

Tapping a service then prompts for fingerprint/PIN; a successful unlock is cached
~5 minutes and cleared whenever the app is backgrounded.

---

## API additions

All require `Authorization: Bearer <token>`.

| Method | Path | Scope | Body / Params | Description |
|--------|------|-------|---------------|-------------|
| `POST` | `/heartbeat` | broadcast | `…,"units":[{"name","active","sub"}]` | `units` is new & optional; upserts unit status, alerts on ok→failed. |
| `GET`  | `/machines` | broadcast | — | Each heartbeat host now carries a `units` array. |
| `POST` | `/fleet/command` | **control** | `{"host","action","unit","lines"}` | Enqueue a command. `action` ∈ `journal`\|`unit-status`. Returns `{"id"}`. `503` if control scope disabled. |
| `GET`  | `/fleet/command?id=N` | **control** | — | Poll a command's status/result. |
| `GET`  | `/fleet/poll?host=X` | broadcast (host) | — | Agent long-poll (~25s) for the next command; claims it atomically. `204` on timeout. |
| `POST` | `/fleet/result` | broadcast (host) | `{"id","status","result","result_code"}` | Agent posts the outcome of a claimed command. |

Stuck commands (host offline, agent died) are failed out by a reaper after 90s,
so the app never polls forever.

### Option reference

`services.aisthetron`:
- `controlTokenFile` — path to the elevated control token. Unset ⇒ `/fleet/command` disabled.
- `heartbeat.units` — list of units to report each beat.

`services.aisthetron-agent`:
- `enable`, `relayUrl`, `host` (= heartbeat source), `tokenFile` (agent-readable broadcast token), `units` (the local allowlist / final authority), `package`.

### Server flags

| Flag | Description |
|------|-------------|
| `--control-token-file` | Path to the control token. Must differ from `--token`. Absent ⇒ control scope off. |

---

## Troubleshooting

| Symptom | Cause & fix |
|---------|-------------|
| **"Control token rejected by the relay"** (401) | The app's token ≠ the relay's decrypted token. You probably pasted the **encrypted `.age` contents** (starts with `age-encryption.org/v1`) instead of the plaintext. Paste `ssh root@<relay> cat /run/agenix/aisthetron-control-token`. Also confirm that file is exactly 64 hex chars — if it contains shell text it was generated with a flattened `echo … printf` (regenerate with the paste-safe snippet above). |
| **Token looks right but still 401** | You regenerated the secret but didn't restart the server. `ssh root@<relay> systemctl restart aisthetron`. |
| **"Control scope is not enabled on the relay"** (503) | `services.aisthetron.controlTokenFile` isn't set on the relay, or the secret is missing. |
| **A service shows grey / "unit … not in this host's allowlist"** | Wrong unit name (e.g. `smbd` vs `samba-smbd`), or it's only in one of the two lists. Confirm with `systemctl list-units --type=service` on the host and mirror both `heartbeat.units` and `agent.units`. |
| **"Timed out waiting for the host to respond"** | The agent isn't running/reachable on that host. `ssh <host> systemctl status aisthetron-agent`; check it can reach `relayUrl`. |
| **A host shows no SERVICES panel at all** | It's still running the old heartbeat script — redeploy that host so the new `heartbeat.units` reporting activates. |
| **Biometric prompt says "No device lock configured"** | Set a PIN/pattern/biometric on the phone; `local_auth` needs a device credential to check against. |

---

## Future: service control

The schema, audit log, allowlist, and closed action enum were built to accept
start/stop/restart later, but that path intentionally does **not** exist yet.
Adding it is a deliberate, reviewed change in **three** places:

1. Add the action to `fleetActions` in `server/main.go`.
2. Add it to `allowedActions` **and** an `exec` branch in `agent/main.go`.
3. Grant the `aisthetron-agent` user a **narrow polkit rule** for exactly the
   allowlisted units (reading needs no privilege; `systemctl start/stop` does).

Keeping the agent read-only until then means a bug or a compromised relay can, at
worst, read logs you already authorised — never change a machine's state.
