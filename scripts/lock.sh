# Lock an image's packages: resolve what its modules ask for, plus the
# Essential set and apt, against its apt sources for arm64, and write every
# .deb that comes to, with its URL and SHA256, to <lock file> -- the only
# thing its image is built from. Run it again to take updates:
#
#   nix run github:danielbodart/nix-raspios-imagebuilder#lock -- .#pi raspios.lock.json
#
# apt checks every index against the keys the sources name, so the hashes
# are as trustworthy as those keys. The time it was taken is kept too:
# snapshot.debian.org still has a .deb under it once deb.debian.org does not.

usage="usage: lock <flake>#<name> <lock file>"
ref=${1:?$usage}
out=${2:?$usage}
attr=$(image_attr "$ref")

work=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" raspios-lock.XXXXXX)
trap 'rm -rf "$work"' EXIT

nix eval --json "$attr.lockInput" > "$work/input.json"
arch=$(jq -r .arch "$work/input.json")
snapshot=$(date -u +%Y%m%dT%H%M%SZ)

mkdir -p "$work"/etc/apt/{sources.list.d,preferences.d,apt.conf.d} \
         "$work"/var/lib/apt/lists/partial "$work"/var/cache/apt/archives/partial "$work"/var/lib/dpkg
touch "$work"/var/lib/dpkg/status
jq -r --arg arch "$arch" '.sources[] | "Types: deb\nURIs: \(.uri)\nSuites: \(.suite)\nComponents: \(.components | join(" "))\nSigned-By: \(.key)\nArchitectures: \($arch)\n"' \
  "$work/input.json" > "$work"/etc/apt/sources.list.d/lock.sources

# nixpkgs' apt has its directories compiled in, relative to Dir, so each is
# named here.
apt=(
  -o Dir="$work" -o Dir::Etc=etc/apt -o Dir::State=var/lib/apt -o Dir::Cache=var/cache/apt
  -o Dir::State::status="$work"/var/lib/dpkg/status
  -o APT::Architecture="$arch" -o APT::Architectures::="$arch"
  -o Acquire::Languages=none -o APT::Install-Recommends=false
  -o Debug::NoLocking=true
)
apt-get "${apt[@]}" -qq update >&2

# The Essential set, which apt takes as already there on a running system
# but which a root made from nothing installs like anything else.
mapfile -t essential < <(cat "$work"/var/lib/apt/lists/*_Packages | awk '/^Package:/{p=$2} /^Essential: yes/{print p}' | sort -u)
mapfile -t wanted < <(jq -r '.packages[]' "$work/input.json")

# apt prints each .deb's URL but only an MD5 for it; the SHA256 comes from
# the same signed index, found by the pool path the URL ends with.
cat "$work"/var/lib/apt/lists/*_Packages \
  | awk '/^Package:/{p=$2} /^Version:/{v=$2} /^Filename:/{f=$2} /^SHA256:/{s=$2}
         /^$/{ if (f) print f "\t" p "\t" v "\t" s; f="" }' > "$work/index.tsv"

apt-get "${apt[@]}" -qq --print-uris install "${essential[@]}" apt "${wanted[@]}" \
  | sed -E "s/^'([^']+)' [^ ]+ ([0-9]+) .*/\1\t\2/" > "$work/uris.tsv"

awk -F'\t' 'NR==FNR { idx[$1] = $2 "\t" $3 "\t" $4; next }
            { url = $1; path = url; sub(/^https?:\/\/[^\/]+\//, "", path)
              gsub(/%2[bB]/, "+", path); gsub(/%3[aA]/, ":", path); gsub(/%7[eE]/, "~", path)
              while (!(path in idx) && index(path, "/")) sub(/^[^\/]*\//, "", path)
              if (!(path in idx)) { print "no index entry for " url > "/dev/stderr"; exit 1 }
              print url "\t" $2 "\t" idx[path] }' "$work/index.tsv" "$work/uris.tsv" \
  | jq -Rn --arg snapshot "$snapshot" \
      '{snapshot: $snapshot,
        debs: [inputs | split("\t") | {name: .[2], version: .[3], url: .[0], size: (.[1] | tonumber), sha256: .[4]}]
              | sort_by(.name)}' \
  > "$out"

jq -r '"\(.debs | length) debs, \(.debs | map(.size) | add / 1048576 | floor) MiB, snapshot \(.snapshot)"' "$out"
