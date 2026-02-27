{
  description = "andrNoti — self-hosted push notification server and Android app";

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
            pname   = "andr-noti";
            version = "0.1.0";
            src     = ./server;

            vendorHash = "sha256-M16ieYmUqzWJm5ZWFu4ISVD4553EHh31wT8oH1sJZX4=";

            postInstall = ''
              mv $out/bin/andrnoti $out/bin/andr-noti
            '';
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
                echo "Error: run from the andrNoti repo root or the app/ subdirectory" >&2
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
              echo "andrNoti Flutter dev environment ready."
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
            cfg = config.services.andrNoti;
          in {
            options.services.andrNoti = {
              enable = lib.mkEnableOption "andrNoti push notification server";

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

              package = lib.mkOption {
                type        = lib.types.package;
                default     = self.packages.${pkgs.system}.default;
                defaultText = lib.literalExpression "andrNoti.packages.\${system}.default";
                description = "The andr-noti server package to use.";
              };
            };

            config = lib.mkIf cfg.enable {
              assertions = [
                {
                  assertion = cfg.tokenFile != null || cfg.token != null;
                  message   = "services.andrNoti: set either tokenFile or token.";
                }
                {
                  assertion = !(cfg.tokenFile != null && cfg.token != null);
                  message   = "services.andrNoti: set only one of tokenFile or token, not both.";
                }
              ];

              users.users.andr-noti = {
                isSystemUser = true;
                group        = "andr-noti";
                description  = "andrNoti notification server";
              };
              users.groups.andr-noti = {};

              systemd.services.andr-noti = {
                description = "andrNoti push notification server";
                after       = [ "network.target" ];
                wantedBy    = [ "multi-user.target" ];

                serviceConfig = {
                  Type           = "simple";
                  User           = "andr-noti";
                  Group          = "andr-noti";
                  StateDirectory = "andr-noti";
                  ExecStart      = lib.concatStringsSep " " (
                    [
                      "${cfg.package}/bin/andr-noti"
                      "--port ${toString cfg.port}"
                      "--db /var/lib/andr-noti/notifications.db"
                    ] ++ (
                      if cfg.tokenFile != null
                      then [ "--token-file ${cfg.tokenFile}" ]
                      else [ "--token ${cfg.token}" ]
                    )
                  );
                  Restart    = "always";
                  RestartSec = 5;

                  # Hardening
                  NoNewPrivileges = true;
                  ProtectSystem   = "strict";
                  ProtectHome     = true;
                  PrivateTmp      = true;
                  ReadWritePaths  = [ "/var/lib/andr-noti" ];
                };
              };

              services.nginx.commonHttpConfig = lib.mkIf (cfg.hostname != null) ''
                limit_req_zone $binary_remote_addr zone=andrnoti_ws:1m rate=5r/s;
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
                      limit_req zone=andrnoti_ws burst=10 nodelay;
                      proxy_http_version 1.1;
                      proxy_set_header Upgrade    $http_upgrade;
                      proxy_set_header Connection "upgrade";
                      proxy_read_timeout  3600s;
                      proxy_send_timeout  3600s;
                    '';
                  };
                };
              };
            };
          };

        # ── Overlay ────────────────────────────────────────────────────────────
        overlays.default = final: _prev: {
          andr-noti = self.packages.${final.system}.default;
        };
      };
}
