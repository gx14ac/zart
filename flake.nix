{
  description = "BART routing table library development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils  }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "bart-dev";
          buildInputs = with pkgs; [
            pkg-config
            gcc
            nodejs_20
            nodePackages.npm
          ];

          shellHook = ''
            echo "BART development environment"
            echo "Zig version: $(zig version)"
            echo "Node.js version: $(node --version)"
            echo "npm version: $(npm --version)"
            
            if ! command -v codex &> /dev/null; then
              echo "Installing Codex..."
              npm install -g @openai/codex
            fi
          '';
        };

        packages = {
          default = pkgs.stdenv.mkDerivation {
            name = "bart";
            src = ./.;
            nativeBuildInputs = with pkgs; [
              pkg-config
              gcc
            ];

            buildPhase = ''
              zig build
            '';

            installPhase = ''
              mkdir -p $out/lib $out/include
              cp zig-out/lib/libbart.a $out/lib/
              cp zig-out/include/bart.h $out/include/
            '';
          };

          codex = pkgs.nodePackages."@openai/codex";
        };

        apps = {
          codex = {
            type = "app";
            program = "${pkgs.nodePackages."@openai/codex"}/bin/codex";
          };
        };
      }
    );
} 