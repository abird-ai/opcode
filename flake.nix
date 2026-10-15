{
  description = "Opcode - a minimal, extensible coding agent written in hand-written assembly";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = inputs:
    import ./nix {
      inherit inputs;
      sourceRoot = ./.;
    };
}
