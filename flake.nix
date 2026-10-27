{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = { self, ... }@inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];
      imports = [
        inputs.git-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      perSystem = { pkgs, config, lib, system, ... }: {
        # Nix code formatter -> 'nix fmt'
        treefmt.config = {
          projectRootFile = "flake.nix";
          flakeFormatter = true;
          flakeCheck = true;
          programs = {
            deadnix.enable = true;
            nixpkgs-fmt.enable = true;
            shellcheck.enable = true;
            shfmt.enable = true;
            statix.enable = true;
          };
        };

        # Pre-commit hooks
        pre-commit.check.enable = false;
        pre-commit.settings.hooks.treefmt = {
          enable = true;
          package = config.treefmt.build.wrapper;
        };

        # Development shell -> 'nix develop' or 'direnv allow'
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.pre-commit ];
          shellHook = config.pre-commit.installationScript;
        };

        packages = {
          tpm-host-key = pkgs.callPackage ./package.nix { };
          default = config.packages.tpm-host-key;
        };

        checks = {
          derive = config.packages.tpm-host-key.tests.derive;
          # The module must also evaluate on hosts without agenix
          module = (inputs.nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.default
              {
                boot.loader.grub.enable = false;
                fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
                nixpkgs.hostPlatform = system;
                services.openssh.enable = true;
                services.tpmHostKey.enable = true;
                system.stateVersion = lib.trivial.release;
              }
            ];
          }).config.system.build.toplevel;
        };
      };

      flake = {
        nixosModules = {
          tpmHostKey.imports = [ ./nixosModules ];
          default = self.nixosModules.tpmHostKey;
        };
      };
    };
}
