{
  description = "zyouz - Terminal Pane Manager";

  nixConfig = {
    extra-substituters = ["https://yutaura.cachix.org"];
    extra-trusted-public-keys = ["yutaura.cachix.org-1:uoMGhQXiri/CBTK1IByqBipk42mkEfWhYo2q9ENseJ8="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    {
      homeModules.default = import ./nix/hm-module.nix;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zyouz";
          version = "0.3.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig_0_15.hook ];

          # zig test requires a TTY, which is unavailable in the Nix sandbox
          dontUseZigCheck = true;

          meta = with pkgs.lib; {
            description = "A terminal multiplexer driven by a static config file";
            homepage = "https://github.com/YutaUra/zyouz";
            license = licenses.mit;
            maintainers = [ ];
            mainProgram = "zyouz";
            platforms = platforms.unix;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            zig
            zls
          ];
          ZYOUZ_CONFIG = "./config.dev.zon";
        };
      }
    );
}
