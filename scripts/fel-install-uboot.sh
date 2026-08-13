#!/bin/bash
#
# Install a 64-bit U-Boot into the box's eMMC over USB FEL.
#
# Usage:  ./fel-install-uboot.sh [installer-spl] [uboot-payload]
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
STATUS_ADDR=0x40000

[ -f "$SPL" ]     || { echo "missing installer SPL: $SPL"; exit 1; }
[ -f "$PAYLOAD" ] || { echo "missing payload: $PAYLOAD"; exit 1; }

BYTES=$(stat -c %s "$PAYLOAD")
SECTORS=$(( (BYTES + 511) / 512 ))

echo "payload : $PAYLOAD"
echo "size    : $BYTES bytes ($SECTORS sectors)"
echo

echo "==> checking FEL"
$FEL ver

# The payload is uploaded into DRAM, and DRAM does not exist until the SPL has
# run its init once. So: run the SPL, upload, tell it how big, run it again.
echo "==> initialising DRAM (first SPL run)"
$FEL spl "$SPL"

echo "==> uploading payload to DRAM"
$FEL write $SRC_ADDR "$PAYLOAD"

echo "==> setting sector count"
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

if [ "$WROTE" = "$SECTORS" ] && [ "$SRCCRC" = "$DSTCRC" ] && [ "$SRCCRC" != "0x00000000" ]; then
	echo "SUCCESS - U-Boot is installed and verified byte-for-byte."
else
	echo "FAILED - do not power cycle expecting it to boot; re-read the README."
	exit 1
fi
