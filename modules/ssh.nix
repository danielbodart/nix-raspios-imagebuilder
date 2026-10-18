# OpenSSH, by key alone, for root. The host key is on the persistent
# partition, so it survives an upgrade: from ssh.hostKeyFile when the flash
# app writes the card, so it can be pinned in known_hosts beforehand, or
# made on the box's first boot otherwise.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;
  cfg = config.ssh;
in
{
  options.ssh = {
    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Public keys that may log in as root.";
    };

    hostKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/pi-host-key";
      description = ''
        An ed25519 private key on the machine that flashes the card, put on
        its persistent partition as the box's host key. A path as a string,
        so that it is never copied into the Nix store.
      '';
    };
  };

  config = {
    packages = [ "openssh-server" ];

    files = {
      "etc/ssh/sshd_config.d/10-keys-only.conf" = pkgs.writeText "10-keys-only.conf" ''
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin prohibit-password
        HostKey /persistent/ssh/ssh_host_ed25519_key
      '';
      # One made on first boot when the card came without one, before sshd's
      # own check of its config.
      "etc/systemd/system/ssh.service.d/host-key.conf" = pkgs.writeText "host-key.conf" ''
        [Unit]
        RequiresMountsFor=/persistent
        [Service]
        ExecStartPre=
        ExecStartPre=/bin/sh -c 'mkdir -p /persistent/ssh && { test -f /persistent/ssh/ssh_host_ed25519_key || ssh-keygen -q -t ed25519 -N "" -f /persistent/ssh/ssh_host_ed25519_key; }'
        ExecStartPre=/usr/sbin/sshd -t
      '';
      "root/.ssh/authorized_keys" = {
        source = pkgs.writeText "authorized_keys" (lib.concatMapStrings (k: "${k}\n") cfg.authorizedKeys);
        mode = "0600";
      };
    };

    units = [ "ssh" ];

    persistent = {
      ssh.mode = "0700";
    } // lib.optionalAttrs (cfg.hostKeyFile != null) {
      "ssh/ssh_host_ed25519_key" = { source = cfg.hostKeyFile; mode = "0600"; };
    };

    customize = [
      ''
        chmod 700 "$root/root/.ssh"
        rm -f "$root"/etc/ssh/ssh_host_*
      ''
    ];
  };
}
