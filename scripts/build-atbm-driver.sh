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
#   - ports it to Linux 7.1 (it was written for 4.9)
#   - fixes the W01-specific faults described in the README
#
# Needs: gcc-aarch64-linux-gnu, and the matching kernel headers/build tree.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/build-atbm}"
KHDR="${KHDR:-}"

if [ -z "$KHDR" ]; then
    cat <<'EOF'
Set KHDR to the kernel build tree that matches the box.

Take the linux-aarch64-headers package from the SAME MiniArch release as the
image you installed (the releases page lists it next to the SD-Image asset):

  https://github.com/warpme/miniarch/releases

  mkdir khdr && tar xf linux-aarch64-headers-<ver>-any.pkg.tar.* -C khdr
  KHDR=$PWD/khdr/usr/lib/modules/<ver>/build ./build-atbm-driver.sh

The module must be built against the exact kernel it will load into:
vermagic is checked at insmod time.
EOF
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
echo
echo "built: $WORK/atbm60xx/$KO"
echo "Install it as /lib/modules/\$(uname -r)/extramodules/atbm603x_wifi_sdio.ko"
