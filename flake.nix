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
        postInstall = ''
          mkdir -p $out/share/slqs
          cp -r ui $out/share/slqs/ui
          install -Dm755 media-viewer.sh $out/share/slqs/media-viewer.sh
        '';
        meta.mainProgram = "slqs";
      };

      client = pkgs.writeShellApplication {
        name = "slqs-client";
        runtimeInputs = [ daemon pkgs.quickshell pkgs.procps pkgs.coreutils pkgs.mpv pkgs.imv pkgs.jq pkgs.curl pkgs.xdg-utils ];
        text = ''
          export SLK_MEDIA_VIEWER="${daemon}/share/slqs/media-viewer.sh"
          pgrep -x slqs >/dev/null 2>&1 || \
            setsid nohup ${daemon}/bin/slqs >/tmp/slqs.log 2>&1 </dev/null &
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
