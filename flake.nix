{
  description = "Opcode - a minimal, extensible coding agent written in hand-written assembly";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      version = lib.removeSuffix "\n" (builtins.readFile ./VERSION);

      # The darwin-arm64 port is a shipped target only when a macOS runner
      # really builds and tests it. release.yml must carry the macos-14 job
      # that publishes opcode-darwin-arm64; a port with no runner stays gated
      # off everywhere, matching tools/targets.sh's `macos_ci_job`.
      darwinArm64Ci =
        let release = builtins.readFile ./.github/workflows/release.yml;
        in lib.hasInfix "macos-14" release
          && lib.hasInfix "opcode-darwin-arm64" release;

      # The linux-aarch64 port must cross-build on x86_64-linux and run the
      # full suite under qemu-aarch64 before it ships.  The path gate is not
      # enough now that src/plat/linux/aarch64/ exists.
      aarch64QemuCi =
        let ci = builtins.readFile ./.github/workflows/ci.yml;
            release = builtins.readFile ./.github/workflows/release.yml;
        in lib.hasInfix "build and test linux-aarch64 with QEMU" ci
          && lib.hasInfix "EMULATOR=qemu-aarch64" ci
          && lib.hasInfix "Build and verify linux-aarch64 under QEMU" release
          && lib.hasInfix "EMULATOR=qemu-aarch64" release;

      # The windows-x86_64 port must build from x86_64-linux with the mingw
      # cross toolchain and pass its Wine lane before it ships.  The gate names
      # the workspace files and both workflow steps, so a source-only port can
      # never be built by release-all.
      windowsWineCi =
        let ci = builtins.readFile ./.github/workflows/ci.yml;
            release = builtins.readFile ./.github/workflows/release.yml;
        in lib.hasInfix "build and verify windows-x86_64 under Wine" ci
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
          gate = [ ./tools/arm64.py ./src/plat/linux/aarch64 ];
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
          gate = [ ./src/plat/riscv64 ./src/net/riscv64 ];
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
          gate = [ ./src/plat/win ./src/net/win ./tests/run-wine.sh ];
          ciGate = windowsWineCi;
          toolchain = "pkgsCross.mingwW64 (binutils + gcc) + wine64";
          artifact = "opcode-windows-x86_64.exe";
        };
        darwin-arm64 = {
          os = "mac";
          arch = "aarch64";
          native = false;
          gate = [ ./src/plat/mac ./src/net/mac ./tools/arm64.py ];
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
          gate = [ ./src/plat/mac/x86_64 ./src/net/mac/x86_64 ];
          toolchain = "llvmPackages.clang (-target x86_64-apple-darwin)";
          artifact = "opcode-darwin-x86_64";
        };
      };

      # A target is enabled when every gated path exists and, for darwin-arm64,
      # when the macOS CI job exists too. The native target has no gate.
      targetEnabled = t:
        (t.gate == null || lib.all builtins.pathExists t.gate)
        && (t.ciGate or true);

      # Shared derivation recipe. With no arguments it is exactly the native
      # debug package; `release` adds RELEASE=1, `target`/`cross` rename the
      # output and select the toolchain.
      mkOpcode = pkgs: { release ? false, target ? null, cross ? null, os ? "linux", extraInputs ? [], doCheck ? true }:
        let
          makeArgs = lib.concatStringsSep " " (
            [ "-j$NIX_BUILD_CORES" ]
            ++ lib.optional release "RELEASE=1"
            ++ lib.optional (cross != null) "CROSS=${cross}"
            ++ lib.optional (target != null) "TARGET=${target}"
          );
          binary = if target == null then "build/opcode"
            else if os == "win" then "build/opcode-${target}.exe"
            else "build/opcode-${target}";
          # The Windows PE is cross-built on Linux, so its derivation must
          # evaluate on the Linux host; the artifact itself is native PE32+
          # (this is meta only).
          platforms = if os == "mac" then pkgs.lib.platforms.darwin
            else pkgs.lib.platforms.linux;
        in
        pkgs.stdenv.mkDerivation {
          pname = "opcode";
          inherit version;
          src = ./.;

          nativeBuildInputs = with pkgs; [
            gnumake
            llvmPackages.clang
            python3
          ] ++ lib.optionals (os != "mac") [ binutils ] ++ extraInputs;

          # The binary is linked with -nostdlib; glibc's _FORTIFY_SOURCE
          # wrappers (__memcpy_chk, ...) have no implementation here.
          hardeningDisable = [ "fortify" ];

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

      # Linux-hosted cross/smoke build of the darwin-arm64 target.  It assembles
      # the Mach-O arm64 object set with LLVM clang and links it with Zig, whose
      # bundled libSystem stub makes a Mach-O link possible on a Linux builder
      # (pkgsCross.aarch64-darwin cannot be built here at all; ADR-7).  This is
      # explicitly NOT the release artifact -- that is produced and tested only
      # by the macOS runner.  tools/check-macho.sh gates the output, so the
      # binaries cannot exist unless the static Mach-O checks pass.
      mkDarwinCross = pkgs: pkgs.stdenv.mkDerivation {
        pname = "opcode-darwin-arm64-cross";
        inherit version;
        src = ./.;

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
        hardeningDisable = [ "fortify" ];

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
    in
    {
      # Machine-readable target table; tools/targets.sh mirrors it for shells.
      lib = {
        inherit opcodeTargets targetEnabled;
      };

      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          debug = mkOpcode pkgs { };
          release = mkOpcode pkgs { release = true; };

          # A target is buildable from this system when its gate is open, its
          # OS matches the builder, and (for a native target) the host really
          # is that architecture. The macOS targets are built only by the
          # macOS runner: a Linux builder excludes them instead of trying to
          # cross-link a foreign OS. A closed (or host-mismatched) target is
          # simply absent; it is never turned into a broken artifact.
          hostArch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
          hostOs =
            if pkgs.stdenv.hostPlatform.isDarwin then "mac"
            else if pkgs.stdenv.hostPlatform.isWindows then "win"
            else "linux";
          # A target runs on a host of its own OS, or is cross-built there
          # (windows-x86_64 is cross-built on x86_64-linux).
          hostCanBuild = t: t.os == hostOs
            || ((t.crossBuild or false) && pkgs.stdenv.hostPlatform.isLinux);
          buildable = lib.filterAttrs (name: t:
            targetEnabled t && hostCanBuild t
            && (!t.native || t.arch == hostArch)) opcodeTargets;

          mkTarget = name: t: mkOpcode pkgs {
            # Matrix packages are distribution builds: stripped (RELEASE=1).
            release = true;
            target = if t.native then null else name;
            cross = t.cross or null;
            os = t.os;
            # Foreign test binaries cannot run on the build host.
            doCheck = t.native;
            extraInputs =
              lib.optionals (t ? crossSet) [
                pkgs.pkgsCross.${t.crossSet}.binutils
                pkgs.pkgsCross.${t.crossSet}.stdenv.cc
              ]
              ++ lib.optionals ((t.toolchain or "") == "llvmPackages") [ pkgs.llvmPackages.llvm pkgs.llvmPackages.lld ]
              ++ lib.optionals (name == "windows-x86_64") [
                pkgs.pkgsCross.mingwW64.buildPackages.binutils
                pkgs.pkgsCross.mingwW64.buildPackages.gcc
              ];
          };
          targetDrvs = lib.mapAttrs mkTarget buildable;
          # One installable covering every enabled target; individual targets
          # are also exposed as packages.<system>.<name>. Gated-closed targets
          # are absent here entirely.
          matrix = pkgs.linkFarm "opcode-matrix"
            (lib.mapAttrsToList (name: drv: { inherit name; path = drv; }) targetDrvs);

          # Release bundle consumed by .github/workflows/release.yml: every
          # buildable target copied to `opcode-<os>-<arch>` (`.exe` on Windows)
          # plus SHA256SUMS. Gate-closed targets are never built; they are
          # listed in SKIPPED and reported with a ::notice:: while the
          # derivation runs, so a closed gate can never fail a release.
          releaseAll =
            let
              # Relative display name of a gated path for the notice text.
              gateLabel = p:
                lib.removePrefix (toString ./. + "/") (toString p);
              entries = lib.mapAttrsToList (name: t: {
                inherit name;
                artifact = t.artifact;
                enabled = targetEnabled t && hostCanBuild t
                  && (!t.native || t.arch == hostArch);
                drv = mkTarget name t;
                reason =
                  if t.os != hostOs
                  then "requires a ${t.os} builder (host is ${hostOs})"
                  else if t.gate == null
                  then "native ${t.arch} target; host is ${hostArch}"
                  else "missing " + lib.concatStringsSep ", "
                    (map gateLabel (lib.filter (p: !builtins.pathExists p) t.gate));
              }) opcodeTargets;
              enabled = lib.filter (e: e.enabled) entries;
              skipped = lib.filter (e: !e.enabled) entries;
            in
            pkgs.runCommand "opcode-release-all"
              { nativeBuildInputs = [ pkgs.coreutils ]; }
              ''
                mkdir -p "$out"
                ${lib.concatMapStrings (e: ''
                  install -m0755 ${e.drv}/bin/opcode "$out/${e.artifact}"
                '') enabled}
                : > "$out/SKIPPED"
                ${lib.concatMapStrings (e: ''
                  echo "::notice::${e.name}: ${e.reason}"
                  echo "${e.name}: ${e.reason}" >> "$out/SKIPPED"
                '') skipped}
                (
                  cd "$out"
                  sha256sum ${lib.concatStringsSep " " (map (e: e.artifact) enabled)} > SHA256SUMS
                )
              '';
        in
        {
          default = debug;
          inherit release matrix;
          release-all = releaseAll;
        } // targetDrvs
          // lib.optionalAttrs (system == "x86_64-linux") {
            # The Linux-hosted darwin cross/smoke build; see mkDarwinCross.  Not
            # a release artifact and not part of the target matrix.
            darwin-arm64-cross = mkDarwinCross pkgs;
          });

      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          targets = {
            type = "app";
            program = "${pkgs.writeShellScript "opcode-targets" ''
              exec ${self}/tools/targets.sh "$@"
            ''}";
          };
        });

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          # Cross binutils for the Linux targets, ready the day a port lands.
          # The aarch64 cross gcc is the C compiler of the linux-aarch64
          # build (mbedTLS, the glue, the TLS shim, the plugins): it carries
          # its own aarch64 glibc sysroot, so the freestanding C set compiles
          # against arch-correct headers instead of the host's.
          # No macOS SDKs here: they are unfree and untestable in this tree.
          crossTools = lib.optionals pkgs.stdenv.isLinux [
            pkgs.pkgsCross.aarch64-multiplatform.binutils
            pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc
          ] ++ lib.optionals (pkgs.pkgsCross ? riscv64) [
            pkgs.pkgsCross.riscv64.binutils
          ];
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              gnumake
              binutils
              curl
              llvmPackages.clang
              python3
            ] ++ lib.optionals (pkgs ? gdb) [ pkgs.gdb ]
              ++ lib.optionals (pkgs ? hyperfine) [ pkgs.hyperfine ]
              ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs ? qemu-user) [ pkgs.qemu-user ]
              ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs ? wine64) [
                pkgs.wine64
                pkgs.pkgsCross.mingwW64.buildPackages.binutils
                pkgs.pkgsCross.mingwW64.buildPackages.gcc
              ]
              ++ crossTools;
          };
        });

      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = self.packages.${system}.default;
          release = self.packages.${system}.release;
          targets = pkgs.runCommand "opcode-targets-table" { } ''
            ${self}/tools/targets.sh > $out
          '';
        } // lib.optionalAttrs (system == "x86_64-linux" && targetEnabled opcodeTargets.windows-x86_64) {
          # Cross-compile the PE on Linux; the Wine execution lane lives in CI
          # (a Nix sandbox cannot run wineserver reliably).
          windows-x86_64 = self.packages.${system}.windows-x86_64;
        } // lib.optionalAttrs (system == "x86_64-linux" && targetEnabled opcodeTargets.darwin-arm64) {
          # Cross/smoke build plus tools/check-macho.sh.  Gated on the darwin
          # sources being present so a tree without them never breaks
          # `nix flake check`.
          darwin-arm64-cross = self.packages.${system}.darwin-arm64-cross;
        } // lib.optionalAttrs (system == "x86_64-linux" && targetEnabled opcodeTargets.linux-aarch64) {
          # Cross-build the linux-aarch64 static ELF and execute aarch64 code
          # under qemu-aarch64.  The full integration suite is the gate for
          # this check: it runs inside the sandbox and must report a clean
          # "TESTS <n> passed, 0 failed".  Loopback networking is probed
          # first; without it the loopback-dependent integration suites cannot
          # run, so the check fails rather than silently downgrading to the
          # sandbox-safe subset.
          linux-aarch64-qemu =
            let
              crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
            in
            pkgs.stdenv.mkDerivation {
              pname = "opcode-linux-aarch64-qemu";
              inherit version;
              src = ./.;

              nativeBuildInputs = with pkgs; [
                gnumake
                python3
                qemu-user
                coreutils
                curl
                binutils
                crossPkgs.binutils
                crossPkgs.stdenv.cc
              ];

              hardeningDisable = [ "fortify" ];

              buildPhase = ''
                runHook preBuild
                rm -rf build
                make -j$NIX_BUILD_CORES linux-aarch64 test-aarch64
                runHook postBuild
              '';

              doCheck = true;
              checkPhase = ''
                runHook preCheck

                export OPCODE_TARGET=linux-aarch64
                export EMULATOR=qemu-aarch64
                export EMU_TIMEOUT_SCALE=10

                # Empirical loopback probe: the 12 integration suites bind and
                # connect on 127.0.0.1.  Determine whether the Nix sandbox
                # allows that, by measurement rather than by assumption.
                loopback_ok=0
                if ${pkgs.python3}/bin/python3 -c "
                import socket
                try:
                    s = socket.socket()
                    s.bind(('127.0.0.1', 0))
                    s.listen(1)
                    c = socket.socket()
                    c.connect(s.getsockname())
                    a, _ = s.accept()
                    a.close(); c.close(); s.close()
                except OSError as e:
                    print('loopback probe failed:', e)
                    raise SystemExit(1)
                " > loopback.log 2>&1; then
                  echo "Sandbox loopback networking: available"
                  loopback_ok=1
                else
                  echo "Sandbox loopback networking: NOT available"
                  echo "Loopback-dependent integration suites are excluded from this flake check."
                fi

                echo "Binary under test:"
                readelf -h build/opcode-linux-aarch64 | grep -E 'Class|Machine|Type'
                echo "Emulator: $($EMULATOR --version | head -1)"
                echo "Executing aarch64 unit binaries and CLI checks under qemu-aarch64..."

                pass=0
                fail=0
                for t in tests/*.s; do
                  n=$(basename "$t" .s)
                  test_out="build/$n.out"
                  rc=0
                  # shellcheck disable=SC2086
                  $EMULATOR "./build/a64/tests/$n" > "$test_out" 2>&1 || rc=$?
                  if [ "$rc" -ne 0 ]; then
                    echo "FAIL $n (exit $rc)"
                    fail=$((fail + 1))
                  elif cmp -s "$test_out" "tests/data/$n.expected"; then
                    echo "ok   $n"
                    pass=$((pass + 1))
                  else
                    echo "FAIL $n"
                    diff -u "tests/data/$n.expected" "$test_out" | head -40 || true
                    fail=$((fail + 1))
                  fi
                done

                v=$(cat VERSION)
                # shellcheck disable=SC2086
                if [ "$($EMULATOR build/opcode-linux-aarch64 --version)" = "opcode $v" ]; then
                  echo "ok   cli-version"
                  pass=$((pass + 1))
                else
                  echo "FAIL cli-version"
                  fail=$((fail + 1))
                fi

                # shellcheck disable=SC2086
                if $EMULATOR build/opcode-linux-aarch64 --help > /dev/null 2>&1; then
                  echo "ok   cli-help"
                  pass=$((pass + 1))
                else
                  echo "FAIL cli-help"
                  fail=$((fail + 1))
                fi

                # shellcheck disable=SC2086
                $EMULATOR build/opcode-linux-aarch64 --nope > /dev/null 2>&1 && rc=0 || rc=$?
                if [ "$rc" = 2 ]; then
                  echo "ok   cli-unknown"
                  pass=$((pass + 1))
                else
                  echo "FAIL cli-unknown (exit $rc)"
                  fail=$((fail + 1))
                fi

                echo "QEMU sandbox-safe check: $pass passed, $fail failed"

                if [ $loopback_ok -ne 1 ]; then
                  echo "FATAL: loopback networking unavailable; the full QEMU suite cannot run."
                  exit 1
                fi

                # The full suite is authoritative: it supersedes the
                # sandbox-safe subset above (same unit binaries + CLI checks,
                # plus the 12 integration suites).  Its success is required.
                echo "Running the full QEMU suite (make test-qemu)..."
                set +e
                timeout 600 sh -c 'OPCODE_TARGET=linux-aarch64 EMULATOR=qemu-aarch64 make -j$NIX_BUILD_CORES test-qemu' > full.log 2>&1
                full_rc=$?
                set -e
                tail -5 full.log || true
                if [ $full_rc -ne 0 ] || ! grep -q '^TESTS [0-9]* passed, 0 failed' full.log; then
                  echo "FATAL: full QEMU suite did not pass (rc=$full_rc)."
                  tail -40 full.log || true
                  exit 1
                fi
                echo "Full QEMU suite passed inside the Nix sandbox."

                runHook postCheck
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out
                install -Dm755 build/opcode-linux-aarch64 $out/bin/opcode-linux-aarch64
                echo "linux-aarch64 QEMU sandbox-safe check passed" > $out/success
                if [ -f full.log ]; then
                  cp full.log $out/
                fi
                cp loopback.log $out/ 2>/dev/null || true
                runHook postInstall
              '';

              meta = {
                description = "opcode linux-aarch64 cross-build + QEMU sandbox-safe verification";
                license = pkgs.lib.licenses.mit;
                platforms = pkgs.lib.platforms.linux;
              };
            };
        });
    };
}
