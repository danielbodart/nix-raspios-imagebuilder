# What the apps share: an image named as <flake>#<name>, as nixos-rebuild
# names a system, is the flake's raspiosImages.<name>; and it is built here,
# or on $builder -- an ssh:// or ssh-ng:// store, e.g. an aarch64-linux
# machine for builder = "sandbox" -- and its files read from where it was.

builder=${RASPIOS_BUILDER:-}

image_attr() { # <flake>#<name>
  [[ $1 == *#?* ]] || { echo "expected <flake>#<name>, e.g. .#pi, not '$1'" >&2; exit 1; }
  echo "${1%%#*}#raspiosImages.${1#*#}"
}

builder_host() {
  local h=${builder#*://}
  echo "${h%%\?*}"
}

check_builder() {
  [[ -z $builder || $builder == ssh://* || $builder == ssh-ng://* ]] ||
    { echo "--builder takes an ssh:// or ssh-ng:// store, not '$builder'" >&2; exit 1; }
}

# The image's store path, built.
build_image() { # <attr>
  if [[ -n $builder ]]; then
    echo "Building $1 on $builder" >&2
    local out
    out=$(nix build --no-link --print-out-paths --eval-store auto --store "$builder" "$1" \
      2> >(grep -v "ignoring the client-specified setting 'store'" >&2))
    # Rooted there while it is read, and after: unrooted, a garbage
    # collection on the builder can take it from under a flash or upgrade
    # minutes in.
    # shellcheck disable=SC2029 # the path is named here, for the builder
    ssh -n "$(builder_host)" "mkdir -p ~/.cache/nix-raspios-imagebuilder && nix-store --realise --add-root ~/.cache/nix-raspios-imagebuilder/${1##*.} $out" > /dev/null
    echo "$out"
  else
    echo "Building $1" >&2
    nix build --no-link --print-out-paths "$1"
  fi
}

# A file of the built image, on stdout.
image_cat() { # <path>
  if [[ -n $builder ]]; then
    # -n: the caller's stdin may be the terminal a password is typed at.
    ssh -n "$(builder_host)" cat "$1"
  else
    cat "$1"
  fi
}
