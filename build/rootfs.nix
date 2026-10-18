# The root, installed by mmdebstrap from the image's local repository, and
# all of its building that needs root: maintainer scripts chown to system
# users, chroot and mknod. What comes out is plain files -- the root as a
# tarball, the firmware's boot files, and the persistent partition's
# directories as a tarball -- which ./image.nix lays out unprivileged.
#
# Root comes one of two ways (config.builder):
#
#   sandbox  the Nix sandbox itself, with uid-range: 65536 uids and root
#            inside it. On an aarch64-linux builder with uid-range in its
#            system-features (auto-allocate-uids, cgroups) and
#            filter-syscalls off, since a root has setuid and setgid files.
#   vm       a throwaway VM (nixpkgs' vmTools), on any Linux builder with
#            kvm. Off aarch64, the root's own programs run under qemu-user,
#            registered with binfmt_misc in the VM.
{ pkgs, config, repo, partuuid }:

let
  inherit (pkgs) lib;

  mmdebstrap = pkgs.callPackage ./mmdebstrap.nix { };
  native = pkgs.stdenv.hostPlatform.system == "aarch64-linux";

  customize = pkgs.writeShellScript "raspios-${config.name}-customize" ''
    set -euo pipefail
    root=$1
    ${lib.concatStrings (lib.mapAttrsToList (dest: f: ''
      install -D -m ${f.mode} ${f.source} "$root/${dest}"
    '') config.files)}
    ${lib.concatMapStrings (u: ''
      chroot "$root" systemctl enable ${u}
    '') config.units}
    ${lib.concatStringsSep "\n" config.customize}
  '';

  fstab = pkgs.writeText "fstab" ''
    PARTUUID=${partuuid.persistent} /persistent ext4 defaults,noatime 0 2
    /persistent/home /home none bind,x-systemd.requires-mounts-for=/persistent 0 0
  '';

  # What only the image's layout differs in, taken out of the root: the
  # firmware's boot files, which go to their own partition, and the
  # persistent partition's directories, with their owners.
  finish = pkgs.writeShellScript "raspios-${config.name}-finish" ''
    set -euo pipefail
    root=$1 out=$2
    install -m 644 ${fstab} "$root/etc/fstab"
    mkdir -p "$root/persistent"

    mkdir -p "$out/boot"
    cp -r --no-preserve=ownership "$root/boot/firmware/." "$out/boot/"
    find "$root/boot/firmware" -mindepth 1 -delete

    persistent=$(mktemp -d)
    ${lib.concatStrings (lib.mapAttrsToList (path: e: lib.optionalString (e.source == null) ''
      install -d -m ${e.mode} "$persistent"/${lib.escapeShellArg path}
      chown ${e.owner} "$persistent"/${lib.escapeShellArg path}
    '') config.persistent)}
    tar --numeric-owner -C "$persistent" -cf "$out/persistent.tar" .
    rm -rf "$persistent"
  '';

  install = ''
    mkdir -p $out
    mmdebstrap --mode=root --variant=apt --architectures=arm64 \
      --aptopt='APT::Install-Recommends "false"' \
      ${lib.concatMapStringsSep " " (o: "--dpkgopt=${lib.escapeShellArg o}") config.dpkgOptions} \
      --include=${lib.concatStringsSep "," config.packages} \
      --customize-hook='${customize} "$1"' \
      --customize-hook='${finish} "$1" '"$out" \
      --skip=cleanup/reproducible/machine-id ${lib.optionalString (!native) "--skip=check/qemu"} \
      ${config.suite} $out/rootfs.tar "deb [trusted=yes] copy://${repo} ./"
  '';

  # Static, and registered with binfmt's F flag, which opens it there and
  # then: the chroot needs nothing of the store to run the root's arm64
  # programs. A dynamic one would need the store in the chroot, where
  # mmdebstrap's PATH would then find nixpkgs' own tools ahead of Debian's.
  qemu = "${pkgs.pkgsStatic.qemu-user}/bin/qemu-aarch64";
  # The ELF header of an aarch64 executable, and which of its bytes count.
  aarch64Magic = ''\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'';
  aarch64Mask = ''\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';

  name = "raspios-${config.name}-rootfs";
in
if config.builder == "sandbox" then
  assert lib.assertMsg native
    "raspios ${config.name}: builder = \"sandbox\" builds on aarch64-linux; pass mkImage an aarch64-linux pkgs, or set builder = \"vm\"";
  pkgs.runCommand name {
    nativeBuildInputs = [ mmdebstrap ];
    requiredSystemFeatures = [ "uid-range" ];
  } install
else
  pkgs.vmTools.runInLinuxVM (pkgs.runCommand name {
    nativeBuildInputs = [ mmdebstrap pkgs.util-linux ];
    # The root is built in the VM's RAM.
    memSize = 4096;
  } ''
    ${lib.optionalString (!native) ''
      mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
      printf '%s' ':qemu-aarch64:M::${aarch64Magic}:${aarch64Mask}:${qemu}:F' \
        > /proc/sys/fs/binfmt_misc/register
    ''}
    export TMPDIR=/tmp
    ${install}
  '')
