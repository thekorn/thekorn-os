{pkgs, inputs, ...}: let
  zig = pkgs.zigpkgs."master-2026-08-28";
  zig-cov = pkgs.stdenv.mkDerivation {
    pname = "zig-cov";
    version = "0.1.0";
    src = inputs.zcov;
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
    inputs.zls.packages.${pkgs.stdenv.hostPlatform.system}.zls
  ];
}
