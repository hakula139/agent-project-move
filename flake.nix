# ==================================================================================================
# agent-project-move Development Flake
# ==================================================================================================

{
  description = "agent-project-move packages and development environment";

  nixConfig = {
    extra-substituters = [ "https://hakula.cachix.org" ];
    extra-trusted-public-keys = [
      "hakula.cachix.org-1:7zwB3fhMfReHdOjh6DmnaLXgqbPDBcojvN9F+osZw0k="
    ];
  };

  # ------------------------------------------------------------------------------------------------
  # Inputs
  # ------------------------------------------------------------------------------------------------
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    devkit = {
      url = "github:hakula139/devkit/61682dd34d15732234bac835f3603de8de5b86f1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # ------------------------------------------------------------------------------------------------
  # Outputs
  # ------------------------------------------------------------------------------------------------
  outputs =
    {
      self,
      nixpkgs,
      devkit,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      mkAgentProjectMove =
        pkgs:
        (devkit.lib.mkLib pkgs).mkNuApplication {
          pname = "agent-project-move";
          version = "0.1.0";
          src = ./src;
          skills = [ ./skills/agent-project-move ];
          runtimeInputs = with pkgs; [
            coreutils
            diffutils
            findutils
            ripgrep
            sqlite
            zstd
          ];
          meta = {
            description = "Move, prune, and transfer the project state stored by coding agents";
            homepage = "https://github.com/hakula139/agent-project-move";
            license = lib.licenses.mit;
            platforms = lib.platforms.all;
          };
        };

      # A key lets the module system deduplicate the module when it is imported twice.
      homeModuleKey = "${self}/flake.nix#homeModules.default";
    in
    # ----------------------------------------------------------------------------------------------
    # Overlay and Home Manager Module
    # ----------------------------------------------------------------------------------------------
    {
      overlays.default = final: _: { agent-project-move = mkAgentProjectMove final; };

      homeModules.default = {
        _class = "homeManager";
        _file = homeModuleKey;
        key = homeModuleKey;
        imports = [
          (import ./nix/home-manager.nix {
            inherit devkit mkAgentProjectMove;
          })
        ];
      };
    }
    // devkit.lib.eachSystem devkit.lib.systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        dk = devkit.lib.mkLib pkgs;

        agentProjectMove = mkAgentProjectMove pkgs;

        preCommit = dk.preCommit {
          src = ./.;
          hooks.nu-check.enable = true;
        };
      in
      {
        # ------------------------------------------------------------------------------------------
        # Dev Shell
        # ------------------------------------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          name = "agent-project-move-dev";

          packages = [
            dk.nushell
            dk.nu-test
            pkgs.git-cliff
            pkgs.ripgrep
            pkgs.sqlite
            pkgs.zstd
          ];

          inputsFrom = [
            preCommit.shell
          ];
        };

        # ------------------------------------------------------------------------------------------
        # Packages
        # ------------------------------------------------------------------------------------------
        packages = {
          default = agentProjectMove;
          agent-project-move = agentProjectMove;
        };

        # ------------------------------------------------------------------------------------------
        # Checks
        # ------------------------------------------------------------------------------------------
        checks = {
          pre-commit = preCommit.check;

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
                      _module.args.pkgs = pkgs;
                      programs.agent-project-move.enable = true;
                    };
                  }
                ];
              };
            in
            pkgs.writeText "home-module.json" (builtins.toJSON eval.config.home);

          package = agentProjectMove;

          tests = dk.nuTests {
            src = ./.;
            runtimeInputs = [ pkgs.sqlite ];
          };
        };

        # ------------------------------------------------------------------------------------------
        # Formatter
        # ------------------------------------------------------------------------------------------
        formatter = pkgs.nixfmt-tree;
      }
    );
}
