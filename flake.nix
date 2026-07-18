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
    firmwareRevision = "ed05d403048f2956d9d3653acd996157363e94fe";
  in {
    devShells = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [zig-overlay.overlays.default];
      };
    in {
      default = pkgs.mkShell {
        RPI_FIRMWARE_REVISION = firmwareRevision;
        RPI_START4 = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/raspberrypi/firmware/${firmwareRevision}/boot/start4.elf";
          hash = "sha256-ESATIAB6XaaM6sHpKGoQZmZth6oBkEWlJBRPPA5YuEQ=";
        };
        RPI_FIXUP4 = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/raspberrypi/firmware/${firmwareRevision}/boot/fixup4.dat";
          hash = "sha256-eVv7JRS1Qdxq17obBibGu3aX9/ao9FLJyBroYbgt5qY=";
        };
        RPI_DTB = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/raspberrypi/firmware/${firmwareRevision}/boot/bcm2711-rpi-4-b.dtb";
          hash = "sha256-dXYbc8KE4mYj5NFiS/8T5nvOKuYgiA79gdZXGjc5/Ps=";
        };
        RPI_DISABLE_BT = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/raspberrypi/firmware/${firmwareRevision}/boot/overlays/disable-bt.dtbo";
          hash = "sha256-6mnSLe3GB/7nXuxX2KTMDw6rk811OT5hpkxJ+6yRLQI=";
        };
        RPI_FIRMWARE_LICENSE = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/raspberrypi/firmware/${firmwareRevision}/boot/LICENCE.broadcom";
          hash = "sha256-xyg/9R+GPZOidcZuO0ywgCGl3U2MHnrMR9hy++UtPWs=";
        };
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
