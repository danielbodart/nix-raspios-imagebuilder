{
  description = "Build Raspberry Pi OS images in Nix derivations";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # An app: ./scripts/common.sh, then the script. nix, ssh and sudo are
      # the machine's own, so its configuration of each holds.
      app = pkgs: name: runtimeInputs: pkgs.writeShellApplication {
        name = "raspios-${name}";
        inherit runtimeInputs;
        text = builtins.readFile ./scripts/common.sh + builtins.readFile ./scripts/${name}.sh;
      };
    in
    {
      # Modules to give mkImage: core always, the rest as wanted.
      raspiosModules = {
        core = ./modules/core.nix;
        network = ./modules/network.nix;
        ssh = ./modules/ssh.nix;
      };

      lib = {
        # mkImage { modules, system ? "aarch64-linux" } or { modules, pkgs }:
        # an image, as a derivation. system, or pkgs, is the machine that
        # builds it: aarch64-linux for builder = "sandbox", any Linux with
        # KVM for "vm".
        mkImage = args:
          import ./build { core = self.raspiosModules.core; } ({
            pkgs = nixpkgs.legacyPackages.${args.system or "aarch64-linux"};
          } // removeAttrs args [ "system" ]);
      };

      packages = forAllSystems (pkgs: with pkgs; {
        lock = app pkgs "lock" [ apt gnupg jq gawk gnused coreutils ];
        flash = app pkgs "flash" [ zstd util-linux e2fsprogs gawk gnugrep coreutils ];
        upgrade = app pkgs "upgrade" [ jq gawk gnused gnugrep coreutils ];
      });

      # The apps, shellchecked as they are built, and an image evaluated
      # through every module -- building one needs a lock and root, which
      # a check has neither of.
      checks = forAllSystems (pkgs: self.packages.${pkgs.stdenv.hostPlatform.system} // {
        modules = pkgs.writeText "lock-input.json" (builtins.toJSON
          (self.lib.mkImage {
            modules = with self.raspiosModules; [ network ssh { name = "check"; } ];
          }).lockInput);
      });

      apps = forAllSystems (pkgs: lib.mapAttrs (_: p: {
        type = "app";
        program = lib.getExe p;
      }) self.packages.${pkgs.stdenv.hostPlatform.system});
    };
}
