{pkgs, inputs, config, ...}: let
  zig-cov = pkgs.stdenv.mkDerivation {
    pname = "zig-cov";
    version = "0.1.0";
    src = inputs.zcov;
    nativeBuildInputs = [config.languages.zig.package] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.autoPatchelfHook
    ];
    buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
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
  languages.zig = {
    enable = true;
    version = "master-2026-09-20";
  };

  packages = [
    pkgs.codebook
    pkgs.coreutils
    pkgs.minicom
    pkgs.mtools
    pkgs.python3
    pkgs.qemu
    pkgs.which
    zig-cov
  ];
}
