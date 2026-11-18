# ==================================================================================================
# agent-project-move Home Manager Module
# ==================================================================================================

{
  devkit,
  packageFor,
}:

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.programs.agent-project-move;
  systemExpr = "\${pkgs.stdenv.hostPlatform.system}";
  defaultPackage = "agent-project-move.packages.${systemExpr}.agent-project-move";
in
{
  # ------------------------------------------------------------------------------------------------
  # Module Options
  # ------------------------------------------------------------------------------------------------
  options.programs.agent-project-move = {
    enable = lib.mkEnableOption "agent-project-move and its agent skill";

    package = lib.mkOption {
      type = lib.types.package;
      default = packageFor pkgs;
      defaultText = lib.literalExpression defaultPackage;
      description = "Package that provides the `agent-project-move` command.";
    };

    skillDirectories = lib.mkOption devkit.lib.skillDirectoriesOption;
  };

  # ------------------------------------------------------------------------------------------------
  # Module Config
  # ------------------------------------------------------------------------------------------------
  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.file = devkit.lib.skillLinks {
      inherit (cfg) package;
      name = "agent-project-move";
      directories = cfg.skillDirectories;
    };
  };
}
