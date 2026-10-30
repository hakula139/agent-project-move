# ==================================================================================================
# agent-project-move Home Manager Module
# ==================================================================================================

{
  mkAgentProjectMove,
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.agent-project-move;

  skillLinks = lib.listToAttrs (
    map (directory: {
      name = "${directory}/agent-project-move";
      value.source = cfg.skill;
    }) cfg.skillDirectories
  );
in
{
  # ------------------------------------------------------------------------------------------------
  # Module Options
  # ------------------------------------------------------------------------------------------------
  options.programs.agent-project-move = {
    enable = lib.mkEnableOption "agent-project-move and its agent skill";

    package = lib.mkOption {
      type = lib.types.package;
      default = mkAgentProjectMove pkgs;
      defaultText = lib.literalExpression "agent-project-move built from this flake";
      description = "Package that provides the `agent-project-move` command.";
    };

    skillDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        ".claude/skills"
        ".codex/skills"
      ];
      description = ''
        Home-relative directories that each receive a link to the skill directory. Codex skips
        a skill whose `SKILL.md` is itself a symlink.
      '';
    };

    skill = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = "${cfg.package}/share/skills/agent-project-move";
      defaultText = lib.literalExpression ''
        "''${config.programs.agent-project-move.package}/share/skills/agent-project-move"
      '';
      description = "Read-only path to the installed skill directory.";
    };
  };

  # ------------------------------------------------------------------------------------------------
  # Module Config
  # ------------------------------------------------------------------------------------------------
  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.file = skillLinks;
  };
}
