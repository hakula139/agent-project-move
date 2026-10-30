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
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
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
      nixpkgs-unstable,
      git-hooks-nix,
      home-manager,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      eachSystem =
        f:
        let
          bySystem = lib.genAttrs systems f;
          outputs = builtins.attrNames bySystem.${builtins.head systems};
        in
        lib.genAttrs outputs (output: builtins.mapAttrs (_: attrs: attrs.${output}) bySystem);

      # nixos-26.05 ships Nushell 0.112.2, and the modules need `str lowercase` from 0.114.
      nushellFor = pkgs: nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.nushell;

      mkAgentProjectMove =
        pkgs: pkgs.callPackage ./nix/agent-project-move.nix { nushell = nushellFor pkgs; };

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
        imports = [ (import ./nix/home-manager.nix { inherit mkAgentProjectMove; }) ];
      };
    }
    // eachSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nushell = nushellFor pkgs;

        agentProjectMove = mkAgentProjectMove pkgs;

        # ------------------------------------------------------------------------------------------
        # Pre-commit Hooks
        # ------------------------------------------------------------------------------------------
        hooks = {
          actionlint.enable = true;
          check-added-large-files.enable = true;
          check-yaml.enable = true;
          deadnix.enable = true;
          editorconfig-checker.enable = true;
          end-of-file-fixer.enable = true;
          nixfmt.enable = true;
          statix.enable = true;
          taplo.enable = true;

          cspell = {
            enable = true;
            args = [
              "--no-progress"
              "--no-must-find-files"
            ];
          };

          markdownlint = {
            enable = true;
            args = [ "--fix" ];
          };

          nu-check = {
            enable = true;
            name = "nu-check";
            description = "Run Nushell's diagnostic check on .nu files.";
            package = nushell;
            entry = lib.getExe (
              pkgs.writeShellApplication {
                name = "nu-check";
                runtimeInputs = [ nushell ];
                text = ''exec nu --no-config-file ${./scripts/nu-check.nu} "$@"'';
              }
            );
            files = "\\.nu$";
            types = [ "file" ];
          };

          prettier = {
            enable = true;
            files = "\\.(js|json|jsonc|ya?ml)$";
          };

          trim-trailing-whitespace = {
            enable = true;
            # Preserve Markdown's two-trailing-space hard-break syntax.
            args = [ "--markdown-linebreak-ext=md" ];
          };
        };

        preCommit = git-hooks-nix.lib.${system}.run {
          src = ./.;
          package = pkgs.prek;
          # Fixtures are byte-for-byte inputs, so no hook may rewrite them.
          excludes = [ "(^|/)fixtures/" ];
          inherit hooks;
        };

        flock = lib.getExe pkgs.flock;
        git = lib.getExe pkgs.git;

      in
      {
        # ------------------------------------------------------------------------------------------
        # Dev Shell
        # ------------------------------------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          name = "agent-project-move-dev";

          packages = [
            nushell
            pkgs.git-cliff
            pkgs.ripgrep
            pkgs.sqlite
            pkgs.zstd
          ]
          ++ preCommit.enabledPackages
          ++ [ preCommit.config.package ];

          # git-hooks.nix sets a hooks path relative to the main checkout, which linked worktrees
          # cannot resolve (cachix/git-hooks.nix#688). Unset it to use the shared hooks directory.
          # The lock prevents concurrent loads from setting the path during `pre-commit install`,
          # which rejects it. Install only when the current repository is this project, since
          # `nix develop` can borrow this toolchain from a sibling repository.
          shellHook = ''
            if common=$(${git} rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
              top=$(${git} rev-parse --show-toplevel 2>/dev/null) &&
              [ -f "$top/flake.nix" ] && grep -q agent-project-move "$top/flake.nix"; then
              (
                ${flock} 9
                ${preCommit.config.installationScript}
                ${git} config --local --unset-all core.hooksPath || true
              ) 9>"$common/git-hooks.lock"
            fi
          '';
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
          pre-commit = preCommit;

          tests =
            pkgs.runCommand "agent-project-move-tests"
              {
                nativeBuildInputs = [
                  pkgs.findutils
                  pkgs.ripgrep
                  pkgs.sqlite
                  pkgs.zstd
                ];
              }
              ''
                cd ${./.}
                ${lib.getExe nushell} --no-config-file scripts/nu-test.nu $(find src -name '*.test.nu' | sort)
                touch "$out"
              '';

          home-manager = import ./nix/home-manager-tests.nix {
            inherit home-manager pkgs;
            homeModule = self.homeModules.default;
          };

          overlay =
            assert (pkgs.extend self.overlays.default).agent-project-move.drvPath == agentProjectMove.drvPath;
            pkgs.emptyFile;
        };

        # ------------------------------------------------------------------------------------------
        # Formatter
        # ------------------------------------------------------------------------------------------
        formatter = pkgs.nixfmt-tree;
      }
    );
}
