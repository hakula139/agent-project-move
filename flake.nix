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
      ...
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
        canaryPkgs = pkgs.extend (_: prev: { zstd = prev.hello; });
        drvPath = pkg: builtins.unsafeDiscardStringContext pkg.drvPath;

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
            pkgs.ripgrep
            pkgs.sqlite
            pkgs.zstd
          ];

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
        checks = {
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

          package = agentProjectMove;

          tests = dk.nuTests {
            src = ./.;
            runtimeInputs = commonInputs;
          };
        };

        # ------------------------------------------------------------------------------------------
        # Formatter
        # ------------------------------------------------------------------------------------------
        formatter = pkgs.nixfmt-tree;
      }
    );
}
