{
  inputs,
  sourceRoot,
}: let
  inherit (inputs) nixpkgs self;
  lib = nixpkgs.lib;
  systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
  forAllSystems = lib.genAttrs systems;
  pkgsFor = system: import nixpkgs {inherit system;};
  version = lib.removeSuffix "\n" (builtins.readFile (sourceRoot + "/VERSION"));

  native = import ./native.nix {inherit lib sourceRoot version;};
  cross = import ./cross.nix {
    inherit lib sourceRoot version;
    inherit (native) mkOpcode;
  };

  perSystem = system: let
    pkgs = pkgsFor system;
    crossPkgs = cross.mkCross pkgs;
    releaseBundle = import ./release.nix {
      inherit pkgs lib sourceRoot;
      inherit (cross) opcodeTargets targetEnabled mkTarget hostArch hostOs hostCanBuild;
    };
    dev = import ./dev.nix {inherit pkgs lib;};
    packages =
      {
        default = native.mkOpcode pkgs {};
        release = native.mkOpcode pkgs {release = true;};
        matrix = crossPkgs.matrix;
        release-all = releaseBundle.releaseAll;
      }
      // crossPkgs.targetDrvs
      // lib.optionalAttrs (system == "x86_64-linux") {
        darwin-arm64-cross = crossPkgs.darwin-arm64-cross;
      };
  in {
    inherit packages;
    checks = import ./checks.nix {
      inherit pkgs lib self system sourceRoot version;
      inherit (cross) opcodeTargets targetEnabled;
    };
    apps.targets = {
      type = "app";
      program = "${pkgs.writeShellScript "opcode-targets" ''
        exec ${self}/tools/targets.sh "$@"
      ''}";
    };
    devShells.default = dev.shell;
    inherit (dev) formatter;
  };
in {
  # Machine-readable target table; tools/targets.sh mirrors it for shells.
  lib = {
    inherit (cross) opcodeTargets targetEnabled;
  };

  packages = forAllSystems (system: (perSystem system).packages);
  apps = forAllSystems (system: (perSystem system).apps);
  devShells = forAllSystems (system: (perSystem system).devShells);
  formatter = forAllSystems (system: (perSystem system).formatter);
  checks = forAllSystems (system: (perSystem system).checks);
}
