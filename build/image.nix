# The image: the root from ./rootfs.nix laid out as an A/B disk for the
# Pi firmware's tryboot.
#
#   p1 bootconfig  FAT, autoboot.txt: which boot partition the firmware takes
#   p2 boot_a      FAT, firmware, kernel, initramfs, cmdline naming system_a
#   p3 boot_b      the same, naming system_b
#   p4 system_a    ext4, the root, mounted read-only under a RAM overlay
#   p5 system_b    the same
#   p6 persistent  ext4, what outlives a slot: /home, and what modules keep
#
# The disk image carries slot A with B left empty; the upgrade app writes
# the slot the box is not running from with boot-<slot>.vfat and
# system.ext4, tries it once with tryboot, and only then makes it the
# default. Nothing here needs root: mke2fs builds each ext4 from a tarball.
{ pkgs, config, rootfs, partuuid, uuid }:

let
  inherit (pkgs) lib;
  inherit (config) sizes;

  cmdline = slot: lib.concatStringsSep " " ([
    "console=tty1"
    "root=PARTUUID=${partuuid."system_${slot}"}"
    "rootfstype=ext4"
    "rootwait"
    "fsck.repair=yes"
    # A kernel that panics reboots, so a slot on trial falls back.
    "panic=10"
    # Every write lands in RAM: the slot stays exactly as built.
    "overlayroot=tmpfs:recurse=0"
  ] ++ config.cmdline);

  autoboot = pkgs.writeText "autoboot.txt" ''
    [all]
    tryboot_a_b=1
    boot_partition=2
    [tryboot]
    boot_partition=3
  '';
in
pkgs.runCommand "raspios-${config.name}" {
  nativeBuildInputs = with pkgs; [ e2fsprogs dosfstools mtools util-linux zstd jq ];
  # mke2fs reads the root's tarball through libarchive, which refuses a
  # name it cannot convert to the locale's charset: the sandbox's C is
  # ASCII, and Debian has UTF-8 names.
  LC_ALL = "C.UTF-8";
} ''
  mkdir boot
  cp -r --no-preserve=mode ${rootfs}/boot/. boot/
  for f in ${lib.escapeShellArgs config.bootFiles}; do
    [ -e boot/$f ] || { echo "boot partition has no $f" >&2; ls boot >&2; exit 1; }
  done
  cp ${pkgs.writeText "config.txt" config.configTxt} boot/config.txt

  mkdir -p $out

  vfat() { # <image> <MiB> <label> <dir>
    mkfs.vfat -C -n "$3" "$1" $(( $2 * 1024 )) > /dev/null
    mcopy -s -i "$1" "$4"/* ::/
  }
  for slot in a b; do
    rm -rf boot-$slot && cp -r boot boot-$slot
    case $slot in
      a) echo '${cmdline "a"}' > boot-$slot/cmdline.txt ;;
      b) echo '${cmdline "b"}' > boot-$slot/cmdline.txt ;;
    esac
    vfat boot-$slot.vfat ${toString sizes.boot} BOOT_''${slot^^} boot-$slot
  done
  mkdir bootconfig && cp ${autoboot} bootconfig/autoboot.txt
  vfat bootconfig.vfat 32 BOOTCONFIG bootconfig

  mkfs.ext4 -q -L system -d ${rootfs}/rootfs.tar system.ext4 ${toString sizes.system}M
  mkfs.ext4 -q -L persistent -d ${rootfs}/persistent.tar persistent.ext4 ${toString sizes.persistent}M

  # The disk: GPT, 1MiB aligned, slot B empty until the first upgrade.
  total=$(( 1 + 32 + 2 * ${toString sizes.boot} + 2 * ${toString sizes.system} + ${toString sizes.persistent} + 1 ))
  truncate -s ''${total}M disk.img
  sfdisk -q disk.img <<EOF
  label: gpt
  label-id: ${uuid "disk"}
  size=32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=bootconfig, uuid=${partuuid.bootconfig}
  size=${toString sizes.boot}MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=boot_a, uuid=${partuuid.boot_a}
  size=${toString sizes.boot}MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=boot_b, uuid=${partuuid.boot_b}
  size=${toString sizes.system}MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=system_a, uuid=${partuuid.system_a}
  size=${toString sizes.system}MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=system_b, uuid=${partuuid.system_b}
  size=${toString sizes.persistent}MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=persistent, uuid=${partuuid.persistent}
  EOF
  put() { # <partition number> <image>
    start=$(sfdisk -J disk.img | jq ".partitiontable.partitions[$(( $1 - 1 ))].start")
    dd if="$2" of=disk.img bs=512 seek=$start conv=notrunc,sparse status=none
  }
  put 1 bootconfig.vfat
  put 2 boot-a.vfat
  put 4 system.ext4
  put 6 persistent.ext4

  # Each is exactly its partition's size, so an upgrade checks what it
  # wrote by hashing the whole partition.
  sha256sum boot-a.vfat boot-b.vfat system.ext4 > $out/SHA256SUMS
  zstd -q -T0 -10 disk.img -o $out/disk.img.zst
  zstd -q -T0 -10 boot-a.vfat -o $out/boot-a.vfat.zst
  zstd -q -T0 -10 boot-b.vfat -o $out/boot-b.vfat.zst
  zstd -q -T0 -10 system.ext4 -o $out/system.ext4.zst
  echo '${builtins.toJSON partuuid}' > $out/partuuids.json
''
