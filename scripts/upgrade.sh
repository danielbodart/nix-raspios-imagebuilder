# Upgrade a running box to its image, over SSH as root -- the ssh module, or
# any sshd that lets root in by key:
#
#   nix run github:danielbodart/nix-raspios-imagebuilder#upgrade -- [--builder ssh-ng://host] [--host root@box] .#pi
#   ... .#pi rollback   back to the slot it ran before
#   ... .#pi commit     keep the slot it is on, tried into by hand
#
# The image is streamed into the slot the box is not running from, each
# partition then hashed against the build's. The box reboots into it with
# the firmware's tryboot, which takes that slot once: if it does not come
# up, with its health checks passing, the next boot is the old slot again.
# Only once it has is autoboot.txt rewritten to make it the default. The
# persistent partition is untouched.

trap 'echo "upgrade: failed at line $LINENO: $BASH_COMMAND" >&2' ERR
usage="usage: upgrade [--builder <ssh-ng://host>] [--host <user@box>] <flake>#<name> [upgrade|rollback|commit]"
target=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --builder) builder=${2:?$usage}; shift 2 ;;
    --host) target=${2:?$usage}; shift 2 ;;
    *) echo "$usage" >&2; exit 1 ;;
  esac
done
ref=${1:?$usage}
action=${2:-upgrade}
[[ $action == @(upgrade|rollback|commit) ]] || { echo "$usage" >&2; exit 1; }
attr=$(image_attr "$ref")
check_builder
host=$(nix eval --raw "$attr.config.name")
target=${target:-root@$host}

# Short timeouts: while the box reboots, a connection would otherwise wait
# minutes on a host that is not there.
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
remote() { ssh -n "${ssh_opts[@]}" "$target" "$@"; }

# The partition UUIDs are the box's name hashed, so every build's are the
# same and name the partitions already on its disk.
uuids=$(nix eval --json "$attr.partuuid")
uuid() { jq -r --arg p "$1" '.[$p]' <<< "$uuids"; }
dev() { echo "/dev/disk/by-partuuid/$(uuid "$1")"; }

running() { # the slot the box booted, from its root's PARTUUID
  local root
  root=$(remote cat /proc/cmdline | sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p')
  case $root in
    "$(uuid system_a)") echo a ;;
    "$(uuid system_b)") echo b ;;
    *) echo "$host's root, $root, is neither slot's" >&2; return 1 ;;
  esac
}
other() { [[ $1 == a ]] && echo b || echo a; }
partition() { [[ $1 == a ]] && echo 2 || echo 3; } # the boot partition's number, as autoboot.txt names it

# The firmware boots <default>, and <other> on a tryboot.
make_default() { # <slot>
  local slot=$1
  # Not remote, whose ssh -n would leave bash no script to read.
  ssh "${ssh_opts[@]}" "$target" bash -s -- "$(dev bootconfig)" "$(partition "$slot")" "$(partition "$(other "$slot")")" <<'EOF'
set -euo pipefail
mnt=$(mktemp -d)
mount "$1" "$mnt"
printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=%s\n' "$2" "$3" > "$mnt/autoboot.txt.new"
sync
mv "$mnt/autoboot.txt.new" "$mnt/autoboot.txt"
umount "$mnt"
rmdir "$mnt"
sync
EOF
  # Read back, so a write that did not happen does not pass for one: the
  # first boot_partition, [all]'s, is the default.
  remote "mount -o ro $(dev bootconfig) /mnt && grep -m1 ^boot_partition= /mnt/autoboot.txt | grep -qx boot_partition=$(partition "$slot"); s=\$?; umount /mnt; exit \$s" ||
    { echo "autoboot.txt does not boot slot $slot" >&2; return 1; }
}

booted=
reboot_into() { # <expected slot> [tryboot]
  local slot=$1 arg=${2:-}
  echo "Rebooting $host${arg:+ ($arg)}"
  # The firmware reads "0 tryboot" as: this once, the [tryboot] partition.
  # shellcheck disable=SC2016 # the single quotes are inside double ones
  remote "systemctl reboot${arg:+ --reboot-argument='0 $arg'}" || true
  # Down, then up again.
  while remote true 2>/dev/null; do sleep 2; done
  local tries=0
  until remote true 2>/dev/null; do
    sleep 5
    (( ++tries < 60 )) || { echo "$host has not come back after 5 minutes" >&2; return 1; }
  done
  booted=$(running)
  [[ $booted == "$slot" ]]
}

# Booted all the way -- degraded is a unit failing, which the image's own
# checks judge -- and the image's health checks passing.
healthy() {
  local state failed
  state=$(remote systemctl is-system-running --wait || true)
  failed=$(remote systemctl --failed --no-legend --plain | cut -d' ' -f1 | tr '\n' ' ')
  echo "  system $state${failed:+; failed: $failed}"
  [[ $state == running || $state == degraded ]] || return 1
  remote /usr/lib/raspios/health-check
}

current=$(running)
next=$(other "$current")

if [[ $action == commit ]]; then
  make_default "$current"
  echo "$host is on slot $current, now the default"
  exit 0
fi

if [[ $action == rollback ]]; then
  echo "$host is on slot $current; making slot $next the default"
  make_default "$next"
  reboot_into "$next" || { echo "$host came back on slot $booted, not $next" >&2; exit 1; }
  echo "$host is on slot $next"
  exit 0
fi

out=$(build_image "$attr")
echo "$host is on slot $current; writing $out to slot $next"
sums=$(image_cat "$out/SHA256SUMS")
write() { # <image> <partition>
  echo "  $1 -> $2"
  # shellcheck disable=SC2029 # the partition is named here, for the box
  image_cat "$out/$1.zst" |
    ssh "${ssh_opts[@]}" "$target" "zstd -dc | dd of=$(dev "$2") bs=4M iflag=fullblock oflag=direct conv=fsync status=progress"
  local want got
  want=$(awk -v f="$1" '$2 == f { print $1 }' <<< "$sums")
  got=$(remote sha256sum "$(dev "$2")" | cut -d' ' -f1)
  [[ $got == "$want" ]] || { echo "$2 does not hash to $1: $got, not $want" >&2; return 1; }
}
# The system first: a boot partition naming a half-written root is worse
# than an old one naming nothing new.
write system.ext4 "system_$next"
write "boot-$next.vfat" "boot_$next"

if ! reboot_into "$next" tryboot; then
  echo "$host came back on slot $booted: slot $next did not boot, so $current stays the default" >&2
  exit 1
fi
if ! healthy; then
  echo "Slot $next booted but is not healthy; back to slot $current" >&2
  reboot_into "$current" || true
  exit 1
fi
make_default "$next"
echo "$host is on slot $next, now the default; rollback goes back to slot $current"
