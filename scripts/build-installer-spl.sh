#!/bin/bash
#
# Build the 32-bit FEL installer SPL from source.
# You do NOT need this if you use the prebuilt binary from the Releases page.
#
# Needs: gcc-arm-linux-gnueabihf, plus the usual U-Boot build deps
#   sudo apt install gcc-arm-linux-gnueabihf bison flex libssl-dev bc \
#        device-tree-compiler swig python3-dev python3-pyelftools uuid-dev \
#        libgnutls28-dev pkg-config zlib1g-dev
#
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/build-installer}"
TAG=v2025.07

# The patches are against v2025.07. They do NOT apply to current master:
# arch/arm/mach-sunxi/Kconfig has drifted and board_init_f has moved, and
# because git apply is atomic you get *nothing* applied - which silently
# builds arm64 assembly with a 32-bit toolchain and thousands of
# "Error: ARM register expected".
mkdir -p "$WORK"
cd "$WORK"
[ -d u-boot ] || git clone --depth 1 --branch $TAG \
	https://github.com/u-boot/u-boot.git u-boot
cd u-boot

# Reset first so the script can be re-run. Without this a second run hits an
# already-patched tree, git apply fails, and set -e aborts with nothing saying
# that you simply need to start from a clean checkout.
git checkout -- . 2>/dev/null || true
git clean -fdq 2>/dev/null || true

git apply "$HERE/../patches/0001-apritzel-h616-32bit-build.patch"
git apply "$HERE/../patches/0002-fel-emmc-tool.patch"

make tanix_tx1_defconfig
./scripts/config --disable TOOLS_MKEFICAPSULE
./scripts/config --enable SPL_MMC_WRITE      # else mmc_bwrite() is a no-op stub
yes "" | make oldconfig >/dev/null 2>&1

make -j"$(nproc)" CROSS_COMPILE=arm-linux-gnueabihf- \
	spl/u-boot-spl.bin spl/sunxi-spl.bin

file spl/u-boot-spl | grep -q 'ELF 32-bit.*ARM' \
	|| { echo "ERROR: SPL is not 32-bit ARM - did patch 0001 apply?"; exit 1; }

echo
echo "built: $WORK/u-boot/spl/sunxi-spl.bin"
