#!/bin/bash
#
# Build the 64-bit U-Boot payload (TOC0 format, with ARM Trusted Firmware
# BL31 embedded) that gets installed into the eMMC.
# You do NOT need this if you use the prebuilt binary from the Releases page.
#
# Needs: gcc-aarch64-linux-gnu, openssl, plus the usual U-Boot build deps.
#
set -e

WORK="${WORK:-$PWD/build-uboot}"
mkdir -p "$WORK"
cd "$WORK"

# --- ARM Trusted Firmware -------------------------------------------------
# Pinned: unpinned master has broken this build before.
[ -d arm-trusted-firmware ] || git clone --depth 1 --branch v2.11.0 \
	https://github.com/ARM-software/arm-trusted-firmware.git
( cd arm-trusted-firmware && \
  make CROSS_COMPILE=aarch64-linux-gnu- PLAT=sun50i_h616 DEBUG=0 bl31 )
BL31="$WORK/arm-trusted-firmware/build/sun50i_h616/release/bl31.bin"

# --- U-Boot ---------------------------------------------------------------
# Pinned to the same tag the FEL SPL is built from, so both halves match.
[ -d u-boot ] || git clone --depth 1 --branch v2025.07 \
	https://github.com/u-boot/u-boot.git
cd u-boot

make tanix_tx1_defconfig

# TOC0 rather than the default eGON container. The BROM on this box rejects a
# plain eGON image written to the eMMC (it silently drops back to FEL), but
# accepts TOC0 - which is also what the stock Android bootloader uses.
./scripts/config --enable  SPL_IMAGE_TYPE_SUNXI_TOC0
./scripts/config --disable SPL_IMAGE_TYPE_SUNXI_EGON
yes "" | make oldconfig >/dev/null 2>&1

# TOC0 images are signed. The ROTPK_HASH eFuse on these boxes is blank
# (secure boot was never fused), so the BROM accepts ANY key - a throwaway
# self-signed one is fine and nothing is locked down by using it.
[ -f root_key.pem ] || openssl genrsa -out root_key.pem 2048

# binman looks for bl31.bin in the build root
cp "$BL31" bl31.bin

make -j"$(nproc)" CROSS_COMPILE=aarch64-linux-gnu-

head -c 8 u-boot-sunxi-with-spl.bin | grep -q 'TOC0.GLH' \
	|| { echo "ERROR: output is not a TOC0 image"; exit 1; }

# fel-install-uboot.sh looks for this name, so emit it rather than making the
# user work out that they have to rename it.
cp u-boot-sunxi-with-spl.bin u-boot-sunxi-with-spl-toc0.bin

echo
echo "built: $WORK/u-boot/u-boot-sunxi-with-spl-toc0.bin"
echo
# NOTE: the SPL below comes from build-installer-spl.sh, NOT from this tree.
# This tree is the 64-bit U-Boot; its spl/sunxi-spl.bin is aarch64 and cannot
# return to the 32-bit FEL BROM, which fails as usb_bulk_send() ERROR -7.
echo "install it with (run build-installer-spl.sh first if you have not):"
echo "  sudo ./fel-install-uboot.sh \\"
echo "       $(dirname "$WORK")/build-installer/u-boot/spl/sunxi-spl.bin \\"
echo "       $WORK/u-boot/u-boot-sunxi-with-spl-toc0.bin"
