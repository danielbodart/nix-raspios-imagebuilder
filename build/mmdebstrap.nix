# mmdebstrap, which nixpkgs does not have, from Debian's own package: one
# Perl script, run here to install a Raspberry Pi OS root from the pinned
# .debs (./_image.nix).
{ lib, stdenvNoCC, fetchurl, dpkg, makeWrapper, perl, python3, apt, coreutils, util-linux, gnutar, gzip, zstd, findutils, gnugrep, gnused, diffutils, gnupg, glibc, linuxHeaders }:

stdenvNoCC.mkDerivation rec {
  pname = "mmdebstrap";
  version = "1.5.7-1+deb13u1";
  src = fetchurl {
    url = "https://deb.debian.org/debian/pool/main/m/mmdebstrap/mmdebstrap_${version}_all.deb";
    sha256 = "df731ee92b0ad40f9618b8b1c98c2e90635224f6b21c0905dab65ca099c8fe14";
  };
  nativeBuildInputs = [ dpkg makeWrapper perl ];
  unpackPhase = "dpkg-deb -x $src .";

  # It requires syscall.ph and sys/ioctl.ph, which Debian's perl ships and
  # nixpkgs' does not: made here from the C headers.
  buildPhase = ''
    mkdir inc
    cp -rL --no-preserve=mode ${glibc.dev}/include/. inc/
    cp -rL --no-preserve=mode ${linuxHeaders}/include/. inc/
    mkdir -p $out/lib/perl5
    (cd inc && h2ph -d $out/lib/perl5 -r -l . > /dev/null 2>&1 || true)
    perl -I$out/lib/perl5 -e 'require "syscall.ph"; require "sys/ioctl.ph"; &SYS_unshare; &TIOCGWINSZ'
  '';

  installPhase = ''
    install -Dm755 usr/bin/mmdebstrap $out/bin/mmdebstrap
    substituteInPlace $out/bin/mmdebstrap --replace-fail '#!/usr/bin/perl' '#!${perl}/bin/perl'
    # What it filters the packages' files through for --dpkgopt=path-exclude.
    install -Dm755 usr/bin/mmtarfilter $out/bin/mmtarfilter
    substituteInPlace $out/bin/mmtarfilter --replace-fail '#!/usr/bin/env python3' '#!${python3}/bin/python3'

    # nixpkgs' apt has its directories compiled in as store paths relative
    # to Dir, so once mmdebstrap points Dir at the chroot apt looks for its
    # config, and dpkg, under a store path in there: name Debian's own, and
    # the download methods where they are.
    substituteInPlace $out/bin/mmdebstrap --replace-fail \
      'print $conf "DPkg::Chroot-Directory \"$options->{root}\";\n";' \
      'print $conf "DPkg::Chroot-Directory \"$options->{root}\";\n";
    print $conf "Dir::Etc \"etc/apt\";\nDir::State \"var/lib/apt\";\nDir::Cache \"var/cache/apt\";\nDir::Log \"var/log/apt\";\n";
    print $conf "Dir::Bin \"usr/bin\";\nDir::Bin::methods \"${apt}/libexec/apt/methods\";\nDir::Bin::dpkg \"/usr/bin/dpkg\";\n";'

    # Without a dpkg status file nixpkgs' apt finds no packaging system, so
    # fails even the --version mmdebstrap probes it with; its real runs set
    # APT_CONFIG to the chroot's.
    printf 'Dir::State::status "/dev/null";\nDir::Bin::dpkg "${dpkg}/bin/dpkg";\n' > $out/lib/apt.conf

    # Debian's own directories last, for what runs inside the chroot.
    wrapProgram $out/bin/mmdebstrap \
      --set-default APT_CONFIG $out/lib/apt.conf \
      --prefix PERL5LIB : $out/lib/perl5 \
      --suffix PATH : /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      --prefix PATH : ${lib.makeBinPath [ apt dpkg perl python3 coreutils util-linux gnutar gzip zstd findutils gnugrep gnused diffutils gnupg ]}
  '';
}
