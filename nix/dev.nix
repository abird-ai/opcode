{
  pkgs,
  lib,
}: {
  shell = let
    # Cross binutils for the Linux targets, ready the day a port lands.
    # The aarch64 cross gcc is the C compiler of the linux-aarch64
    # build (mbedTLS, the glue, the TLS shim, the plugins): it carries
    # its own aarch64 glibc sysroot, so the freestanding C set compiles
    # against arch-correct headers instead of the host's.
    # No macOS SDKs here: they are unfree and untestable in this tree.
    crossTools =
      lib.optionals pkgs.stdenv.isLinux [
        pkgs.pkgsCross.aarch64-multiplatform.binutils
        pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc
      ]
      ++ lib.optionals (pkgs.pkgsCross ? riscv64) [
        pkgs.pkgsCross.riscv64.binutils
      ];
  in
    pkgs.mkShell {
      packages =
        (with pkgs; [
          gnumake
          binutils
          curl
          llvmPackages.clang
          python3
          # linting: clang-format/clang-tidy for C23, cppcheck, asmfmt for the
          # hand-written assembly, markdownlint and alejandra for the docs/flake
          clang-tools
          cppcheck
          asmfmt
          markdownlint-cli2
          alejandra
        ])
        ++ lib.optionals (pkgs ? gdb) [pkgs.gdb]
        ++ lib.optionals (pkgs ? hyperfine) [pkgs.hyperfine]
        ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs ? qemu-user) [pkgs.qemu-user]
        ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs ? wine64) [
          pkgs.wine64
          pkgs.pkgsCross.mingwW64.buildPackages.binutils
          pkgs.pkgsCross.mingwW64.buildPackages.gcc
        ]
        ++ crossTools;
    };

  formatter = pkgs.alejandra;
}
