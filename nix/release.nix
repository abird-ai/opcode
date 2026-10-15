{
  pkgs,
  lib,
  sourceRoot,
  opcodeTargets,
  targetEnabled,
  mkTarget,
  hostArch,
  hostOs,
  hostCanBuild,
}: {
  # Release bundle consumed by .github/workflows/release.yml: every
  # buildable target copied to `opcode-<os>-<arch>` (`.exe` on Windows)
  # plus SHA256SUMS. Gate-closed targets are never built; they are
  # listed in SKIPPED and reported with a ::notice:: while the
  # derivation runs, so a closed gate can never fail a release.
  releaseAll = let
    # Relative display name of a gated path for the notice text.
    gateLabel = p: lib.removePrefix (toString sourceRoot + "/") (toString p);
    entries =
      lib.mapAttrsToList (name: t: {
        inherit name;
        artifact = t.artifact;
        enabled =
          targetEnabled t
          && hostCanBuild pkgs t
          && (!t.native || t.arch == hostArch pkgs);
        drv = mkTarget pkgs name t;
        reason =
          if t.os != hostOs pkgs
          then "requires a ${t.os} builder (host is ${hostOs pkgs})"
          else if t.gate == null
          then "native ${t.arch} target; host is ${hostArch pkgs}"
          else
            "missing "
            + lib.concatStringsSep ", "
            (map gateLabel (lib.filter (p: !builtins.pathExists p) t.gate));
      })
      opcodeTargets;
    enabled = lib.filter (e: e.enabled) entries;
    skipped = lib.filter (e: !e.enabled) entries;
  in
    pkgs.runCommand "opcode-release-all"
    {nativeBuildInputs = [pkgs.coreutils];}
    ''
      mkdir -p "$out"
      ${lib.concatMapStrings (e: ''
          install -m0755 ${e.drv}/bin/opcode "$out/${e.artifact}"
        '')
        enabled}
      : > "$out/SKIPPED"
      ${lib.concatMapStrings (e: ''
          echo "::notice::${e.name}: ${e.reason}"
          echo "${e.name}: ${e.reason}" >> "$out/SKIPPED"
        '')
        skipped}
      (
        cd "$out"
        sha256sum ${lib.concatStringsSep " " (map (e: e.artifact) enabled)} > SHA256SUMS
      )
    '';
}
