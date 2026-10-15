{
  lib,
  sourceRoot,
  version,
  mkOpcode,
}: let
  # The darwin-arm64 port is a shipped target only when a macOS runner
  # really builds and tests it. release.yml must carry the macos-14 job
  # that publishes opcode-darwin-arm64; a port with no runner stays gated
  # off everywhere, matching tools/targets.sh's `macos_ci_job`.
  darwinArm64Ci = let
    release = builtins.readFile (sourceRoot + "/.github/workflows/release.yml");
  in
    lib.hasInfix "macos-14" release
    && lib.hasInfix "opcode-darwin-arm64" release;

  # The linux-aarch64 port must cross-build on x86_64-linux and run the
  # full suite under qemu-aarch64 before it ships.  The path gate is not
  # enough now that src/plat/linux/aarch64/ exists.
  aarch64QemuCi = let
    ci = builtins.readFile (sourceRoot + "/.github/workflows/ci.yml");
    release = builtins.readFile (sourceRoot + "/.github/workflows/release.yml");
  in
    lib.hasInfix "build and test linux-aarch64 with QEMU" ci
    && lib.hasInfix "EMULATOR=qemu-aarch64" ci
    && lib.hasInfix "Build and verify linux-aarch64 under QEMU" release
    && lib.hasInfix "EMULATOR=qemu-aarch64" release;

  # The windows-x86_64 port must build from x86_64-linux with the mingw
  # cross toolchain and pass its Wine lane before it ships.  The gate names
  # the workspace files and both workflow steps, so a source-only port can
  # never be built by release-all.
  windowsWineCi = let
    ci = builtins.readFile (sourceRoot + "/.github/workflows/ci.yml");
    release = builtins.readFile (sourceRoot + "/.github/workflows/release.yml");
  in
    lib.hasInfix "build and verify windows-x86_64 under Wine" ci
    && lib.hasInfix "test-wine" ci
    && lib.hasInfix "windows-x86_64 under Wine" release
    && lib.hasInfix "test-wine" release;

  # ------------------------------------------------------------ targets
  #
  # The cross-build matrix behind `nix run .#targets`, `tools/targets.sh`
  # and .github/workflows/release.yml. `gate` lists the paths that must all
  # exist before the target is buildable (`null` only for the native
  # target); every path is fed to `builtins.pathExists`. A closed gate
  # means the port sources or the x86-64 -> AArch64 translator are not in
  # the tree: CI skips the target with a notice, it never builds a broken
  # binary and never fails the whole release.
  #
  # `toolchain` names the intended toolchain, `cross` is the GNU triple
  # consumed by the Makefile's CROSS= variable and `crossSet` is the
  # pkgsCross attribute that carries the cross binutils.
  opcodeTargets = {
    linux-x86_64 = {
      os = "linux";
      arch = "x86_64";
      native = true;
      gate = null;
      toolchain = "native gnu binutils";
      artifact = "opcode-linux-x86_64";
    };
    linux-aarch64 = {
      os = "linux";
      arch = "aarch64";
      native = false;
      # The translator + shim are necessary, but not sufficient: the
      # target must be cross-built on x86_64-linux and the full suite
      # executed under qemu-aarch64 before release.  The Darwin arm64
      # port remains a separate target gated by its own macos-14 CI job.
      gate = [(sourceRoot + "/tools/arm64.py") (sourceRoot + "/src/plat/linux/aarch64")];
      ciGate = aarch64QemuCi;
      toolchain = "pkgsCross.aarch64-multiplatform.binutils";
      cross = "aarch64-unknown-linux-gnu";
      crossSet = "aarch64-multiplatform";
      artifact = "opcode-linux-aarch64";
    };
    linux-riscv64 = {
      os = "linux";
      arch = "riscv64";
      native = false;
      gate = [(sourceRoot + "/src/plat/riscv64") (sourceRoot + "/src/net/riscv64")];
      toolchain = "pkgsCross.riscv64.binutils";
      cross = "riscv64-unknown-linux-gnu";
      crossSet = "riscv64";
      artifact = "opcode-linux-riscv64";
    };
    windows-x86_64 = {
      os = "win";
      arch = "x86_64";
      native = false;
      # Cross-built on x86_64-linux; verified by the Wine lane before it
      # is allowed into release-all.
      crossBuild = true;
      gate = [(sourceRoot + "/src/plat/win") (sourceRoot + "/src/net/win") (sourceRoot + "/tests/run-wine.sh")];
      ciGate = windowsWineCi;
      toolchain = "pkgsCross.mingwW64 (binutils + gcc) + wine64";
      artifact = "opcode-windows-x86_64.exe";
    };
    darwin-arm64 = {
      os = "mac";
      arch = "aarch64";
      native = false;
      gate = [(sourceRoot + "/src/plat/mac") (sourceRoot + "/src/net/mac") (sourceRoot + "/tools/arm64.py")];
      ciGate = darwinArm64Ci;
      artifact = "opcode-darwin-arm64";
    };
    # The Darwin work is AArch64-only and the Makefile fails fast on any
    # darwin-* TARGET except darwin-arm64. This gate names the x86_64
    # Darwin platform/net sources that would be required; they do not
    # exist, so the target is closed on every host (and the system-aware
    # matrix/release-all filter then never selects it).
    darwin-x86_64 = {
      os = "mac";
      arch = "x86_64";
      native = false;
      gate = [(sourceRoot + "/src/plat/mac/x86_64") (sourceRoot + "/src/net/mac/x86_64")];
      toolchain = "llvmPackages.clang (-target x86_64-apple-darwin)";
      artifact = "opcode-darwin-x86_64";
    };
  };

  # A target is enabled when every gated path exists and, for darwin-arm64,
  # when the macOS CI job exists too. The native target has no gate.
  targetEnabled = t:
    (t.gate == null || lib.all builtins.pathExists t.gate)
    && (t.ciGate or true);

  # Host facts a target selection depends on.
  hostArch = pkgs: pkgs.stdenv.hostPlatform.parsed.cpu.name;
  hostOs = pkgs:
    if pkgs.stdenv.hostPlatform.isDarwin
    then "mac"
    else if pkgs.stdenv.hostPlatform.isWindows
    then "win"
    else "linux";
  # A target runs on a host of its own OS, or is cross-built there
  # (windows-x86_64 is cross-built on x86_64-linux).
  hostCanBuild = pkgs: t:
    t.os
    == hostOs pkgs
    || ((t.crossBuild or false) && pkgs.stdenv.hostPlatform.isLinux);

  # Every target this system can build now (gate open and host compatible).
  buildable = pkgs:
    lib.filterAttrs (
      name: t:
        targetEnabled t
        && hostCanBuild pkgs t
        && (!t.native || t.arch == hostArch pkgs)
    )
    opcodeTargets;

  # Matrix packages are distribution builds: stripped (RELEASE=1). Foreign
  # test binaries cannot run on the build host.
  mkTarget = pkgs: name: t:
    mkOpcode pkgs {
      release = true;
      target =
        if t.native
        then null
        else name;
      cross = t.cross or null;
      os = t.os;
      doCheck = t.native;
      extraInputs =
        lib.optionals (t ? crossSet) [
          pkgs.pkgsCross.${t.crossSet}.binutils
          pkgs.pkgsCross.${t.crossSet}.stdenv.cc
        ]
        ++ lib.optionals ((t.toolchain or "") == "llvmPackages") [
          pkgs.llvmPackages.llvm
          pkgs.llvmPackages.lld
        ]
        ++ lib.optionals (name == "windows-x86_64") [
          pkgs.pkgsCross.mingwW64.buildPackages.binutils
          pkgs.pkgsCross.mingwW64.buildPackages.gcc
        ];
    };

  # Linux-hosted cross/smoke build of the darwin-arm64 target.  It assembles
  # the Mach-O arm64 object set with LLVM clang and links it with Zig, whose
  # bundled libSystem stub makes a Mach-O link possible on a Linux builder
  # (pkgsCross.aarch64-darwin cannot be built here at all; ADR-7).  This is
  # explicitly NOT the release artifact -- that is produced and tested only
  # by the macOS runner.  tools/check-macho.sh gates the output, so the
  # binaries cannot exist unless the static Mach-O checks pass.
  mkDarwinCross = pkgs:
    pkgs.stdenv.mkDerivation {
      pname = "opcode-darwin-arm64-cross";
      inherit version;
      src = sourceRoot;

      nativeBuildInputs = with pkgs; [
        gnumake
        python3
        llvmPackages.clang
        llvmPackages.bintools
        zig
      ];

      # The output is Mach-O arm64; the ELF fixup/strip machinery would fail
      # on it.
      dontFixup = true;
      dontStrip = true;

      # The binary is linked -nostdlib on a glibc builder; glibc's
      # _FORTIFY_SOURCE wrappers (__inet_pton_chk, __memcpy_chk, ...) have no
      # implementation here. Same reason as mkOpcode's setting.
      hardeningDisable = ["fortify"];

      buildPhase = ''
        runHook preBuild
        make -j$NIX_BUILD_CORES darwin-arm64-cross darwin-arm64-test \
          ARM64_CC="${pkgs.llvmPackages.clang}/bin/clang" \
          ARM64_LD="${pkgs.zig}/bin/zig cc" \
          ARM64_LDFLAGS="-target aarch64-macos.11.0 -mmacosx-version-min=11.0"
        runHook postBuild
      '';

      doCheck = true;
      checkPhase = ''
        runHook preCheck
        tools/check-macho.sh build/opcode-darwin-arm64
        tools/check-macho.sh --smoke build/smoke-darwin-arm64
        tools/check-macho.sh --smoke build/mac/tests/str_test
        runHook postCheck
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 build/opcode-darwin-arm64 $out/bin/opcode-darwin-arm64
        install -Dm755 build/smoke-darwin-arm64 $out/bin/smoke-darwin-arm64
        runHook postInstall
      '';

      meta = {
        description = "opcode darwin-arm64 cross/smoke build (Linux host; not a release artifact)";
        license = pkgs.lib.licenses.mit;
        platforms = pkgs.lib.platforms.linux;
        mainProgram = "opcode-darwin-arm64";
      };
    };

  # Everything a given system exposes from the target matrix: the per-target
  # packages, the single installable covering them all, and the Linux-hosted
  # Darwin cross/smoke build.
  mkCross = pkgs: let
    targetDrvs = lib.mapAttrs (mkTarget pkgs) (buildable pkgs);
    matrix = pkgs.linkFarm "opcode-matrix" (
      lib.mapAttrsToList (name: drv: {
        inherit name;
        path = drv;
      })
      targetDrvs
    );
  in {
    inherit targetDrvs matrix;
    darwin-arm64-cross = mkDarwinCross pkgs;
  };
in {
  inherit opcodeTargets targetEnabled hostArch hostOs hostCanBuild mkTarget mkCross;
}
