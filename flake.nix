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

        # 一時的にcodex-pkgを分離
        codex-pkg = pkgs.buildNpmPackage {
          pname = "codex-cli";
          version = "0.1.0";
          src = ./.;
          npmDepsHash = "";
          npmInstallFlags = [ "--frozen-lockfile" ];
          # 一時的にpostPatchを削除
          meta = with pkgs.lib; {
            description = "OpenAI Codex command-line interface";
            license = licenses.asl20;
            homepage = "https://github.com/openai/codex";
          };
        };

      in
      {
        # 開発用のシェルを分離
        devShells = {
          # メインの開発環境
          default = pkgs.mkShell {
            name = "bart-dev";
            buildInputs = with pkgs; [
              pkg-config
              gcc
              nodejs_22
            ];

            shellHook = ''
              echo "BART development environment"
              echo "Node.js version: $(node --version)"
            '';
          };

          # Codex用の開発環境
          codex = pkgs.mkShell {
            name = "codex-dev";
            buildInputs = with pkgs; [
              nodejs_22
            ];

            shellHook = ''
              echo "Codex development environment"
              echo "Node.js version: $(node --version)"
              
              # package-lock.jsonが存在しない場合は生成
              if [ ! -f package-lock.json ]; then
                echo "Generating package-lock.json..."
                npm install
              fi
            '';
          };
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