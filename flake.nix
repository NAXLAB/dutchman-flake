{
  description = "Dutchman: ferries CAD designs between formats";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.dutchman-src = {
    url = "github:dutchman-cad/dutchman";
    flake = false;
  };

  outputs =
    { self, nixpkgs, dutchman-src }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      cargoToml = builtins.fromTOML (builtins.readFile "${dutchman-src}/Cargo.toml");
      version = cargoToml.workspace.package.version;
      rustVersion = cargoToml.workspace.package."rust-version";

      mkPackages =
        pkgs:
        let
          inherit (pkgs) lib;

          # Workspace MSRV comes straight from Cargo.toml.
          _ = lib.assertMsg (lib.versionAtLeast pkgs.rustc.version rustVersion)
            "dutchman needs Rust ${rustVersion} or newer, but this nixpkgs has ${pkgs.rustc.version}";

          src = dutchman-src;

          common = {
            inherit version src;
            cargoLock.lockFile = "${dutchman-src}/Cargo.lock";
          };

          meta = {
            description = "Ferries CAD designs between formats: decodes native design files into open, editable models";
            homepage = "https://github.com/dutchman-cad/dutchman";
            license = lib.licenses.asl20;
          };

          # Libraries that winit / glutin / wgpu dlopen at runtime on Linux.
          guiRuntimeLibs =
            with pkgs;
            [
              wayland
              libxkbcommon
              libGL
              vulkan-loader
              (pkgs.libx11 or pkgs.xorg.libX11)
              (pkgs.libxcursor or pkgs.xorg.libXcursor)
              (pkgs.libxi or pkgs.xorg.libXi)
              (pkgs.libxrandr or pkgs.xorg.libXrandr)
            ];
        in
        rec {
          # `dutchman` and `dutchman-mcp` (both live in the `dutchman` crate).
          dutchman = pkgs.rustPlatform.buildRustPackage (
            common
            // {
              pname = "dutchman";
              cargoBuildFlags = [ "--package" "dutchman" ];
              cargoTestFlags = [ "--package" "dutchman" ];
              meta = meta // {
                mainProgram = "dutchman";
              };
            }
          );

          # Desktop app. Tests (egui_kittest) want a GPU, so they are skipped here.
          dutchman-gui = pkgs.rustPlatform.buildRustPackage (
            common
            // {
              pname = "dutchman-gui";
              cargoBuildFlags = [ "--package" "dutchman-gui" ];
              doCheck = false;

              nativeBuildInputs = [ pkgs.pkg-config ];
              buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux guiRuntimeLibs;

              postFixup = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
                patchelf --add-rpath ${lib.makeLibraryPath guiRuntimeLibs} $out/bin/dutchman-gui
              '';

              meta = meta // {
                mainProgram = "dutchman-gui";
              };
            }
          );

          # CLI + MCP server + GUI in one profile.
          full = pkgs.symlinkJoin {
            name = "dutchman-full-${version}";
            paths = [
              dutchman
              dutchman-gui
            ];
            inherit meta;
          };

          default = dutchman;
        };
    in
    {
      packages = forAllSystems mkPackages;

      apps = forAllSystems (
        pkgs:
        let
          p = mkPackages pkgs;
        in
        {
          default = {
            type = "app";
            program = "${p.dutchman}/bin/dutchman";
          };
          dutchman = {
            type = "app";
            program = "${p.dutchman}/bin/dutchman";
          };
          dutchman-mcp = {
            type = "app";
            program = "${p.dutchman}/bin/dutchman-mcp";
          };
          dutchman-gui = {
            type = "app";
            program = "${p.dutchman-gui}/bin/dutchman-gui";
          };
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [
            (mkPackages pkgs).dutchman
            (mkPackages pkgs).dutchman-gui
          ];
          packages = with pkgs; [
            cargo
            rustc
            clippy
            rustfmt
            rust-analyzer
          ];
          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          LD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux (
            pkgs.lib.makeLibraryPath (
              with pkgs;
              [
                wayland
                libxkbcommon
                libGL
                vulkan-loader
                (pkgs.libx11 or pkgs.xorg.libX11)
                (pkgs.libxcursor or pkgs.xorg.libXcursor)
                (pkgs.libxi or pkgs.xorg.libXi)
                (pkgs.libxrandr or pkgs.xorg.libXrandr)
              ]
            )
          );
        };
      });

      overlays.default = final: _prev: {
        inherit (mkPackages final) dutchman dutchman-gui;
      };
    };
}