#!/bin/bash
#
# Extract the WiFi firmware the W01 actually needs out of the stock Android
# image (the PhoenixSuit .img you can also use to restore the box).
#
#   ./extract-atbm-firmware.sh 313_TX1_6031_20250513.img
#
# Produces atbm_fw.bin, which goes to /lib/firmware/atbm_fw.bin on the box.
#
# Why this is necessary: the open-source atbm60xx driver ships a firmware blob
# (svn14195) that this board's chip does not run - it loads, executes, and then
# never completes the WSM startup handshake, so you get an endless
# "wsm_startup_done timeout" reload loop. The blob that works is the one from
# the box's own Android system: lmac 19040, label "=MODEM==SDIO=-NoBle-".
#
# Needs: python3, simg2img (android-sdk-libsparse-utils), sudo for the loop mount.
set -e

IMG="${1:-}"
[ -f "$IMG" ] || { echo "usage: $0 <stock-android.img>"; exit 1; }
OUT="${OUT:-$PWD}"
WORK="$(mktemp -d)"
trap 'sudo umount "$WORK/vendor" 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "=== 1/4 unpacking IMAGEWTY container ==="
python3 - "$IMG" "$WORK" <<'PY'
import struct, sys, os
img, work = sys.argv[1], sys.argv[2]
f = open(img, "rb")
hdr = f.read(0x60)
assert hdr[:8] == b"IMAGEWTY", "not an Allwinner IMAGEWTY image"
n = struct.unpack_from("<I", hdr, 0x3C)[0]
for i in range(n):
    f.seek(1024 + i * 1024)
    e = f.read(1024)
    name = e[0x24:0x124].split(b"\x00")[0].decode()
    stored, orig, off = struct.unpack_from("<QQQ", e, 0x124)
    if name != "super.fex":
        continue
    f.seek(off)
    with open(os.path.join(work, "super.fex"), "wb") as o:
        left = orig
        while left > 0:
            c = f.read(min(1 << 20, left))
            if not c:
                break
            o.write(c); left -= len(c)
    print("  extracted super.fex (%d bytes)" % orig)
    break
else:
    sys.exit("super.fex not found in image")
PY

echo "=== 2/4 converting sparse image ==="
simg2img "$WORK/super.fex" "$WORK/super.img"

echo "=== 3/4 locating the vendor partition ==="
VOFF=$(python3 - "$WORK/super.img" <<'PY'
import struct, sys
f = open(sys.argv[1], "rb"); f.seek(0, 2); size = f.tell()
off = 0
while off + 0x1000 < size:
    f.seek(off + 0x438)
    if f.read(2) == b"\x53\xef":
        f.seek(off + 0x400); sb = f.read(0x400)
        label = sb[0x78:0x88].split(b"\x00")[0].decode("ascii", "replace")
        if label == "vendor":
            print(off); break
    off += 0x10000
PY
)
[ -n "$VOFF" ] || { echo "vendor partition not found"; exit 1; }
echo "  vendor at byte offset $VOFF"

echo "=== 4/4 copying firmware ==="
mkdir -p "$WORK/vendor"
sudo mount -o ro,loop,offset="$VOFF" "$WORK/super.img" "$WORK/vendor"
cp "$WORK/vendor/etc/firmware/ATBM_lite_fw_sdio.bin" "$OUT/atbm_fw.bin"
sudo umount "$WORK/vendor"

echo
ls -l "$OUT/atbm_fw.bin"

# Check it rather than asking you to eyeball two hex strings. The wrong blob
# (the WiFi+BT combo from the same directory, or the driver's own svn14195)
# loads happily and then hangs forever in wsm_startup_done timeout.
if echo "822266515afa86b838ed3f621d4db042  $OUT/atbm_fw.bin" | md5sum -c - ; then
	echo
	echo "Install it on the box as /lib/firmware/atbm_fw.bin"
else
	echo
	echo "ERROR: this is not the known-good firmware."
	echo "You may have a different stock image. Check that you extracted"
	echo "ATBM_lite_fw_sdio.bin (WiFi only) and not the blecomb one."
	exit 1
fi
