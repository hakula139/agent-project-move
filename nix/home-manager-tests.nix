# ==================================================================================================
# agent-project-move Home Manager Module Tests
# ==================================================================================================

{
  home-manager,
  homeModule,
  pkgs,
}:

let
  inherit (pkgs) lib;

  stub = pkgs.runCommandLocal "agent-project-move-stub" { } ''
    mkdir -p $out/bin $out/share/skills/agent-project-move
    touch $out/share/skills/agent-project-move/SKILL.md
  '';

  evalHome =
    module:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        homeModule
        {
          home = {
            homeDirectory = "/home/u";
            username = "u";
            stateVersion = "26.05";
          };

          programs.agent-project-move = {
            enable = true;
            package = stub;
          };
        }
        module
      ];
    }).config;

  home = evalHome { };
  emptySkills = evalHome {
    programs.agent-project-move.skillDirectories = [ ];
    programs.claude-code.enable = true;
  };

  failures = lib.runTests {
    testEnabledInstallsThePackageAndLinksTheSkill = {
      expr = {
        installsPackage = builtins.elem stub home.home.packages;
        claudeLink = home.home.file.".claude/skills/agent-project-move".source;
        codexLink = home.home.file.".codex/skills/agent-project-move".source;
      };

      expected = {
        installsPackage = true;
        claudeLink = "${stub}/share/skills/agent-project-move";
        codexLink = "${stub}/share/skills/agent-project-move";
      };
    };

    testEmptyDirectoriesLinkNothingEvenWithClaudeCode = {
      expr = builtins.filter (lib.hasInfix "skills/agent-project-move") (
        builtins.attrNames emptySkills.home.file
      );
      expected = [ ];
    };
  };
in
assert lib.assertMsg (failures == [ ]) "failed tests: ${builtins.toJSON failures}";
pkgs.emptyFile
