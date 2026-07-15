{
  description = "slqs — native QML/Quickshell Slack client (Go daemon + vendored UI)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      daemon = pkgs.buildGoModule {
        pname = "slqs";
        version = "0.1.0";
        src = ./.;
        vendorHash = "sha256-cZCfXEtwhyz0XDC74AJ0CnPZ1Y/QURomgPqbipxHuVk=";
        subPackages = [ "." ];
        # Bake the build's commit so the running daemon can detect newer builds.
        # Empty on a dirty/dev tree (self.rev absent) → update check stays off.
        ldflags = [ "-X main.gitRev=${self.rev or ""}" ];
        postInstall = ''
          mkdir -p $out/share/slqs
          cp -r ui $out/share/slqs/ui
          install -Dm755 media-viewer.sh $out/share/slqs/media-viewer.sh
        '';
        meta.mainProgram = "slqs";
      };

      client = pkgs.writeShellApplication {
        name = "slqs-client";
        runtimeInputs = [ daemon pkgs.quickshell pkgs.procps pkgs.coreutils pkgs.mpv pkgs.imv pkgs.ffmpeg-headless pkgs.jq pkgs.curl pkgs.xdg-utils pkgs.util-linux ];
        text = ''
          export QML2_IMPORT_PATH="$HOME/.local/share/qml:${daemon}/share/slqs/ui/vendor''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
          export SLK_MEDIA_VIEWER="${daemon}/share/slqs/media-viewer.sh"
          sock="$XDG_RUNTIME_DIR/slqs.sock"

          # a UI is already up (window stays mapped in this app — jump-or-exec
          # handles focus): a second one is never wanted
          # serialize the daemon aliveness check + spawn: concurrent launches
          # used to each see "no daemon" and spawn duplicates
          exec 9>"$XDG_RUNTIME_DIR/slqs-launch.lock"
          flock 9
          alive=""
          for pid in $(pgrep -x slqs 2>/dev/null); do
            # a zombie (unreaped child) matches pgrep but serves nothing
            case "$(ps -o stat= -p "$pid" 2>/dev/null)" in Z*|"") ;; *) alive=1 ;; esac
          done
          if [ -z "$alive" ]; then
            # The daemon binds its socket only after loading all workspaces, so
            # wait for it before starting the UI — avoids the cold-start empty
            # render (UI racing a not-yet-ready daemon). Clear any stale socket
            # first so the wait lands on the fresh daemon.
            rm -f "$sock"
            setsid nohup ${daemon}/bin/slqs >/tmp/slqs.log 2>&1 </dev/null 9>&- &
          fi
          for _ in $(seq 1 300); do [ -S "$sock" ] && break; sleep 0.1; done

          # single-instance UI — checked AFTER the daemon health pass, so the
          # launcher can revive a dead daemon while a window is still up
          if pgrep -f "quickshell.* -p .*share/slqs/ui" >/dev/null 2>&1; then
            exit 0
          fi
          # close the launch lock for qs — an inherited fd 9 holds the lock
          # for the UI's whole lifetime and deadlocks future launches
          exec qs -p "${daemon}/share/slqs/ui" 9>&-
        '';
      };
    in {
      packages.${system} = {
        slqs = daemon;
        slqs-client = client;
        default = client;
      };
      apps.${system}.default = {
        type = "app";
        program = "${client}/bin/slqs-client";
      };
    };
}
