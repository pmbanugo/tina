{
  description = "Tina development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Change the ref below to use another Odin tag/branch, e.g.:
    #   github:odin-lang/Odin/dev-2026-06
    #   github:odin-lang/Odin/master
    odin-src = {
      url = "github:odin-lang/Odin/dev-2026-06";
      flake = false;
    };
  };

  outputs =
    { nixpkgs, odin-src, ... }:
    let
      odinVersion = "dev-2026-06";

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forEachSystem = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs {
            inherit system;
          }));
    in
    {
      devShells = forEachSystem (pkgs: {
        default =
          let
            odin = pkgs.odin.overrideAttrs (_: {
              version = odinVersion;
              src = odin-src;
            });
          in
          pkgs.mkShell {
            packages = [
              odin
            ];
          };
      });

      formatter = forEachSystem (pkgs: pkgs.nixfmt);
    };
}
