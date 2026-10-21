#!/bin/sh
# Build the aarch64 release tarball from the Debian packages the aarch64 CI builds.
#
# WHAT THIS SHIPS. aarch64 can't have a Winelib tarball like the x86_64 release (make-release.sh):
# vstbridge there needs its own Wine, built for ARM64EC with FEX. So the aarch64 release is the
# four packages ../aarch64/build-debs.sh makes, with an installer, an uninstaller, a README and
# their checksums:
#
#     wine-fex        Wine with FEX in /opt/vstbridge/wine; wine and its programs in /usr/bin
#     wine-fex-i386   Wine's 32-bit Windows side
#     wine-fex-mono   the wine-mono installer
#     vstbridge       the plugin libraries and host, vstbridgectl and vstbridgectl-gtk
#
# WHERE THE PACKAGES COME FROM. The "pivuan-debs" artifact of a run of the aarch64 build workflow
# (rations/pivuan's "vstbridge for Pivuan" runs it), which also installs and runs them in a clean
# Debian trixie container. Download the artifact and pass the zip, or a directory with the .debs:
#
#     ./make-arm-release.sh ~/Downloads/pivuan-debs.zip
#
# HOW IT IS INSTALLED. The archive unpacks into vstbridge-<version>-aarch64/ and installs
# system-wide through apt, which also installs the libraries the packages depend on:
#
#     tar -xf vstbridge-<version>-aarch64.tar
#     cd vstbridge-<version>-aarch64
#     ./install.sh
#
# WHERE IT RUNS. arm64 Debian 13 "trixie" and systems built on it (Devuan excalibur, Raspberry Pi
# OS trixie): the packages depend on trixie's library packages. wine-fex conflicts with Debian's
# wine, since both install /usr/bin/wine; apt shows the removal and asks first.
#
# THE VERSION is the git tag, as in make-release.sh (v0.0.3 gives 0.0.3), or --version. The
# packages carry their own versions, which this prints and the README lists, so check that the
# artifact was built from the code the version names.
#
# The archive is a plain tar: the .debs are already compressed. Member order, owners, modes and
# mtimes are normalised, as in make-release.sh.
#
# POSIX sh, with GNU tar and coreutils, dpkg-deb, and unzip for a zip.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$root/.." && pwd)
outdir=$root/dist
version=
input=

usage() {
    cat <<USAGE
usage: make-arm-release.sh [--out DIR] [--version VERSION] <pivuan-debs.zip | directory>

  --out DIR          where to write the tarball (default: dist/)
  --version VERSION  the release version (default: from 'git describe', v0.0.3 -> 0.0.3)

Packages the four aarch64 .debs (wine-fex, wine-fex-i386, wine-fex-mono and
vstbridge) with install.sh and uninstall.sh as vstbridge-<version>-aarch64.tar,
with a .sha256 next to it.
USAGE
}

while [ $# -gt 0 ]; do
    case $1 in
        --out) outdir=$2; shift 2 ;;
        --out=*) outdir=${1#--out=}; shift ;;
        --version) version=$2; shift 2 ;;
        --version=*) version=${1#--version=}; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) printf 'make-arm-release.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *) [ -z "$input" ] || { usage >&2; exit 2; }; input=$1; shift ;;
    esac
done
[ -n "$input" ] || { usage >&2; exit 2; }

die() { printf 'make-arm-release.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

for tool in dpkg-deb dpkg sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
tar --version 2>/dev/null | head -1 | grep -q 'GNU tar' || die "GNU tar is required"

# ---------------------------------------------------------------------------------------------
# Version.
# ---------------------------------------------------------------------------------------------
if [ -z "$version" ]; then
    describe=$(git -C "$repo" describe --tags --match 'v[0-9]*' 2>/dev/null) ||
        die "no v<version> tag is reachable from HEAD; pass --version"
    version=${describe#v}
fi
case $version in
    *[!A-Za-z0-9.+~_-]*|'') die "not a usable version: $version" ;;
esac
name=vstbridge-$version-aarch64

printf '\n%s %s\n\n' "Building release tarball for" "$name"

stage=$(mktemp -d "${TMPDIR:-/tmp}/vstbridge-arm-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
out=$stage/$name
mkdir "$out"

# ---------------------------------------------------------------------------------------------
# The packages. A zip has to hold only .deb files, with no directories in their names.
# ---------------------------------------------------------------------------------------------
printf 'Reading the packages\n'
debs=$stage/debs
mkdir "$debs"
if [ -d "$input" ]; then
    for deb in "$input"/*.deb; do
        [ -e "$deb" ] || die "no .deb files in $input"
        cp "$deb" "$debs/"
    done
elif [ -f "$input" ]; then
    command -v unzip >/dev/null 2>&1 || die "unzip is required to read $input"
    unzip -Z1 "$input" > "$stage/zip-list" || die "$input is not a zip file"
    if grep -v -E '^[A-Za-z0-9.+~_-]+\.deb$' "$stage/zip-list" > "$stage/zip-other"; then
        die "$input holds more than .deb files:
$(sed 's/^/  /' "$stage/zip-other")"
    fi
    unzip -q "$input" -d "$debs"
else
    die "no such file or directory: $input"
fi

# 1. Exactly vstbridge's four packages, once each, for arm64 (the Mono installer is for all)
wine_fex= wine_fex_i386= wine_fex_mono= vstbridge=
for deb in "$debs"/*.deb; do
    [ -e "$deb" ] || die "no .deb files in $input"
    pkg=$(dpkg-deb -f "$deb" Package) || die "$(basename "$deb") is not a Debian package"
    arch=$(dpkg-deb -f "$deb" Architecture)
    case $pkg:$arch in
        wine-fex:arm64) var=wine_fex ;;
        wine-fex-i386:arm64) var=wine_fex_i386 ;;
        wine-fex-mono:all) var=wine_fex_mono ;;
        vstbridge:arm64) var=vstbridge ;;
        *) die "$(basename "$deb"): $pkg ($arch) is not one of vstbridge's aarch64 packages" ;;
    esac
    eval "[ -z \"\$$var\" ]" || die "more than one $pkg package"
    eval "$var=\$deb"
    # Reading the whole archive catches a truncated download
    dpkg-deb --contents "$deb" >/dev/null || die "$(basename "$deb") is damaged"
done
for var in wine_fex wine_fex_i386 wine_fex_mono vstbridge; do
    eval "[ -n \"\$$var\" ]" || die "the $(printf '%s' "$var" | tr _ -) package is missing"
done

version_of() { dpkg-deb -f "$1" Version; }
depends_of() { dpkg-deb -f "$1" Depends | tr ',' '\n' | sed 's/^ *//'; }

# 2. They belong together: wine-fex wants exactly these i386 and Mono packages, and vstbridge a
#    wine-fex at least this old
depends_of "$wine_fex" | grep -qxF "wine-fex-i386 (= $(version_of "$wine_fex_i386"))" ||
    die "wine-fex $(version_of "$wine_fex") needs a different wine-fex-i386 than $(version_of "$wine_fex_i386")"
depends_of "$wine_fex" | grep -qxF "wine-fex-mono (= $(version_of "$wine_fex_mono"))" ||
    die "wine-fex $(version_of "$wine_fex") needs a different wine-fex-mono than $(version_of "$wine_fex_mono")"
need=$(depends_of "$vstbridge" | sed -n 's/^wine-fex (>= \(.*\))$/\1/p')
[ -n "$need" ] || die "vstbridge does not depend on a wine-fex version"
dpkg --compare-versions "$(version_of "$wine_fex")" ge "$need" ||
    die "vstbridge needs wine-fex >= $need, and the wine-fex package is $(version_of "$wine_fex")"
for var in vstbridge wine_fex wine_fex_i386 wine_fex_mono; do
    eval "deb=\$$var"
    say "$(basename "$deb") ($(du -h "$deb" | cut -f1))"
    cp "$deb" "$out/"
done
say "the four packages are there, for arm64, and their versions fit together"

# ---------------------------------------------------------------------------------------------
# install.sh, uninstall.sh, README.txt and SHA256SUMS.
# ---------------------------------------------------------------------------------------------
printf 'Writing the installer\n'

cat > "$out/install.sh" <<'INSTALL'
#!/bin/sh
# Installs vstbridge and its Wine (wine-fex, which runs the x86 code of Windows plugins with FEX)
# from the Debian packages in this directory, through apt, which also installs the libraries
# they need. For 64-bit Arm (arm64) systems based on Debian 13 "trixie".
#
#     ./install.sh
#
# ./uninstall.sh removes them again.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    die "this needs a Debian-based system (apt and dpkg)"
fi
arch=$(dpkg --print-architecture)
[ "$arch" = arm64 ] || die "these packages are for 64-bit Arm (arm64), and this system is $arch"

# The packages depend on trixie's libraries. Elsewhere apt may not find them, and says so.
codename=
if [ -r /etc/os-release ]; then
    codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
fi
case $codename in
    trixie|excalibur) ;;
    *) printf 'Note: these packages are built for Debian 13 "trixie" and systems based on it.\n'
       printf 'On %s, apt may not find the libraries they need.\n\n' "${codename:-this system}" ;;
esac

(cd "$here" && sha256sum --quiet -c SHA256SUMS) ||
    die "the packages don't match SHA256SUMS; download the release again"

set --
for pkg in wine-fex-mono wine-fex-i386 wine-fex vstbridge; do
    for deb in "$here/${pkg}_"*.deb; do
        [ -e "$deb" ] || die "${pkg}_*.deb is missing from $here"
        set -- "$@" "$deb"
    done
done

if [ "$(id -u)" -eq 0 ]; then
    as_root=
elif command -v sudo >/dev/null 2>&1; then
    as_root=sudo
else
    die "run this as root: sudo isn't installed"
fi

# Debian's wine and WineHQ's packages install /usr/bin/wine too
others=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' \
             wine wine64 wine32 winehq-stable winehq-staging winehq-devel 2>/dev/null |
         awk '$1 ~ /^.i/ { print $2 }' | sort -u | tr '\n' ' ')
if [ -n "$others" ]; then
    printf 'Note: wine-fex replaces the Wine that is installed (%s), because both install\n' "${others% }"
    printf '/usr/bin/wine. apt lists it for removal below and asks first.\n\n'
fi

# A fresh package index, so apt finds the current versions of the libraries
$as_root apt-get update
$as_root apt-get install "$@"

cat <<DONE

vstbridge is installed.

  1. Install your Windows plugins with Wine:  wine PluginInstaller.exe
  2. Open vstbridgectl from the menu (Audio), or in a terminal:
       vstbridgectl add "\$HOME/.wine/drive_c/Program Files/Common Files/VST3"
       vstbridgectl sync
  3. Rescan the plugins in your audio program. The bridged plugins are in
     ~/.vst3/vstbridge, ~/.vst/vstbridge and ~/.clap/vstbridge.

Wine uses the default prefix, ~/.wine: keep your plugins there.
DONE
INSTALL

cat > "$out/uninstall.sh" <<'UNINSTALL'
#!/bin/sh
# Removes the packages install.sh installed: vstbridge, wine-fex, wine-fex-i386, wine-fex-mono.

set -eu

die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }

command -v apt-get >/dev/null 2>&1 || die "apt-get is not installed"

installed=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' \
                vstbridge wine-fex wine-fex-i386 wine-fex-mono 2>/dev/null |
            awk '$1 ~ /^.i/ { print $2 }' | tr '\n' ' ')
if [ -z "$installed" ]; then
    echo "vstbridge and wine-fex are not installed."
    exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
    as_root=
elif command -v sudo >/dev/null 2>&1; then
    as_root=sudo
else
    die "run this as root: sudo isn't installed"
fi

# $installed is package names, split on purpose
# shellcheck disable=SC2086
$as_root apt-get remove $installed

cat <<DONE

vstbridge and wine-fex are removed. These are kept:
  ~/.wine                  the Wine prefix, with your Windows plugins
  ~/.config/vstbridgectl   vstbridgectl's settings
  ~/.vst3/vstbridge, ~/.vst/vstbridge, ~/.clap/vstbridge
                           the bridged plugins, which don't load without vstbridge;
                           delete them if you're not reinstalling it
DONE
UNINSTALL

cat > "$out/README.txt" <<README
vstbridge $version for 64-bit Arm (aarch64)

Windows VST2, VST3 and CLAP plugins in Linux audio programs, on 64-bit Arm such as the
Raspberry Pi 5. Wine runs natively and FEX runs the plugins' x86 code.

Packages:
  $(basename "$vstbridge")
  $(basename "$wine_fex")
  $(basename "$wine_fex_i386")
  $(basename "$wine_fex_mono")

Needs an arm64 system running Debian 13 "trixie" or a system based on it (Devuan excalibur,
Raspberry Pi OS trixie), and sudo. It doesn't run on x86_64 PCs: use the x86_64 release there.

Install:
  ./install.sh

It checks the packages against SHA256SUMS and installs them with apt, which also installs the
libraries they need. wine-fex replaces Debian's or WineHQ's wine, since both install
/usr/bin/wine; if one is installed, apt lists it for removal and asks first.

Then:
  1. Install your Windows plugins with Wine:  wine PluginInstaller.exe
  2. Open vstbridgectl from the menu (Audio), or in a terminal:
       vstbridgectl add "\$HOME/.wine/drive_c/Program Files/Common Files/VST3"
       vstbridgectl sync
  3. Rescan the plugins in your audio program. The bridged plugins are in
     ~/.vst3/vstbridge, ~/.vst/vstbridge and ~/.clap/vstbridge.

Wine uses the default prefix, ~/.wine: keep your plugins there.

Uninstall:
  ./uninstall.sh

https://github.com/rations/vstbridge
README

(cd "$out" && sha256sum -- *.deb > SHA256SUMS)

# 3. The scripts parse
for f in install.sh uninstall.sh; do
    sh -n "$out/$f" || die "the generated $f doesn't parse"
done
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s sh "$out/install.sh" "$out/uninstall.sh" || die "shellcheck found problems in the scripts"
    say "install.sh and uninstall.sh parse and pass shellcheck"
else
    say "install.sh and uninstall.sh parse (shellcheck isn't installed)"
fi

# ---------------------------------------------------------------------------------------------
# Archive.
# ---------------------------------------------------------------------------------------------
printf 'Archiving\n'
find "$out" -type d -exec chmod 755 {} +
find "$out" -type f -exec chmod 644 {} +
chmod 755 "$out/install.sh" "$out/uninstall.sh"

if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    epoch=$SOURCE_DATE_EPOCH
else
    epoch=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || date +%s)
fi
find "$out" -exec touch -d "@$epoch" {} +

mkdir -p "$outdir"
outdir=$(CDPATH= cd -- "$outdir" && pwd)
tar -C "$stage" \
    --format=ustar \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@$epoch" \
    -cf "$outdir/$name.tar" "$name"
( cd "$outdir" && sha256sum "$name.tar" > "$name.sha256" )
say "$outdir/$name.tar ($(du -h "$outdir/$name.tar" | cut -f1))"
say "$outdir/$name.sha256"

# ---------------------------------------------------------------------------------------------
# Verify what was written: one directory, exactly the staged files, and the checksums hold.
# ---------------------------------------------------------------------------------------------
printf 'Verifying the written archive\n'
( cd "$out" && find . -type f | sed 's|^\./||' | sort ) > "$stage/expected"
check=$stage/check
mkdir "$check"
tar -C "$check" -xf "$outdir/$name.tar"
[ "$(ls "$check")" = "$name" ] || die "the archive does not unpack into a single $name/ directory"
( cd "$check/$name" && find . -type f | sed 's|^\./||' | sort ) > "$stage/unpacked"
cmp -s "$stage/expected" "$stage/unpacked" || die "the written archive does not hold the staged files"
( cd "$check/$name" && sha256sum --quiet -c SHA256SUMS ) || die "the unpacked packages don't match SHA256SUMS"
[ -x "$check/$name/install.sh" ] || die "install.sh is not executable in the archive"
say "unpacks into $name/ with $(wc -l < "$stage/unpacked") files, and SHA256SUMS holds"

printf '\n%s\n\n' "vstbridge $version (aarch64) is in $outdir."
printf 'Packages:\n'
for var in vstbridge wine_fex wine_fex_i386 wine_fex_mono; do
    eval "deb=\$$var"
    printf '  %s %s\n' "$(dpkg-deb -f "$deb" Package)" "$(version_of "$deb")"
done
printf '\nInstall with:\n  tar -xf %s.tar && cd %s && ./install.sh\n\n' "$name" "$name"
