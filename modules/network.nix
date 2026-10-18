# Wired networking: DHCP on every ethernet port with systemd-networkd, DNS
# through systemd-resolved, and the clock from NTP with systemd-timesyncd
# -- a Pi has no battery-backed clock.
{ pkgs, ... }:

{
  packages = [ "systemd-resolved" "systemd-timesyncd" ];

  files."etc/systemd/network/10-wired.network" = pkgs.writeText "10-wired.network" ''
    [Match]
    Type=ether

    [Network]
    DHCP=yes
  '';

  units = [ "systemd-networkd" "systemd-resolved" "systemd-timesyncd" ];

  customize = [
    ''
      ln -sf /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
    ''
  ];
}
