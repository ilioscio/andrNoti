{
  description = "Aisthetron — self-hosted wearable + infrastructure telemetry server and Android app";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # ── Per-system outputs (packages, apps, devShells) ─────────────────────
      perSystem = flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree              = true;
              android_sdk.accept_license = true;
            };
          };

          # ── Go server ──────────────────────────────────────────────────────
          serverPkg = pkgs.buildGoModule {
            pname   = "aisthetron";
            version = "0.7.0";
            src     = ./server;

            vendorHash = "sha256-M16ieYmUqzWJm5ZWFu4ISVD4553EHh31wT8oH1sJZX4=";
            # The Go module path's last element is `aisthetron`, so the built
            # binary is already named `aisthetron` — no postInstall rename.
          };

          # ── Host agent ─────────────────────────────────────────────────────
          # The fleet command-queue worker. Pure stdlib (no deps → vendorHash
          # null). Read-only by construction; see agent/main.go.
          agentPkg = pkgs.buildGoModule {
            pname      = "aisthetron-agent";
            version    = "0.7.0";
            src        = ./agent;
            vendorHash = null;
          };

          # ── Android SDK ────────────────────────────────────────────────────
          androidComposition = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion  = "13.0";
            platformToolsVersion = "36.0.2";
            buildToolsVersions   = [ "35.0.0" ];
            platformVersions     = [ "35" "36" ];
            includeEmulator      = false;
            includeNDK           = true;
            ndkVersions          = [ "28.2.13676358" ];
            cmakeVersions        = [ "3.22.1" ];
            includeSources       = false;
            includeSystemImages  = false;
            useGoogleAPIs        = false;
            useGoogleTVAddOns    = false;
          };

          androidSdk = androidComposition.androidsdk;

          # Writable SDK mirror (Nix store is read-only; Flutter/AGP need writable paths)
          sdkSetup = ''
            _nix_sdk="${androidSdk}/libexec/android-sdk"
            _local_sdk="$HOME/.local/share/android-sdk"
            mkdir -p "$_local_sdk"

            for _vdir in platforms build-tools ndk system-images add-ons cmake; do
              if [ -d "$_nix_sdk/$_vdir" ]; then
                mkdir -p "$_local_sdk/$_vdir"
                for _item in "$_nix_sdk/$_vdir"/*; do
                  [ -e "$_item" ] || continue
                  _name="$(basename "$_item")"
                  [ -e "$_local_sdk/$_vdir/$_name" ] || \
                    ln -sfn "$_item" "$_local_sdk/$_vdir/$_name"
                done
              fi
            done

            if [ -e "$_local_sdk/ndk-bundle" ]; then
              mkdir -p "$_local_sdk/ndk"
              _ndk_ver="$(grep "^Pkg.Revision" \
                "$_local_sdk/ndk-bundle/source.properties" 2>/dev/null \
                | cut -d= -f2 | tr -d ' ')"
              if [ -n "$_ndk_ver" ] && [ ! -e "$_local_sdk/ndk/$_ndk_ver" ]; then
                ln -sfn "$_local_sdk/ndk-bundle" "$_local_sdk/ndk/$_ndk_ver"
              fi
              unset _ndk_ver
            fi

            for _item in "$_nix_sdk"/*; do
              _name="$(basename "$_item")"
              case "$_name" in
                platforms|build-tools|ndk|system-images|add-ons|cmake|licenses) continue ;;
              esac
              [ -e "$_local_sdk/$_name" ] || ln -sfn "$_item" "$_local_sdk/$_name"
            done

            if [ -L "$_local_sdk/licenses" ] || [ ! -d "$_local_sdk/licenses" ]; then
              rm -f "$_local_sdk/licenses"
              mkdir -p "$_local_sdk/licenses"
              cp "$_nix_sdk/licenses/"* "$_local_sdk/licenses/" 2>/dev/null || true
            fi

            export ANDROID_SDK_ROOT="$_local_sdk"
            export ANDROID_HOME="$_local_sdk"
            unset _nix_sdk _local_sdk _vdir _item _name

            flutter config \
              --android-sdk "$ANDROID_SDK_ROOT" \
              --no-analytics \
              2>/dev/null || true
          '';

          buildApk = pkgs.writeShellApplication {
            name = "build-apk";
            runtimeInputs = [ pkgs.flutter pkgs.jdk17 androidSdk ];
            text = ''
              export JAVA_HOME="${pkgs.jdk17}"
              ${sdkSetup}
              # Accept running from the repo root or from app/
              if [ ! -f "pubspec.yaml" ] && [ -f "app/pubspec.yaml" ]; then
                cd app
              fi
              if [ ! -f "pubspec.yaml" ]; then
                echo "Error: run from the aisthetron repo root or the app/ subdirectory" >&2
                exit 1
              fi
              echo "Building release APK..."
              flutter build apk --release
              echo ""
              echo "APK ready: $(pwd)/build/app/outputs/flutter-apk/app-release.apk"
            '';
          };

        in {
          packages.default = serverPkg;
          packages.agent = agentPkg;

          apps.buildApk = {
            type    = "app";
            program = "${buildApk}/bin/build-apk";
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.flutter
              pkgs.dart
              pkgs.jdk17
              androidSdk
              pkgs.clang
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
              pkgs.gtk3
              pkgs.libepoxy
              pkgs.xorg.libX11
            ];

            JAVA_HOME = "${pkgs.jdk17}";

            shellHook = ''
              export JAVA_HOME="${pkgs.jdk17}"
              ${sdkSetup}

              echo ""
              echo "Aisthetron Flutter dev environment ready."
              flutter --version 2>/dev/null | head -1
              echo ""
              echo "  cd app && flutter run              # connected Android device (USB)"
              echo "  cd app && flutter devices          # list available targets"
              echo "  nix run .#buildApk                 # build release APK"
              echo ""
            '';
          };
        }
      );

    in
      perSystem // {
        # ── NixOS module (system-independent) ─────────────────────────────────
        nixosModules.default = { config, pkgs, lib, ... }:
          let
            cfg      = config.services.aisthetron;
            cfgAgent = config.services.aisthetron-agent;
          in {
            options.services.aisthetron-agent = {
              enable = lib.mkEnableOption "Aisthetron host agent — serves read-only journal/status queries from the relay command queue";

              relayUrl = lib.mkOption {
                type        = lib.types.str;
                example     = "https://notify.example.com";
                description = "HTTP/HTTPS base URL of the relay (no trailing slash).";
              };

              host = lib.mkOption {
                type        = lib.types.str;
                example     = "octopus";
                description = "This host's source name. MUST match its heartbeat source so the app addresses commands correctly.";
              };

              tokenFile = lib.mkOption {
                type        = lib.types.path;
                description = ''
                  Path to the relay bearer (broadcast) token file. This is the same
                  host token used for heartbeats — the agent authenticates to the
                  relay's host-facing poll/result endpoints with it. The file must be
                  readable by the aisthetron-agent user.
                '';
              };

              units = lib.mkOption {
                type        = lib.types.listOf lib.types.str;
                default     = [];
                example     = [ "nginx.service" "aisthetron.service" ];
                description = ''
                  The allowlist of systemd units this agent will serve journal/status
                  for. This is the FINAL authority: any command naming a unit outside
                  this list is refused locally, regardless of what the relay forwards.
                  Mirror services.aisthetron.heartbeat.units here.
                '';
              };

              package = lib.mkOption {
                type        = lib.types.package;
                default     = self.packages.${pkgs.system}.agent;
                defaultText = lib.literalExpression "aisthetron.packages.\${system}.agent";
                description = "The aisthetron-agent package to use.";
              };
            };

            options.services.aisthetron = {
              enable = lib.mkEnableOption "Aisthetron relay server (notifications + telemetry)";

              port = lib.mkOption {
                type        = lib.types.port;
                default     = 8086;
                description = "TCP port the server listens on (loopback only).";
              };

              hostname = lib.mkOption {
                type        = lib.types.nullOr lib.types.str;
                default     = null;
                example     = "notify.example.com";
                description = "nginx virtual host to configure. null disables nginx setup.";
              };

              tokenFile = lib.mkOption {
                type        = lib.types.nullOr lib.types.path;
                default     = null;
                description = "Path to a file containing the auth token (e.g. from agenix).";
              };

              token = lib.mkOption {
                type        = lib.types.nullOr lib.types.str;
                default     = null;
                description = ''
                  Auth token as a plain string. Less secure than tokenFile because the
                  value is stored in the Nix store. Prefer tokenFile for production.
                '';
              };

              controlTokenFile = lib.mkOption {
                type        = lib.types.nullOr lib.types.path;
                default     = null;
                description = ''
                  Path to a file containing the elevated CONTROL-scope token (e.g. from
                  agenix). This token — distinct from the broadcast token above — gates
                  the /fleet/command surface (log retrieval, and later service control).
                  When unset, /fleet/command is disabled entirely (returns 503). Must
                  differ from the broadcast token.
                '';
              };

              heartbeatMissed = lib.mkOption {
                type        = lib.types.ints.positive;
                default     = 3;
                description = "Number of missed beats before alerting on a remote source.";
              };

              dataDir = lib.mkOption {
                type        = lib.types.path;
                default     = "/var/lib/aisthetron";
                description = ''
                  Directory holding the SQLite database. Override to point at a
                  pre-existing data directory when migrating (e.g. the legacy
                  /var/lib/andr-noti) so history is preserved in place.
                '';
              };

              package = lib.mkOption {
                type        = lib.types.package;
                default     = self.packages.${pkgs.system}.default;
                defaultText = lib.literalExpression "aisthetron.packages.\${system}.default";
                description = "The aisthetron server package to use.";
              };

              # ── Heartbeat sender (for remote servers) ─────────────────────
              heartbeat = {
                enable = lib.mkEnableOption "Aisthetron heartbeat sender — registers this machine with a relay server";

                source = lib.mkOption {
                  type        = lib.types.str;
                  example     = "work-server";
                  description = "Name identifying this machine in heartbeat and alert messages.";
                };

                relayUrl = lib.mkOption {
                  type        = lib.types.str;
                  example     = "https://notify.example.com";
                  description = "HTTP/HTTPS base URL of the Aisthetron relay server (no trailing slash).";
                };

                interval = lib.mkOption {
                  type        = lib.types.ints.positive;
                  default     = 60;
                  description = "Heartbeat interval in seconds. The timer fires at this cadence.";
                };

                monitor = lib.mkOption {
                  type        = lib.types.bool;
                  default     = true;
                  description = ''
                    Whether the relay should alert when this source misses heartbeats.
                    Set false for intermittent devices (e.g. laptops) so they show
                    live/stale status without firing unreachable/recovered alerts.
                  '';
                };

                units = lib.mkOption {
                  type        = lib.types.listOf lib.types.str;
                  default     = [];
                  example     = [ "nginx.service" "aisthetron.service" ];
                  description = ''
                    Declared allowlist of systemd units to report on each heartbeat.
                    Each unit's ActiveState/SubState is pushed to the relay, which shows
                    them in the machines view and raises a push notification on the
                    ok→failed transition. This SAME list should be mirrored in
                    services.aisthetron-agent.units to allow log retrieval for them.
                  '';
                };

                tokenFile = lib.mkOption {
                  type        = lib.types.nullOr lib.types.path;
                  default     = null;
                  description = "Path to file containing the relay auth token (e.g. from agenix).";
                };

                token = lib.mkOption {
                  type        = lib.types.nullOr lib.types.str;
                  default     = null;
                  description = "Relay auth token as plain string. Prefer tokenFile for production.";
                };
              };
            };

            config = lib.mkMerge [

              # ── Relay server ───────────────────────────────────────────────
              (lib.mkIf cfg.enable {
                assertions = [
                  {
                    assertion = cfg.tokenFile != null || cfg.token != null;
                    message   = "services.aisthetron: set either tokenFile or token.";
                  }
                  {
                    assertion = !(cfg.tokenFile != null && cfg.token != null);
                    message   = "services.aisthetron: set only one of tokenFile or token, not both.";
                  }
                ];

                users.users.aisthetron = {
                  isSystemUser = true;
                  group        = "aisthetron";
                  description  = "Aisthetron relay server";
                };
                users.groups.aisthetron = {};

                # Ensure the data directory exists and is owned by the service
                # user. The recursive `Z` rule fixes ownership of a pre-existing
                # directory (e.g. the legacy /var/lib/andr-noti) after the rename.
                systemd.tmpfiles.rules = [
                  "d '${cfg.dataDir}' 0750 aisthetron aisthetron - -"
                  "Z '${cfg.dataDir}' 0750 aisthetron aisthetron - -"
                ];

                systemd.services.aisthetron = {
                  description = "Aisthetron relay server";
                  after       = [ "network.target" ];
                  wantedBy    = [ "multi-user.target" ];

                  serviceConfig = {
                    Type           = "simple";
                    User           = "aisthetron";
                    Group          = "aisthetron";
                    ExecStart      = lib.concatStringsSep " " (
                      [
                        "${cfg.package}/bin/aisthetron"
                        "--port ${toString cfg.port}"
                        "--db ${cfg.dataDir}/notifications.db"
                        "--heartbeat-missed ${toString cfg.heartbeatMissed}"
                      ] ++ (
                        if cfg.tokenFile != null
                        then [ "--token-file ${cfg.tokenFile}" ]
                        else [ "--token ${cfg.token}" ]
                      ) ++ lib.optional (cfg.controlTokenFile != null)
                        "--control-token-file ${cfg.controlTokenFile}"
                    );
                    Restart    = "always";
                    RestartSec = 5;

                    # Hardening
                    NoNewPrivileges = true;
                    ProtectSystem   = "strict";
                    ProtectHome     = true;
                    PrivateTmp      = true;
                    ReadWritePaths  = [ cfg.dataDir ];
                  };
                };

                services.nginx.commonHttpConfig = lib.mkIf (cfg.hostname != null) ''
                  limit_req_zone $binary_remote_addr zone=aisthetron_ws:1m rate=5r/s;
                '';

                services.nginx.virtualHosts = lib.mkIf (cfg.hostname != null) {
                  ${cfg.hostname} = {
                    enableACME = true;
                    forceSSL   = true;

                    locations."/" = {
                      proxyPass   = "http://127.0.0.1:${toString cfg.port}";
                      extraConfig = ''
                        proxy_set_header X-Forwarded-For   $remote_addr;
                        proxy_set_header X-Forwarded-Proto $scheme;
                      '';
                    };

                    locations."/ws" = {
                      proxyPass   = "http://127.0.0.1:${toString cfg.port}";
                      extraConfig = ''
                        limit_req zone=aisthetron_ws burst=10 nodelay;
                        proxy_http_version 1.1;
                        proxy_set_header Upgrade    $http_upgrade;
                        proxy_set_header Connection "upgrade";
                        proxy_read_timeout  3600s;
                        proxy_send_timeout  3600s;
                      '';
                    };
                  };
                };
              })

              # ── Heartbeat sender ───────────────────────────────────────────
              (lib.mkIf cfg.heartbeat.enable {
                assertions = [
                  {
                    assertion = cfg.heartbeat.tokenFile != null || cfg.heartbeat.token != null;
                    message   = "services.aisthetron.heartbeat: set either tokenFile or token.";
                  }
                  {
                    assertion = !(cfg.heartbeat.tokenFile != null && cfg.heartbeat.token != null);
                    message   = "services.aisthetron.heartbeat: set only one of tokenFile or token, not both.";
                  }
                ];

                systemd.services.aisthetron-heartbeat = {
                  description     = "Aisthetron heartbeat ping to relay";
                  after           = [ "network-online.target" ];
                  wants           = [ "network-online.target" ];
                  serviceConfig = {
                    Type            = "oneshot";
                    NoNewPrivileges = true;
                    ProtectSystem   = "strict";
                    ProtectHome     = true;
                    ExecStart       =
                      let
                        tokenExpr =
                          if cfg.heartbeat.tokenFile != null
                          then ''$(cat ${cfg.heartbeat.tokenFile})''
                          else cfg.heartbeat.token;
                        systemctl = "${config.systemd.package}/bin/systemctl";
                        jq        = "${pkgs.jq}/bin/jq";
                        # Bash array literal of the declared units (safely quoted).
                        unitsArr  = lib.concatMapStringsSep " " (u: lib.escapeShellArg u) cfg.heartbeat.units;
                      in
                        pkgs.writeShellScript "aisthetron-heartbeat" ''
                          set -u
                          units_json='[]'
                          for u in ${unitsArr}; do
                            as="$(${systemctl} show -p ActiveState --value "$u" 2>/dev/null || true)"
                            ss="$(${systemctl} show -p SubState   --value "$u" 2>/dev/null || true)"
                            units_json="$(${jq} -c --arg n "$u" --arg a "$as" --arg s "$ss" \
                              '. + [{name:$n,active:$a,sub:$s}]' <<<"$units_json")"
                          done
                          payload="$(${jq} -cn \
                            --arg src "${cfg.heartbeat.source}" \
                            --argjson interval ${toString cfg.heartbeat.interval} \
                            --argjson monitor ${lib.boolToString cfg.heartbeat.monitor} \
                            --argjson units "$units_json" \
                            '{source:$src,interval:$interval,monitor:$monitor}
                             + (if ($units|length)>0 then {units:$units} else {} end)')"
                          ${pkgs.curl}/bin/curl -sf \
                            -X POST "${cfg.heartbeat.relayUrl}/heartbeat" \
                            -H "Authorization: Bearer ${tokenExpr}" \
                            -H "Content-Type: application/json" \
                            -d "$payload" \
                            || true
                        '';
                  };
                };

                systemd.timers.aisthetron-heartbeat = {
                  description = "Aisthetron heartbeat timer";
                  wantedBy    = [ "timers.target" ];
                  timerConfig = {
                    OnBootSec         = "30s";
                    OnUnitActiveSec   = "${toString cfg.heartbeat.interval}s";
                    AccuracySec       = "10s";
                    Persistent        = true;
                  };
                };
              })

              # ── Host agent (fleet command queue worker) ────────────────────
              (lib.mkIf cfgAgent.enable {
                users.users.aisthetron-agent = {
                  isSystemUser = true;
                  group        = "aisthetron-agent";
                  description  = "Aisthetron host agent (read-only journal/status)";
                  # Read the system journal without any privilege escalation.
                  extraGroups  = [ "systemd-journal" ];
                };
                users.groups.aisthetron-agent = {};

                systemd.services.aisthetron-agent = {
                  description = "Aisthetron host agent — read-only fleet queries";
                  after       = [ "network-online.target" ];
                  wants       = [ "network-online.target" ];
                  wantedBy    = [ "multi-user.target" ];

                  serviceConfig = {
                    Type      = "simple";
                    User      = "aisthetron-agent";
                    Group     = "aisthetron-agent";
                    ExecStart = lib.concatStringsSep " " [
                      "${cfgAgent.package}/bin/aisthetron-agent"
                      "--relay ${cfgAgent.relayUrl}"
                      "--host ${cfgAgent.host}"
                      "--token-file ${cfgAgent.tokenFile}"
                      "--units ${lib.escapeShellArg (lib.concatStringsSep "," cfgAgent.units)}"
                      "--journalctl ${config.systemd.package}/bin/journalctl"
                      "--systemctl ${config.systemd.package}/bin/systemctl"
                    ];
                    Restart    = "always";
                    RestartSec = 5;

                    # Hardening. The agent only reads: no capabilities, no new privs,
                    # read-only filesystem, restricted syscalls. AF_UNIX is required so
                    # journalctl/systemctl can reach the journald/systemd sockets.
                    NoNewPrivileges         = true;
                    ProtectSystem           = "strict";
                    ProtectHome             = true;
                    PrivateTmp              = true;
                    PrivateDevices          = true;
                    ProtectKernelTunables   = true;
                    ProtectKernelModules    = true;
                    ProtectControlGroups    = true;
                    ProtectClock            = true;
                    ProtectHostname         = true;
                    RestrictNamespaces      = true;
                    RestrictRealtime        = true;
                    LockPersonality         = true;
                    MemoryDenyWriteExecute  = true;
                    CapabilityBoundingSet   = "";
                    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
                    SystemCallFilter        = [ "@system-service" ];
                    SystemCallErrorNumber   = "EPERM";
                  };
                };
              })

            ];
          };

        # ── Overlay ────────────────────────────────────────────────────────────
        overlays.default = final: _prev: {
          aisthetron = self.packages.${final.system}.default;
        };
      };
}
