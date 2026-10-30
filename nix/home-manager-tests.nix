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

  home =
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
            skillDirectories = [ ".claude/skills" ];
          };
        }
      ];
    }).config;

  failures = lib.runTests {
    testEnabledInstallsThePackageAndLinksTheSkill = {
      expr = {
        installsPackage = builtins.elem stub home.home.packages;
        skill = home.programs.agent-project-move.skill;
        link = home.home.file.".claude/skills/agent-project-move".source;
      };

      expected = {
        installsPackage = true;
        skill = "${stub}/share/skills/agent-project-move";
        link = "${stub}/share/skills/agent-project-move";
      };
    };
  };
in
assert lib.assertMsg (failures == [ ]) "failed tests: ${builtins.toJSON failures}";
pkgs.runCommand "agent-project-move-home-manager-module" { } ''
  touch "$out"
''
