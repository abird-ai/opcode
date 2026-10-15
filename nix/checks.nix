{
  pkgs,
  lib,
  self,
  system,
  sourceRoot,
  version,
  opcodeTargets,
  targetEnabled,
}: let
  # Lint only the files this repo owns: vendored trees, build output and the
  # historical agent run records are not ours to reformat.
  lintSource = extension:
    lib.cleanSourceWith {
      src = sourceRoot;
      filter = path: type:
        if type == "directory"
        then !(lib.elem (baseNameOf path) [".git" "third_party" "build" "dist" "runs"])
        else
          lib.hasSuffix ".${extension}" path
          || (extension == "md" && baseNameOf path == ".markdownlint-cli2.jsonc");
    };

  # `alejandra --check` over flake.nix and nix/ (the same formatter the dev
  # shell and `nix fmt` use).
  alejandra =
    pkgs.runCommand "opcode-alejandra" {
      nativeBuildInputs = [pkgs.alejandra];
    } ''
      alejandra --check ${lintSource "nix"}
      touch "$out"
    '';

  # markdownlint over every owned .md, driven by .markdownlint-cli2.jsonc.
  markdownlint =
    pkgs.runCommand "opcode-markdownlint" {
      nativeBuildInputs = [pkgs.markdownlint-cli2];
    } ''
      cd ${lintSource "md"}
      markdownlint-cli2
      touch "$out"
    '';
  # clang-format conformance for the C sources (the style lives in
  # .clang-format).
  clangFormat =
    pkgs.runCommand "opcode-clang-format" {
      nativeBuildInputs = [pkgs.llvmPackages.clang-tools];
    } ''
      cd ${lib.cleanSourceWith {
        src = sourceRoot;
        filter = path: type:
          if type == "directory"
          then !(lib.elem (baseNameOf path) [".git" "third_party" "build" "dist" "runs"])
          else
            lib.hasSuffix ".c" path
            || lib.hasSuffix ".h" path
            || baseNameOf path == ".clang-format";
      }}
      clang-format --style=file --dry-run --Werror $(find . -name '*.c' -o -name '*.h')
      touch "$out"
    '';

  # clang-tidy over the owned C units. bear records the Makefile flags and
  # clang-tidy reads .clang-tidy; the vendored mbedTLS units are dropped from
  # the list so only owned code is linted.
  clangTidy = pkgs.stdenv.mkDerivation {
    pname = "opcode-clang-tidy";
    inherit version;
    src = sourceRoot;

    nativeBuildInputs = with pkgs; [
      bear
      clang
      gnumake
      python3
      binutils
      llvmPackages.clang-tools
    ];

    hardeningDisable = ["fortify"];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      rm -rf build
      bear -- make -j$NIX_BUILD_CORES
      runHook postBuild
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      python3 -c "import json; [print(e['file']) for e in json.load(open('compile_commands.json')) if not e['file'].startswith('third_party/')]" > tidylist
      echo "clang-tidy: $(wc -l < tidylist) translation units"
      # The Makefile compiles the mbedTLS/TLS units through the nix cc-wrapper,
      # whose implicit glibc -isystem is absent from the recorded command; add
      # it so clang-tidy sees the same headers the build did.
      xargs -P "$NIX_BUILD_CORES" -n1 clang-tidy -p . --quiet \
        --extra-arg=-isystem${pkgs.glibc.dev}/include < tidylist
      runHook postCheck
    '';
    installPhase = ''touch "$out"'';
  };

  # Assembly lint: there is no GNU-as linter, so assemble the whole tree with
  # `as --fatal-warnings`. Any assembler diagnostic fails the check.
  assembly = pkgs.stdenv.mkDerivation {
    pname = "opcode-assembly";
    inherit version;
    src = sourceRoot;

    nativeBuildInputs = with pkgs; [
      clang
      gnumake
      python3
      binutils
    ];

    hardeningDisable = ["fortify"];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      rm -rf build
      make -j$NIX_BUILD_CORES AS="as --fatal-warnings"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 build/opcode $out/bin/opcode
      runHook postInstall
    '';
  };
in
  {
    default = self.packages.${system}.default;
    release = self.packages.${system}.release;
    targets = pkgs.runCommand "opcode-targets-table" {} ''
      ${self}/tools/targets.sh > $out
    '';
    inherit alejandra markdownlint clangFormat clangTidy assembly;
  }
  // lib.optionalAttrs (system == "x86_64-linux" && targetEnabled opcodeTargets.windows-x86_64) {
    # Cross-compile the PE on Linux; the Wine execution lane lives in CI
    # (a Nix sandbox cannot run wineserver reliably).
    windows-x86_64 = self.packages.${system}.windows-x86_64;
  }
  // lib.optionalAttrs (system == "x86_64-linux" && targetEnabled opcodeTargets.darwin-arm64) {
    # Cross/smoke build plus tools/check-macho.sh.  Gated on the darwin
    # sources being present so a tree without them never breaks
    # `nix flake check`.
    darwin-arm64-cross = self.packages.${system}.darwin-arm64-cross;
  }
  // lib.optionalAttrs (system == "x86_64-linux" && targetEnabled opcodeTargets.linux-aarch64) {
    # Cross-build the linux-aarch64 static ELF and execute aarch64 code
    # under qemu-aarch64.  The full integration suite is the gate for
    # this check: it runs inside the sandbox and must report a clean
    # "TESTS <n> passed, 0 failed".  Loopback networking is probed
    # first; without it the loopback-dependent integration suites cannot
    # run, so the check fails rather than silently downgrading to the
    # sandbox-safe subset.
    linux-aarch64-qemu = let
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
    in
      pkgs.stdenv.mkDerivation {
        pname = "opcode-linux-aarch64-qemu";
        inherit version;
        src = sourceRoot;

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

        hardeningDisable = ["fortify"];

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
  }
