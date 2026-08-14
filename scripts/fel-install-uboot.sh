#!/bin/bash
#
# Install a 64-bit U-Boot into the box's eMMC over USB FEL.
#
# Usage:  sudo ./fel-install-uboot.sh [installer-spl] [uboot-payload]
#
# sudo is required: under WSL2 the FEL device is root-owned.
#
# Defaults to the prebuilt binaries shipped in ../prebuilt.
# The box must be in FEL mode (see the README) and reachable by sunxi-fel.
#
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SPL="${1:-$HERE/../prebuilt/sunxi-spl-fel-installer.bin}"
PAYLOAD="${2:-$HERE/../prebuilt/u-boot-sunxi-with-spl-toc0.bin}"
FEL="${FEL:-sunxi-fel}"

SRC_ADDR=0x50000000
NSECT_ADDR=0x40100
LBA_ADDR=0x40104
MODE_ADDR=0x40108
STATUS_ADDR=0x40000
TARGET_LBA=16          # Allwinner BROM boot offset, 8 KiB in

[ -f "$SPL" ]     || { echo "missing installer SPL: $SPL"; exit 1; }
[ -f "$PAYLOAD" ] || { echo "missing payload: $PAYLOAD"; exit 1; }

BYTES=$(stat -c %s "$PAYLOAD")
SECTORS=$(( (BYTES + 511) / 512 ))

echo "payload : $PAYLOAD"
echo "size    : $BYTES bytes ($SECTORS sectors)"
echo

echo "==> checking FEL"
$FEL ver

# The SPL reads three words out of SRAM: sector count, target LBA, and mode.
# SRAM survives between sunxi-fel runs for as long as the box has power, so
# values left behind by a previous tool run (fel-emmc.py, for instance) would
# still be there. Set all three explicitly every time, or a stale LBA would
# put U-Boot somewhere other than sector 16 and destroy whatever was there.
init_scratch() {
	$FEL writel $NSECT_ADDR 0        # nothing to do on this run
	$FEL writel $LBA_ADDR   $TARGET_LBA
	$FEL writel $MODE_ADDR  0        # 0 = write, 1 = read
}

# The payload is uploaded into DRAM, and DRAM does not exist until the SPL has
# run its init once. So: run the SPL, upload, tell it how big, run it again.
echo "==> initialising DRAM (first SPL run)"
init_scratch
$FEL spl "$SPL"

echo "==> uploading payload to DRAM"
$FEL write $SRC_ADDR "$PAYLOAD"

echo "==> setting target and sector count"
$FEL writel $LBA_ADDR   $TARGET_LBA
$FEL writel $MODE_ADDR  0
$FEL writel $NSECT_ADDR $SECTORS

echo "==> installing to eMMC (second SPL run)"
$FEL spl "$SPL"

echo "==> reading result"
TMP=$(mktemp)
$FEL read $STATUS_ADDR 0x24 "$TMP"

word() { printf "%d" "0x$(od -An -tx4 -j "$1" -N4 "$TMP" | tr -d ' ')"; }
hword() { echo "0x$(od -An -tx4 -j "$1" -N4 "$TMP" | tr -d ' ')"; }

START=$(hword 0);  MMCINIT=$(word 4);  FOUND=$(word 8)
INIT=$(word 12);   WROTE=$(word 16);   READ=$(word 20)
SRCCRC=$(hword 24); DSTCRC=$(hword 28); END=$(hword 32)

echo "  started        : $START (want 0xe33a1234)"
echo "  mmc_initialize : $MMCINIT (want 0)"
echo "  eMMC found     : $FOUND (want 1)"
echo "  mmc_init       : $INIT (want 0)"
echo "  sectors written: $WROTE (want $SECTORS)"
echo "  sectors read   : $READ (want $SECTORS)"
echo "  source  crc    : $SRCCRC"
echo "  readback crc   : $DSTCRC"
echo "  completed      : $END (want 0xc0ffeeee)"
rm -f "$TMP"
echo

# The sentinels matter: without them, SRAM left over from an earlier attempt
# could satisfy the counters even if this SPL run never actually executed.
if [ "$START" = "0xe33a1234" ] && [ "$END" = "0xc0ffeeee" ] && \
   [ "$WROTE" = "$SECTORS" ] && [ "$SRCCRC" = "$DSTCRC" ] && \
   [ "$SRCCRC" != "0x00000000" ]; then
	echo "SUCCESS - U-Boot is installed and verified byte-for-byte."
else
	echo "FAILED - do not power cycle expecting it to boot; re-read the README."
	exit 1
fi
