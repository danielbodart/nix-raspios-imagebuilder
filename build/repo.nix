# The image's .debs, every one named by its lock, fetched and made into a
# local apt repository: all the root is installed from.
{ pkgs, config }:

let
  inherit (pkgs) lib;

  lock =
    if config.lock == null
    then throw "raspios ${config.name}: no lock; run the lock app, then set lock to the file it wrote"
    else lib.importJSON config.lock;

  # deb.debian.org keeps only the current point release; snapshot.debian.org
  # keeps everything, under the time the lock was taken.
  urlsFor = d:
    let m = builtins.match "https://deb.debian.org/(debian|debian-security)/(.*)" d.url;
    in [ d.url ] ++ lib.optional (m != null)
      "https://snapshot.debian.org/archive/${lib.elemAt m 0}/${lock.snapshot}/${lib.elemAt m 1}";

  debs = map (d: {
    file = "${d.name}_${lib.replaceStrings [ ":" ] [ "%3a" ] d.version}.deb";
    src = pkgs.fetchurl { urls = urlsFor d; inherit (d) sha256; };
  }) lock.debs;
in
# Copies, not links: apt-ftparchive names a link's target in Packages,
# which is no path under the repository.
pkgs.runCommand "raspios-${config.name}-debs" { nativeBuildInputs = [ pkgs.apt ]; } ''
  mkdir -p $out/pool
  ${lib.concatMapStrings (d: "cp ${d.src} $out/pool/'${d.file}'\n") debs}
  cd $out
  apt-ftparchive packages pool > Packages
  apt-ftparchive -o APT::FTPArchive::Release::Suite=${config.suite} \
    -o APT::FTPArchive::Release::Codename=${config.suite} release . > Release
''
