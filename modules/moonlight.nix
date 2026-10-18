# A Moonlight client: a box that boots straight into moonlight-qt on the
# TV, streaming games from the machines that host them, with the Pi's
# hardware HEVC decode -- Raspberry Pi's FFmpeg -- doing the video.
#
# Moonlight runs as a user of its own, whose home -- its settings and
# pairings -- is on the persistent partition, so an upgrade keeps them.
# Pair it once on the box; or put a Moonlight.conf from one already paired
# on as it is flashed, with pairingFile, and a reflash needs no pairing
# again.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;
  cfg = config.moonlight;
  home = "home/${cfg.user}";
  owner = "${toString cfg.uid}:${toString cfg.uid}";
  confDir = "${home}/.config/Moonlight Game Streaming Project";
  # The kernel's HDMI-A-1 is Qt's HDMI1.
  qtOutput = lib.replaceStrings [ "HDMI-A-" ] [ "HDMI" ] cfg.display.connector;
in
{
  options.moonlight = {
    user = mkOption {
      type = types.str;
      default = "moonlight";
      description = "The user Moonlight runs as, with its home on the persistent partition.";
    };

    uid = mkOption {
      type = types.int;
      default = 1000;
      description = "Its uid and gid, which its files on the persistent partition are made for.";
    };

    pairingFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/moonlight-conf";
      description = ''
        A Moonlight.conf on the machine that flashes the card -- from a
        client already paired -- put in the user's home as it does: its
        client key and certificate, which the hosts know it by, and the
        hosts it knows. A path as a string, so that it is never copied into
        the Nix store; it is a secret.
      '';
    };

    display = {
      connector = mkOption {
        type = types.str;
        default = "HDMI-A-1";
        description = "The connector the TV is on, as the kernel names it.";
      };

      mode = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "1920x1080@60";
        description = ''
          The mode to drive it at, for Moonlight and the console alike.
          Unset, Qt takes the first mode the display offers that the Pi can
          drive, which on a 4K TV -- or a receiver in front of one -- is
          4K at 30Hz, since a Pi 4 cannot drive 4K60 by default.
        '';
      };
    };
  };

  config = {
    # moonlight-qt is not in Debian for arm64; its own repository builds it
    # against Raspberry Pi OS.
    sources.moonlight = {
      uri = "https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-qt/deb/raspbian";
      key = ../keys/moonlight-archive.asc;
    };

    # cec-utils: the TV's remote, over HDMI-CEC.
    packages = [ "moonlight-qt" "cec-utils" ];

    files = {
      "etc/systemd/system/moonlight.service" = pkgs.writeText "moonlight.service" ''
        [Unit]
        Description=Moonlight
        After=network-online.target
        Wants=network-online.target
        RequiresMountsFor=/${home}

        [Service]
        User=${cfg.user}
        # Qt aborts with no screen to draw on, which there is not until vc4
        # has found the TV: a few seconds into boot, or not until it is on.
        ExecStartPre=/bin/sh -c 'until grep -qx connected /sys/class/drm/card*-${cfg.display.connector}/status; do sleep 1; done'
        TimeoutStartSec=infinity
        ${lib.optionalString (cfg.display.mode != null) "Environment=QT_QPA_EGLFS_KMS_CONFIG=/etc/moonlight/kms.json"}
        ExecStart=/usr/bin/moonlight-qt
        Restart=always

        [Install]
        WantedBy=multi-user.target
      '';

      # Controllers: SDL reads them through hidraw, and Steam Input makes
      # virtual ones through uinput, both of which need the input group,
      # which Moonlight's user is in.
      "etc/udev/rules.d/56-game-controllers.rules" = pkgs.writeText "56-game-controllers.rules" ''
        KERNEL=="hidraw*", GROUP="input", MODE="0660"
        KERNEL=="uinput", GROUP="input", MODE="0660"
      '';
      "etc/modules-load.d/uinput.conf" = pkgs.writeText "uinput.conf" "uinput\n";
    } // lib.optionalAttrs (cfg.display.mode != null) {
      "etc/moonlight/kms.json" = pkgs.writeText "kms.json" (builtins.toJSON {
        device = "/dev/dri/card1";
        outputs = [ { name = qtOutput; mode = cfg.display.mode; } ];
      });
    };

    # The console's mode too, once the display has answered with what it
    # offers.
    cmdline = lib.optional (cfg.display.mode != null) "video=${cfg.display.connector}:${cfg.display.mode}";

    units = [ "moonlight" ];

    # An upgrade keeps a slot only if Moonlight comes up on it.
    healthChecks = [ "stays_up moonlight" ];

    persistent = {
      ${home} = { inherit owner; mode = "0750"; };
      "${home}/.config" = { inherit owner; };
      ${confDir} = { inherit owner; };
    } // lib.optionalAttrs (cfg.pairingFile != null) {
      "${confDir}/Moonlight.conf" = { inherit owner; source = cfg.pairingFile; mode = "0600"; };
    };

    customize = [
      ''
        chroot "$root" groupadd --gid ${toString cfg.uid} ${cfg.user}
        chroot "$root" useradd --uid ${toString cfg.uid} --gid ${toString cfg.uid} --no-create-home \
          --home-dir /${home} --shell /bin/bash \
          --groups video,render,input,audio,plugdev ${cfg.user}
      ''
    ];
  };
}
