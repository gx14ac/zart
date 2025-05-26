{
  description = "BART routing table library development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        codex-pkg = pkgs.buildNpmPackage {
          pname = "codex-cli";
          version = "0.1.0";
          src = ./.;
          npmDepsHash = "sha256-PNfd3/suM2c+A5gKGBorGqApL0APoti/9UB857V4GjA=";
          npmInstallFlags = [ "--frozen-lockfile" ];
          dontNpmBuild = true;
          dontBuild = true;
          postPatch = ''
            if [ ! -f package-lock.json ]; then
              echo "Error: package-lock.json not found"
              exit 1
            fi
          '';
          meta = with pkgs.lib; {
            description = "OpenAI Codex command-line interface";
            license = licenses.asl20;
            homepage = "https://github.com/openai/codex";
          };
        };

      in
      {
        devShells.default = pkgs.mkShell {
          name = "bart-dev";
          buildInputs = with pkgs; [
            pkg-config
            gcc
            nodejs_22
            codex-pkg
          ];

          shellHook = ''
            echo "BART development environment"
            echo "Node.js version: $(node --version)"
            echo "Codex version: $(codex --version)"
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

          codex-cli = codex-pkg;
        };

        apps = {
          codex = {
            type = "app";
            program = "${codex-pkg}/bin/codex";
          };
        };
      }
    );
} 