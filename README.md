# nix-raspios-imagebuilder

Build Raspberry Pi OS images in Nix derivations, from pinned `.deb`s, and
keep the boxes running them up to date with A/B upgrades over SSH.

Raspberry Pi OS rather than NixOS: the vendor kernel, firmware and patched
FFmpeg are Raspberry Pi's, and so is hardware video decode. This keeps
them, and makes the rest declarative — a module system in front of
[mmdebstrap](https://gitlab.mister-muffin.de/josch/mmdebstrap), in the
spirit of [nix-openwrt-imagebuilder](https://github.com/astro/nix-openwrt-imagebuilder).
Nothing is compiled: an image is Debian's and Raspberry Pi's own packages,
installed.

- **Locked.** An image is built from a lock file naming every `.deb` by URL
  and SHA256, resolved by apt against signed indexes. Rebuilding it next
  year gives the same root; `snapshot.debian.org` still has every package.
- **A/B.** The disk has two slots. An upgrade writes the one not running,
  boots it once with the firmware's
  [tryboot](https://www.raspberrypi.com/documentation/computers/config_txt.html#autoboot-txt),
  and keeps it only if it comes up healthy; otherwise the next boot is the
  old slot, untouched.
- **Read-only.** The root is mounted read-only under a RAM overlay, so a
  slot stays exactly as built. What must outlive it — `/home`, an SSH host
  key — is on a persistent partition.
- **Unopinionated.** The core is only what boots. Networking and SSH are
  modules to import; everything else is a module of your own.

## An image

```nix
{
  inputs.raspios.url = "github:danielbodart/nix-raspios-imagebuilder";

  outputs = { raspios, ... }: {
    raspiosImages.pi = raspios.lib.mkImage {
      modules = with raspios.raspiosModules; [
        network
        ssh
        {
          name = "pi";
          lock = ./raspios.lock.json;
          ssh.authorizedKeys = [ "ssh-ed25519 AAAA… you@laptop" ];
        }
      ];
    };
  };
}
```

```sh
nix run github:danielbodart/nix-raspios-imagebuilder#lock -- .#pi raspios.lock.json
nix build .#raspiosImages.pi
nix run github:danielbodart/nix-raspios-imagebuilder#flash -- .#pi /dev/sdX
```

Then, once it is running, after any change — or a re-lock, to take updates:

```sh
nix run github:danielbodart/nix-raspios-imagebuilder#upgrade -- .#pi
```

The apps name an image as `<flake>#<name>`, which is the flake's
`raspiosImages.<name>`, as `nixos-rebuild --flake .#host` names a system.

## Building

Installing a root runs its packages' maintainer scripts as root, which a
normal Nix build cannot. `builder` picks how an image gets root:

| `builder` | Builds on | Needs | Moonlight-sized image |
|---|---|---|---|
| `"sandbox"` (default) | aarch64-linux | `uid-range`, `filter-syscalls = false` | ~1 min |
| `"vm"` | any Linux with KVM | nothing | ~9 min on x86_64 |

**`sandbox`** installs in the Nix sandbox itself, given 65536 uids and root
inside it. The builder needs:

```nix
nix.settings = {
  experimental-features = [ "auto-allocate-uids" "cgroups" ];
  auto-allocate-uids = true;
  use-cgroups = true;
  system-features = [ "uid-range" ];  # alongside the rest
  # A root has setuid and setgid files, which the syscall filter refuses.
  filter-syscalls = false;
};
```

On a Mac, nixpkgs' `darwin.linux-builder` is such a machine, at native
speed on Apple silicon. Build there from anywhere with
`--builder ssh-ng://mac` on any of the apps.

**`vm`** installs inside a throwaway VM (nixpkgs' `vmTools`), as root, so
it needs nothing configured. Off aarch64 the root's programs run under a
static qemu-user, registered with binfmt inside the VM — slower, but any
x86_64 Linux machine with KVM will do:

```nix
raspios.lib.mkImage {
  system = "x86_64-linux";
  modules = [ … { builder = "vm"; } ];
}
```

Only installing the root needs root: the disk itself is laid out by an
ordinary build, `mke2fs` making each filesystem straight from a tarball.

## The disk

| # | Partition | |
|---|---|---|
| 1 | `bootconfig` | `autoboot.txt`: the default slot, and the one tryboot takes |
| 2 | `boot_a` | firmware, kernel, initramfs, `cmdline.txt` naming `system_a` |
| 3 | `boot_b` | the same, for slot B |
| 4 | `system_a` | the root, ext4, read-only under a RAM overlay |
| 5 | `system_b` | the same, for slot B |
| 6 | `persistent` | `/persistent`, and `/home` bound from it |

Partition UUIDs come from the image's `name`, so every build of an image
names the partitions already on its disk. The image file carries slot A;
slot B is written by the first upgrade. Flashing grows the persistent
partition to the disk.

## Options

From `modules/core.nix`, beside `name`, `lock` and `builder`:

| Option | |
|---|---|
| `packages` | Installed besides the Essential set and apt, without Recommends |
| `sources.<name>` | apt repositories: `uri`, `suite`, `components`, `key` |
| `files."<path>"` | Files in the root: a path, or `{ source; mode; }` |
| `units` | systemd units to enable |
| `customize` | Shell run as root against the root, `$root`; `chroot "$root"` for its own commands |
| `persistent."<path>"` | The persistent partition: directories, with `owner` and `mode`, and files `source`d from the flashing machine — secrets, never in the store |
| `healthChecks` | Shell run on a slot on trial; each must pass for an upgrade to keep it. `stays_up <unit>` waits for a unit to settle |
| `configTxt`, `cmdline` | The firmware's `config.txt`, and kernel arguments |
| `timeZone`, `suite`, `kernelPackage`, `bootFiles`, `sizes`, `dpkgOptions`, `emergencyShell` | |

## Modules

Each is opt-in: an image has only what it imports.

- **`network`**: DHCP on ethernet with systemd-networkd, -resolved and
  -timesyncd.
- **`ssh`**: OpenSSH for root by key, `ssh.authorizedKeys`, with its host
  key on the persistent partition — from `ssh.hostKeyFile` at flash time,
  so it can be pinned beforehand, or made on first boot. The upgrade app
  needs it, or another way in as root.
- **`moonlight`**: a [Moonlight](https://moonlight-stream.org) client that
  boots straight into Moonlight on the TV, with the Pi's hardware HEVC
  decode. Its settings and pairings live on the persistent partition, so
  upgrades keep them; `moonlight.pairingFile` puts a `Moonlight.conf` from
  an already paired client on at flash time, so even a reflash needs no
  pairing. `moonlight.display.mode` pins the mode, e.g. `"1920x1080@60"`:
  left alone, a Pi 4 on a 4K TV ends up at 4K30. Controllers work through
  hidraw and uinput; an upgrade keeps a slot only if Moonlight stays up on
  it.

```nix
modules = with raspios.raspiosModules; [
  network ssh moonlight
  {
    name = "tv";
    lock = ./raspios.lock.json;
    ssh.authorizedKeys = [ "ssh-ed25519 AAAA… you@laptop" ];
    moonlight.pairingFile = "/run/secrets/moonlight-conf";
    moonlight.display.mode = "1920x1080@60";
  }
];
```

## Writing a module

A module is any of the options above. A box that serves a directory over
HTTP, kept on the persistent partition:

```nix
{ pkgs, ... }:
{
  packages = [ "nginx" ];
  files."etc/nginx/sites-enabled/default" = pkgs.writeText "default" ''
    server { listen 80; root /persistent/www; }
  '';
  units = [ "nginx" ];
  persistent.www = { owner = "33:33"; };  # www-data
  healthChecks = [ "stays_up nginx" ];
}
```

`modules/moonlight.nix` is a fuller one: its own apt repository, a user,
options of its own, and a secret put on at flash time.

## Hardware

Built and run on a Raspberry Pi 4. The Pi 3, 400, Zero 2 W and CM4 take the
same kernel and firmware. A Pi 5 should need only
`kernelPackage = "linux-image-rpi-2712"` and its `bootFiles`, but is
untested. The bootloader must be recent enough for `autoboot.txt` with
tryboot — any Pi 4 EEPROM from 2023 on.

## License

MIT
