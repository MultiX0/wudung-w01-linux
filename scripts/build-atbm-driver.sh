#!/bin/bash
#
# Build the AltoBeam ATBM6031 WiFi driver for the W01's kernel.
#
#   KHDR=/path/to/kernel/build ./build-atbm-driver.sh
#
# You do NOT need this if you use the prebuilt .ko from the Releases page.
#
# The driver is gtxaspec/atbm60xx (a CW1200/"Apollo" derivative) plus
# patches/0003-atbm60xx-w01-wifi.patch, which does two jobs:
#   - ports it to Linux 7.2 (it was written for 4.9)
#   - fixes the W01-specific faults described in the README
#
# Needs: an aarch64 cross gcc 14 or newer, GNU make 4.3 or older, and the
# matching kernel headers/build tree. The script checks all three.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/build-atbm}"
KHDR="${KHDR:-}"

if [ -z "$KHDR" ]; then
    cat <<'EOF'
Set KHDR to the kernel build tree that matches the box.

The headers are NOT a release asset. MiniArch keeps its kernel packages in the
root of its git repo, which is the [miniarch] pacman repo the image itself uses
(see /etc/pacman-miniarch.conf on the box). Take the one whose version matches
the image you wrote:

  https://github.com/warpme/miniarch  ->  linux-aarch64-headers-<ver>-any.pkg.tar.gz

  curl -fLO https://github.com/warpme/miniarch/raw/refs/heads/master/linux-aarch64-headers-7.2.3-1-any.pkg.tar.gz
  mkdir khdr && tar xf linux-aarch64-headers-7.2.3-1-any.pkg.tar.gz -C khdr
  KHDR=$PWD/khdr/usr/lib/modules/7.2.3/build ./build-atbm-driver.sh

The module must be built against the exact kernel it will load into:
vermagic is checked at insmod time.
EOF
    exit 1
fi

[ -d "$KHDR" ] || { echo "KHDR=$KHDR is not a directory"; exit 1; }
KREL_FILE="$KHDR/include/config/kernel.release"
[ -f "$KREL_FILE" ] || {
    echo "$KHDR does not look like a kernel build tree"
    echo "(no include/config/kernel.release). Point KHDR at the 'build'"
    echo "directory inside the unpacked linux-aarch64-headers package."
    exit 1
}
KREL=$(tr -d '\n\r' < "$KREL_FILE")
echo "building against kernel $KREL"

# --- toolchain preflight ----------------------------------------------------
# Both of these fail in ways that look like the driver is broken rather than
# the build host, so check them here instead of letting the user decode a
# compiler error or a fork storm.

# 7.2 builds with -fmin-function-alignment, which gcc only understands from
# 14 onwards. gcc 13 dies with "unrecognized command-line option".
CC_BIN="${CROSS_COMPILE:-aarch64-linux-gnu-}gcc"
command -v "$CC_BIN" >/dev/null 2>&1 || {
    echo "$CC_BIN not found. Install the aarch64 cross compiler:"
    echo "  sudo apt install gcc-aarch64-linux-gnu      # gcc 14 or newer"
    exit 1
}
CC_MAJOR=$("$CC_BIN" -dumpversion 2>/dev/null | cut -d. -f1)
case "$KREL" in
    [7-9].*|[1-9][0-9].*) NEED_GCC=14 ;;
    *)                    NEED_GCC=0  ;;
esac
if [ -n "$CC_MAJOR" ] && [ "$CC_MAJOR" -lt "$NEED_GCC" ] 2>/dev/null; then
    echo
    echo "ERROR: $CC_BIN is gcc $CC_MAJOR, but kernel $KREL needs gcc $NEED_GCC or newer"
    echo "(it builds modules with -fmin-function-alignment, added in gcc 14)."
    echo
    echo "On Ubuntu 24.04 the default cross compiler is gcc 13. Install 14:"
    echo "  sudo apt install gcc-14-aarch64-linux-gnu"
    echo "  sudo ln -sf /usr/bin/aarch64-linux-gnu-gcc-14 /usr/local/bin/aarch64-linux-gnu-gcc"
    exit 1
fi

# GNU make 4.4 made the "export" directive apply to $(shell ...) too. The
# upstream atbm Makefile has a bare "export" plus a dozen "?= $(shell echo ...)"
# variables, and the combination makes make fork shells forever: no output, no
# object files, one core pinned. Catch it rather than letting it look like a
# hang.
MAKE_VER=$(make --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
MAKE_MAJOR=${MAKE_VER%%.*}
MAKE_MINOR=${MAKE_VER#*.}
if [ -n "$MAKE_MAJOR" ] && { [ "$MAKE_MAJOR" -gt 4 ] 2>/dev/null || \
   { [ "$MAKE_MAJOR" -eq 4 ] && [ "$MAKE_MINOR" -ge 4 ]; } 2>/dev/null; }; then
    echo
    echo "ERROR: GNU make $MAKE_VER cannot build this driver."
    echo
    echo "make 4.4 applies 'export' to \$(shell ...) as well, and the upstream"
    echo "atbm Makefile combines both. make then forks shells forever and the"
    echo "build never starts."
    echo
    echo "Build on a host with make 4.3 or older (Debian 12, Ubuntu 24.04),"
    echo "or install make 4.3 alongside and put it first on PATH."
    exit 1
fi

# Pinned. patches/0003 is a 1496-line diff generated against exactly this
# commit; one upstream change and it stops applying, with an error that looks
# like your setup is broken rather than that upstream moved.
ATBM_COMMIT=933a3bc2b3e1100ae00831b82132f8ae200a324d

mkdir -p "$WORK"; cd "$WORK"
[ -d atbm60xx ] || git clone https://github.com/gtxaspec/atbm60xx.git
cd atbm60xx
git fetch --all --quiet || true
git checkout --quiet "$ATBM_COMMIT" || {
    echo "could not check out $ATBM_COMMIT"; exit 1; }
git checkout -- . 2>/dev/null || true
git clean -fdq 2>/dev/null || true
git apply "$HERE/../patches/0003-atbm60xx-w01-wifi.patch"

make -j"$(nproc)" \
     KDIR="$KHDR" KSRC="$KHDR" KERNEL_SRC="$KHDR" \
     ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-

KO=hal_apollo/atbm603x_wifi_sdio.ko
[ -f "$KO" ] || { echo "build produced no module"; exit 1; }
echo
ls -l "$KO"
modinfo "$KO" | grep -E 'vermagic|name'

# A successful compile proves nothing about whether the module will load: the
# kernel refuses it unless vermagic matches exactly. Check it here, against the
# release the headers say they are, rather than letting the box find out.
KO_VER=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
if [ -z "$KO_VER" ]; then
    echo
    echo "WARNING: could not read vermagic (no modinfo?). Verify by hand:"
    echo "  modinfo -F vermagic $WORK/atbm60xx/$KO"
elif [ "$KO_VER" != "$KREL" ]; then
    echo
    echo "ERROR: built module reports kernel $KO_VER, headers say $KREL."
    echo "It would be rejected at insmod time. Check KHDR."
    exit 1
else
    echo
    echo "vermagic OK: module and headers both say $KREL"
fi

echo
echo "built: $WORK/atbm60xx/$KO"
echo "Install it as /lib/modules/$KREL/extramodules/atbm603x_wifi_sdio.ko"
