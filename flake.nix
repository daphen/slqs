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
        vendorHash = "sha256-gJpFPtWUWzDbmG6OgkRSfhKmhCgCNBklf7ZwgOCUAQs=";
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
        runtimeInputs = [ daemon pkgs.quickshell pkgs.procps pkgs.coreutils pkgs.mpv pkgs.imv pkgs.ffmpeg-headless pkgs.jq pkgs.curl pkgs.xdg-utils ];
        text = ''
          export SLK_MEDIA_VIEWER="${daemon}/share/slqs/media-viewer.sh"
          sock="$XDG_RUNTIME_DIR/slqs.sock"
          if ! pgrep -x slqs >/dev/null 2>&1; then
            # The daemon binds its socket only after loading all workspaces, so
            # wait for it before starting the UI — avoids the cold-start empty
            # render (UI racing a not-yet-ready daemon). Clear any stale socket
            # first so the wait lands on the fresh daemon.
            rm -f "$sock"
            setsid nohup ${daemon}/bin/slqs >/tmp/slqs.log 2>&1 </dev/null &
          fi
          for _ in $(seq 1 150); do [ -S "$sock" ] && break; sleep 0.1; done
          exec qs -p "${daemon}/share/slqs/ui"
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
