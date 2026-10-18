# What every image is: the options an image is described with, and what it
# needs to boot at all -- Debian and Raspberry Pi's archives, the kernel,
# firmware and initramfs, a read-only root under a RAM overlay, and the
# persistent partition. Raspberry Pi OS has no module system of its own --
# mmdebstrap takes a package list, a root it then changes, and nothing
# else -- so this is a small one in front of it.
#
# Nothing here is about what the image is for: no network, no SSH, no
# users. ./network.nix and ./ssh.nix are there to import, and anything
# else is a module of your own setting the same options.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkDefault types;

  file = types.coercedTo types.path (source: { inherit source; }) (types.submodule {
    options = {
      source = mkOption { type = types.path; };
      mode = mkOption { type = types.str; default = "0644"; };
    };
  });

  persistentEntry = types.submodule {
    options = {
      source = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          A file on the machine that flashes the card, copied onto it as it
          does -- a secret, say, under /run/secrets -- or null for a
          directory. A path as a string, so that it is never copied into
          the Nix store.
        '';
      };
      owner = mkOption { type = types.str; default = "0:0"; description = "uid:gid on the box."; };
      mode = mkOption { type = types.str; default = "0755"; };
    };
  };

  source = types.submodule {
    options = {
      uri = mkOption { type = types.str; };
      suite = mkOption { type = types.str; default = config.suite; };
      components = mkOption { type = types.listOf types.str; default = [ "main" ]; };
      key = mkOption { type = types.path; description = "The key its Release file is signed with."; };
    };
  };
in
{
  options = {
    name = mkOption {
      type = types.str;
      description = "The box's hostname, which also seeds its partition UUIDs and machine-id.";
    };

    suite = mkOption {
      type = types.str;
      default = "trixie";
      description = "The Debian and Raspberry Pi OS release.";
    };

    sources = mkOption {
      type = types.attrsOf source;
      description = "The apt repositories its packages are locked from.";
    };

    packages = mkOption {
      type = types.listOf types.str;
      description = "What is installed besides the Essential set and apt, without their Recommends.";
    };

    lock = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "The .debs the packages resolve to, as the lock app wrote them. Needed to build; not to lock.";
    };

    files = mkOption {
      type = types.attrsOf file;
      default = { };
      description = "Files installed into the root, by their path on the box, without the leading /.";
    };

    units = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "systemd units enabled in the root.";
    };

    customize = mkOption {
      type = types.listOf types.lines;
      default = [ ];
      description = ''
        Shell run as root against the finished root, which is $root, after
        files and units; chroot "$root" to run the box's own commands.
      '';
    };

    dpkgOptions = mkOption {
      type = types.listOf types.str;
      description = "dpkg options for every install, e.g. path-exclude=.";
    };

    timeZone = mkOption {
      type = types.str;
      default = "Etc/UTC";
    };

    kernelPackage = mkOption {
      type = types.str;
      default = "linux-image-rpi-v8";
      description = "The kernel: linux-image-rpi-v8 for a Pi 3, 4, 400, Zero 2 W or CM4; linux-image-rpi-2712 for a Pi 5.";
    };

    bootFiles = mkOption {
      type = types.listOf types.str;
      default = [ "kernel8.img" "initramfs8" "start4.elf" "fixup4.dat" "bcm2711-rpi-4-b.dtb" ];
      description = "What the boot partition must hold for the image to be built, as a check that the board's firmware and kernel are there.";
    };

    configTxt = mkOption {
      type = types.lines;
      description = "The firmware's config.txt.";
    };

    cmdline = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Kernel arguments beyond the root and overlay ones each slot is given.";
    };

    emergencyShell = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Give a keyboard at the box a root shell when a boot fails. Root has
        no password, so sulogin would otherwise refuse it, and a box that
        failed to boot leaves nothing to find out why with.
      '';
    };

    healthChecks = mkOption {
      type = types.listOf types.lines;
      default = [ ];
      example = [ "stays_up moonlight" ];
      description = ''
        Shell run on the box once a slot on trial has booted, each of which
        must succeed for the upgrade app to keep it; booting all the way is
        checked regardless. stays_up <unit> waits up to four minutes for a
        unit to be up -- or starting -- without restarting, for 20s.
      '';
    };

    persistent = mkOption {
      type = types.attrsOf persistentEntry;
      default = { };
      description = ''
        What the persistent partition starts with, by path under
        /persistent: its directories are in the image too, its files only
        on a card the flash app made, since they are secrets.
      '';
    };

    sizes = {
      boot = mkOption { type = types.int; default = 256; description = "Each boot partition, in MiB."; };
      system = mkOption { type = types.int; default = 4096; description = "Each system partition, in MiB."; };
      persistent = mkOption {
        type = types.int;
        default = 256;
        description = "The persistent partition in the image, in MiB; flashing grows it to the card.";
      };
    };

    builder = mkOption {
      type = types.enum [ "sandbox" "vm" ];
      default = "sandbox";
      description = ''
        How the root is installed, which runs its packages' scripts as root.
        sandbox: in the Nix sandbox, on an aarch64-linux builder with the
        uid-range system feature and filter-syscalls off; fast. vm: in a
        throwaway VM, on any Linux builder with KVM, the arm64 scripts under
        qemu-user on one that is not aarch64; slower, but needs nothing set.
      '';
    };
  };

  config = {
    sources = {
      debian = {
        uri = "https://deb.debian.org/debian";
        components = [ "main" "contrib" "non-free" "non-free-firmware" ];
        key = ../keys/debian-archive-13.asc;
      };
      debian-updates = {
        uri = "https://deb.debian.org/debian";
        suite = "${config.suite}-updates";
        components = [ "main" "contrib" "non-free" "non-free-firmware" ];
        key = ../keys/debian-archive-13.asc;
      };
      debian-security = {
        uri = "https://deb.debian.org/debian-security";
        suite = "${config.suite}-security";
        components = [ "main" "contrib" "non-free" "non-free-firmware" ];
        key = ../keys/debian-security-13.asc;
      };
      raspberrypi = {
        uri = "http://archive.raspberrypi.com/debian";
        key = ../keys/raspberrypi.asc;
      };
    };

    # What boots, and what the flash and upgrade apps run on the box: zstd
    # to unpack an upgrade, e2fsprogs to check the persistent partition.
    # busybox is only a Recommends of initramfs-tools, but without it the
    # initramfs has no grep, which overlayroot finds the overlay driver with.
    packages = lib.mkBefore [
      "systemd" "systemd-sysv" "udev" "dbus"
      config.kernelPackage "raspi-firmware" "initramfs-tools" "busybox" "overlayroot"
      "raspi-utils" "rpi-eeprom" "linux-sysctl-defaults" "ca-certificates"
      "login" "adduser" "procps" "zstd" "e2fsprogs"
    ];

    # No manuals, translations or docs, but the copyrights.
    dpkgOptions = mkDefault [
      "path-exclude=/usr/share/man/*"
      "path-exclude=/usr/share/locale/*"
      "path-include=/usr/share/locale/locale.alias"
      "path-exclude=/usr/share/doc/*"
      "path-include=/usr/share/doc/*/copyright"
      "path-exclude=/usr/share/info/*"
      "path-exclude=/usr/share/lintian/*"
    ];

    # Raspberry Pi OS's own.
    configTxt = lib.mkBefore ''
      arm_64bit=1
      auto_initramfs=1
      dtoverlay=vc4-kms-v3d
      max_framebuffers=2
      disable_fw_kms_setup=1
      disable_overscan=1
      arm_boost=1
    '';

    files = {
      "etc/hostname" = pkgs.writeText "hostname" "${config.name}\n";
      "etc/hosts" = pkgs.writeText "hosts" ''
        127.0.0.1 localhost
        127.0.1.1 ${config.name}
        ::1 localhost ip6-localhost ip6-loopback
      '';
      # A fixed machine-id, since the root is the same on every boot.
      "etc/machine-id" = pkgs.writeText "machine-id"
        "${lib.substring 0 32 (builtins.hashString "sha256" "machine-id:${config.name}")}\n";

      # What the upgrade app runs to decide whether to keep a slot it tried:
      # the slot's own, so a check is always the one the image came with.
      "usr/lib/raspios/health-check" = {
        mode = "0755";
        source = pkgs.writeText "health-check" ''
          #!/bin/bash
          set -euo pipefail

          stays_up() { # <unit>
            local i before after
            for i in $(seq 12); do
              before=$(systemctl show -P NRestarts "$1")
              sleep 20
              after=$(systemctl show -P NRestarts "$1")
              if [[ $before == "$after" && $(systemctl show -P ActiveState "$1") == @(active|activating) ]]; then
                echo "$1 up, after $after restarts"
                return 0
              fi
            done
            echo "$1 is not staying up" >&2
            return 1
          }

          ${lib.concatStringsSep "\n" config.healthChecks}
        '';
      };

      # The firmware's watchdog resets a box that stops answering, which is
      # what makes a hung slot on trial fall back.
      "etc/systemd/system.conf.d/watchdog.conf" = pkgs.writeText "watchdog.conf" ''
        [Manager]
        RuntimeWatchdogSec=15
      '';
    } // lib.optionalAttrs config.emergencyShell {
      "etc/systemd/system/emergency.service.d/sulogin.conf" = pkgs.writeText "sulogin.conf" ''
        [Service]
        Environment=SYSTEMD_SULOGIN_FORCE=1
      '';
      "etc/systemd/system/rescue.service.d/sulogin.conf" = pkgs.writeText "sulogin.conf" ''
        [Service]
        Environment=SYSTEMD_SULOGIN_FORCE=1
      '';
    };

    persistent.home = { };

    customize = lib.mkBefore [
      ''
        ln -sf /usr/share/zoneinfo/${config.timeZone} "$root/etc/localtime"
        echo ${config.timeZone} > "$root/etc/timezone"
      ''
    ];
  };
}
