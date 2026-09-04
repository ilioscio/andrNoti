# Aisthetron

*An instrument of perception* — a self-hosted bridge between the user's wearables
and their own infrastructure. Aisthetron began as andrNoti, a push-notification
client for a self-hosted relay, and is expanding into a sovereign
health-telemetry and infra-perception system.

## Views

- **Notifications** — live history of notifications delivered by the relay
  (`notify.ilios.dev`), with seen/unseen tracking.
- **Machines** — the machines currently sending heartbeats (and any that have
  sent messages), with their last-known health.
- **Health** — a dashboard of the latest health statistics collected from the
  paired Galaxy Watch (via Wear Health Services → Wear Data Layer → relay),
  archived server-side as first-class historical data.

## Principles

Your data, your hardware, your rules. No third-party push clouds, no vendor
health silos — the watch collects, the phone relays, your server remembers.

## Toolchain

Flutter with an isolated Nix toolchain. See `flake.nix`.

```sh
nix develop            # enter the dev shell
flutter run            # run on a connected device
nix run .#buildApk     # produce a release APK
```
