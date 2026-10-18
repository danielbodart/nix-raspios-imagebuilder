# mkImage { pkgs, modules }: an image, from modules setting ../modules/core.nix's
# options. pkgs is the machine that builds it: aarch64-linux for
# builder = "sandbox", either for "vm".
#
# The derivation carries what the apps read: lockInput (the lock app),
# persistent (the flash app) and partuuid, besides config itself.
{ core }:

{ pkgs, modules, specialArgs ? { } }:

let
  inherit (pkgs) lib;

  config = (lib.evalModules {
    class = "raspios";
    specialArgs = { inherit pkgs; } // specialArgs;
    modules = [ core ] ++ modules;
  }).config;

  # A stable UUID from a name, so the same image always gets the same
  # partition UUIDs, which its cmdline.txt and fstab name, and an upgrade
  # finds its partitions by.
  uuid = seed:
    let h = builtins.hashString "sha256" "${config.name}:${seed}";
    in "${lib.substring 0 8 h}-${lib.substring 8 4 h}-4${lib.substring 13 3 h}-8${lib.substring 17 3 h}-${lib.substring 20 12 h}";
  partuuid = lib.genAttrs [ "bootconfig" "boot_a" "boot_b" "system_a" "system_b" "persistent" ] uuid;

  lockInput = {
    arch = "arm64";
    # Each key copied into the store under its own name: a path inside a
    # flake's source is not a file apt can read until it is.
    sources = map (s: s // {
      key = builtins.path { path = s.key; name = baseNameOf s.key; };
    }) (lib.attrValues config.sources);
    inherit (config) packages;
  };

  repo = import ./repo.nix { inherit pkgs config; };
  rootfs = import ./rootfs.nix { inherit pkgs config repo partuuid; };
in
# Its attributes are all lazy: lockInput is there to read before there is a
# lock to build from.
(import ./image.nix { inherit pkgs config rootfs partuuid uuid; }).overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit config lockInput partuuid repo rootfs;
    inherit (config) persistent;
  };
})
