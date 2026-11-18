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
      url = "github:hakula139/devkit/v3";
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
    }:
    let
      inherit (nixpkgs) lib;

      runtimeInputs =
        pkgs: with pkgs; [
          coreutils
          diffutils
          findutils
          ripgrep
          sqlite
          zstd
        ];

      mkAgentProjectMove =
        pkgs:
        (devkit.lib.mkLib pkgs).mkNuApplication {
          pname = "agent-project-move";
          inherit (lib.importJSON ./.claude-plugin/plugin.json) version;
          src = ./skills/agent-project-move/scripts;
          skills = [ ./skills/agent-project-move ];
          runtimeInputs = runtimeInputs pkgs;
          meta = {
            description = "Move, transfer, and retire coding agent sessions";
            homepage = "https://github.com/hakula139/agent-project-move";
            license = lib.licenses.mit;
            platforms = lib.platforms.all;
          };
        };

      platformKey = p: {
        inherit (p) config isStatic;
      };

      packageFor =
        pkgs:
        let
          locked = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-project-move or null;
        in
        if
          locked != null
          && platformKey pkgs.stdenv.buildPlatform == platformKey locked.stdenv.buildPlatform
          && platformKey pkgs.stdenv.hostPlatform == platformKey locked.stdenv.hostPlatform
          && pkgs.stdenv.hostPlatform == pkgs.stdenv.targetPlatform
        then
          locked
        else
          mkAgentProjectMove pkgs;

      # A key lets the module system deduplicate the module when it is imported twice.
      homeModuleKey = "${self}/flake.nix#homeModules.default";
    in
    # ----------------------------------------------------------------------------------------------
    # Overlay and Home Manager Module
    # ----------------------------------------------------------------------------------------------
    {
      overlays.default = _: prev: { agent-project-move = packageFor prev; };

      homeModules.default = {
        _class = "homeManager";
        _file = homeModuleKey;
        key = homeModuleKey;
        imports = [
          (import ./nix/home-manager.nix {
            inherit devkit packageFor;
          })
        ];
      };
    }
    // devkit.lib.eachSystem devkit.lib.systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        dk = devkit.lib.mkLib pkgs;

        commonInputs = runtimeInputs pkgs;

        agentProjectMove = mkAgentProjectMove pkgs;

        preCommit = dk.preCommit {
          src = ./.;
          hooks = {
            nu-check.enable = true;
            prettier.enable = true;
            shellcheck.enable = true;
            shfmt.enable = true;
          };
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
          ]
          ++ commonInputs;

          inputsFrom = [ preCommit ];
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
        checks = import ./nix/checks.nix {
          inherit
            self
            pkgs
            dk
            agentProjectMove
            commonInputs
            ;
        };

        # ------------------------------------------------------------------------------------------
        # Formatter
        # ------------------------------------------------------------------------------------------
        formatter = pkgs.nixfmt-tree;
      }
    );
}
