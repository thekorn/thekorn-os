{
  description = "thekorn-os";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zcov = {
      url = "github:ericsssan/zcov/d5b606ab43b31fbf4ba88b6484be95cb03747de2";
      flake = false;
    };
    zls.url = "github:zigtools/zls/master";
  };

  outputs = {
    nixpkgs,
    zig-overlay,
    zcov,
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
      zig = pkgs.zigpkgs."master-2026-08-28";
      zig-cov = pkgs.stdenv.mkDerivation {
        pname = "zig-cov";
        version = "0.1.0";
        src = zcov;
        nativeBuildInputs = [zig] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
          pkgs.autoPatchelfHook
        ];
        buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
          pkgs.glibc
        ];
        dontConfigure = true;
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
          zig build -Doptimize=safe --prefix "$out"
          runHook postInstall
        '';
      };
    in {
      default = pkgs.mkShell {
        packages = [
          pkgs.codebook
          pkgs.coreutils
          pkgs.minicom
          pkgs.mtools
          pkgs.python3
          pkgs.qemu
          pkgs.which
          zig
          zig-cov
          zls.packages.${system}.zls
        ];
      };
    });
  };
}
