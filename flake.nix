{
  description = "Nabu - Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zls-overlay = {
      url = "github:zigtools/zls";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, zls-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        # Use master/nightly build - update flake.lock to get newer versions
        zig = pkgs.zigpkgs.master;
        zls = zls-overlay.packages.${system}.zls;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            zls
            # SDL2 system dependencies
            pkgs.xorg.libX11
            pkgs.xorg.libXext
            pkgs.xorg.libXrandr
            pkgs.xorg.libXcursor
            pkgs.xorg.libXfixes
            pkgs.xorg.libXi
            pkgs.xorg.libXScrnSaver
            pkgs.SDL2
            pkgs.libGL
            pkgs.libpulseaudio
            pkgs.libxkbcommon
            pkgs.wayland
            pkgs.pkg-config
          ];

          shellHook = ''
            echo "Zig $(zig version) development environment"
          '';
        };
      }
    );
}
