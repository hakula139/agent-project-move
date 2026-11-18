# ==================================================================================================
# agent-project-move Flake Checks
# ==================================================================================================

{
  self,
  pkgs,
  dk,
  agentProjectMove,
  commonInputs,
}:

let
  inherit (pkgs) lib;

  canaryPkgs = pkgs.extend (_: prev: { zstd = prev.hello; });
  drvPath = pkg: builtins.unsafeDiscardStringContext pkg.drvPath;
in
{
  # ------------------------------------------------------------------------------------------------
  # Home Manager Module
  # ------------------------------------------------------------------------------------------------
  home-module =
    let
      eval = lib.evalModules {
        class = "homeManager";
        modules = [
          self.homeModules.default
          {
            options.home = {
              packages = lib.mkOption { type = lib.types.anything; };
              file = lib.mkOption { type = lib.types.anything; };
            };
            config = {
              _module.args.pkgs = canaryPkgs;
              programs.agent-project-move.enable = true;
            };
          }
        ];
      };
      installed = map drvPath eval.config.home.packages;
    in
    assert lib.assertMsg (
      installed == [ (drvPath agentProjectMove) ]
    ) "Home Manager module reconstructed the locked package";
    pkgs.writeText "home-module.json" (builtins.toJSON eval.config.home);

  # ------------------------------------------------------------------------------------------------
  # Overlay
  # ------------------------------------------------------------------------------------------------
  overlay =
    let
      overlaid = (canaryPkgs.extend self.overlays.default).agent-project-move;
      staticPkgs = canaryPkgs // {
        stdenv = canaryPkgs.stdenv // {
          hostPlatform = canaryPkgs.stdenv.hostPlatform // {
            isStatic = true;
          };
        };
      };
      fallback =
        if pkgs.stdenv.isLinux then
          (pkgs.pkgsMusl.extend self.overlays.default).agent-project-move
        else
          (self.overlays.default staticPkgs staticPkgs).agent-project-move;
    in
    assert lib.assertMsg (
      drvPath overlaid == drvPath agentProjectMove
    ) "overlay reconstructed the locked package";
    assert lib.assertMsg (
      drvPath fallback != drvPath agentProjectMove
    ) "overlay reused the locked package for an incompatible platform";
    pkgs.emptyFile;

  # ------------------------------------------------------------------------------------------------
  # Package and Tests
  # ------------------------------------------------------------------------------------------------
  package = agentProjectMove;

  tests = dk.nuTests {
    src = ../.;
    runtimeInputs = commonInputs;
  };
}
