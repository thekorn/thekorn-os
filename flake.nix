{
  description = "thekorn-os";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zls.url = "github:zigtools/zls/master";
  };

  outputs = {
    nixpkgs,
    zig-overlay,
    zls,
    ...
  }: let
    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    devShells = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [zig-overlay.overlays.default];
      };
    in {
      default = pkgs.mkShell {
        packages = [
          pkgs.codebook
          pkgs.coreutils
          pkgs.jq
          pkgs.mtools
          pkgs.python3
          pkgs.qemu
          pkgs.zigpkgs."master-2026-07-16"
          zls.packages.${system}.zls
        ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
          pkgs.kcov
        ];
      };
    });
  };
}
