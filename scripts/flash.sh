# Flash an image onto an SD card, or any removable disk, in this machine:
#
#   nix run github:danielbodart/nix-raspios-imagebuilder#flash -- [--builder ssh-ng://host] .#pi /dev/sdX
#
# The disk gets slot A, with slot B empty until the first upgrade. The
# persistent partition is then grown to the rest of the disk and made
# afresh with what the image's `persistent` names, its files -- secrets --
# copied from where they are on this machine.
#
# Everything that needs root is one sudo, so one password.

trap 'echo "flash: failed at line $LINENO: $BASH_COMMAND" >&2' ERR
usage="usage: flash [--builder <ssh-ng://host>] <flake>#<name> <disk, e.g. /dev/sda>"
while [[ ${1:-} == --* ]]; do
  case $1 in
    --builder) builder=${2:?$usage}; shift 2 ;;
    *) echo "$usage" >&2; exit 1 ;;
  esac
done
ref=${1:?$usage}
dev=${2:?$usage}
attr=$(image_attr "$ref")
name=${ref#*#}
check_builder

# The disk: whole, removable, and nothing on it mounted but by a desktop's
# automounter, which is unmounted before it is written.
[[ -b $dev && $(lsblk -dno TYPE "$dev") == disk ]] || { echo "$dev is not a disk" >&2; exit 1; }
[[ $(lsblk -dno RM "$dev" | tr -d ' ') == 1 ]] || { echo "$dev is not removable; refusing" >&2; exit 1; }
if lsblk -lno MOUNTPOINTS "$dev" | grep -v '^$' | grep -qv '^/run/media/'; then
  echo "$dev has something mounted outside /run/media; refusing" >&2
  exit 1
fi

# The persistent partition, a line a path: path, source or -, owner, mode;
# parents before what is in them.
spec=$(mktemp -p "${XDG_RUNTIME_DIR:-/tmp}" raspios-flash.XXXXXX)
trap 'rm -f "$spec"' EXIT
# shellcheck disable=SC2016 # ${...} here is Nix's
nix eval --raw "$attr.persistent" --apply 'p: builtins.concatStringsSep "" (map (k:
  let e = p.${k}; in "${k}\t${if e.source == null then "-" else e.source}\t${e.owner}\t${e.mode}\n"
) (builtins.attrNames p))' > "$spec"
while IFS=$'\t' read -r _ src _ _; do
  [[ $src == - || -r $src ]] || { echo "$src, for the persistent partition, is not readable" >&2; exit 1; }
done < "$spec"

out=$(build_image "$attr")

lsblk -o NAME,SIZE,MODEL,LABEL "$dev"
read -rp "Erase $dev and flash $name onto it? Type $dev to go on: " answer
[[ $answer == "$dev" ]] || { echo "Not flashed" >&2; exit 1; }

card() { # <device> <spec>; the image on stdin
  set -euo pipefail
  set -E
  trap 'echo "flash: failed at: $BASH_COMMAND" >&2' ERR
  dev=$1 spec=$2
  # findmnt fails for a partition with nothing mounted, which is most.
  unmount() {
    for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do
      { findmnt -rno TARGET -S "$p" || true; } | while read -r m; do umount "$m"; done
    done
  }

  unmount
  # Direct, past the page cache: its progress is the disk's own speed, not
  # RAM's followed by a long silent flush.
  dd of="$dev" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress

  # The backup GPT header to the end of the disk, and the persistent
  # partition, the last, to the rest of it. sfdisk notices first that the
  # table is the image's, for a smaller disk, which is what this mends.
  echo "Growing the persistent partition to the disk"
  sfdisk -q --relocate gpt-bak-std "$dev" \
    2> >(grep -v -e 'PMBR size mismatch' -e 'backup GPT table is not on the end' >&2 || true)
  echo ', +' | sfdisk -q --no-reread -N 6 "$dev"
  partx -u "$dev"
  udevadm settle
  part=$(lsblk -lnpo NAME,PARTN "$dev" | awk '$2 == 6 { print $1 }')

  echo "Putting its files on the persistent partition"
  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  while IFS=$'\t' read -r path src owner mode; do
    if [[ $src == - ]]; then
      install -d -m "$mode" "$root/$path"
    else
      install -m "$mode" "$src" "$root/$path"
    fi
    chown "$owner" "$root/$path"
  done < "$spec"
  unmount
  mkfs.ext4 -q -F -L persistent -d "$root" "$part"
  sync
  unmount
}

echo "Writing $name to $dev"
image_cat "$out/disk.img.zst" | zstd -dc |
  sudo env PATH="$PATH" bash -c "$(declare -f card); card \"\$@\"" card "$dev" "$spec"
lsblk -o NAME,SIZE,PARTLABEL,LABEL "$dev"
echo "$name is on $dev"
