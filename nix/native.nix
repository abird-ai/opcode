{
  lib,
  sourceRoot,
  version,
}: {
  # Shared derivation recipe. With no arguments it is exactly the native
  # debug package; `release` adds RELEASE=1, `target`/`cross` rename the
  # output and select the toolchain. `pkgs` picks the builder (native or a
  # pkgsCross set).
  mkOpcode = pkgs: {
    release ? false,
    target ? null,
    cross ? null,
    os ? "linux",
    extraInputs ? [],
    doCheck ? true,
  }: let
    makeArgs = lib.concatStringsSep " " (
      ["-j$NIX_BUILD_CORES"]
      ++ lib.optional release "RELEASE=1"
      ++ lib.optional (cross != null) "CROSS=${cross}"
      ++ lib.optional (target != null) "TARGET=${target}"
    );
    binary =
      if target == null
      then "build/opcode"
      else if os == "win"
      then "build/opcode-${target}.exe"
      else "build/opcode-${target}";
    # The Windows PE is cross-built on Linux, so its derivation must
    # evaluate on the Linux host; the artifact itself is native PE32+
    # (this is meta only).
    platforms =
      if os == "mac"
      then pkgs.lib.platforms.darwin
      else pkgs.lib.platforms.linux;
  in
    pkgs.stdenv.mkDerivation {
      pname = "opcode";
      inherit version;
      src = sourceRoot;

      nativeBuildInputs =
        (with pkgs; [
          gnumake
          llvmPackages.clang
          python3
        ])
        ++ lib.optionals (os != "mac") [pkgs.binutils]
        ++ extraInputs;

      # The binary is linked with -nostdlib; glibc's _FORTIFY_SOURCE
      # wrappers (__memcpy_chk, ...) have no implementation here.
      hardeningDisable = ["fortify"];

      # A path: flake reference copies the working tree including
      # gitignored build artifacts; start from a clean object tree so the
      # derivation really builds from source.
      preBuild = ''
        rm -rf build
      '';

      buildPhase = ''
        runHook preBuild
        make ${makeArgs}
        runHook postBuild
      '';

      inherit doCheck;
      checkPhase = ''
        runHook preCheck
        make -j$NIX_BUILD_CORES test
        runHook postCheck
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 ${binary} $out/bin/opcode
        runHook postInstall
      '';

      meta = with pkgs.lib; {
        description = "A minimal, extensible coding agent written in hand-written assembly";
        license = licenses.mit;
        inherit platforms;
        mainProgram = "opcode";
      };
    };
}
