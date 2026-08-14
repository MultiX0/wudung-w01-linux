#!/usr/bin/env python3
"""
fel-emmc.py - read and write the W01's eMMC over USB FEL, with the box
              otherwise dead.

This is the recovery tool. It needs nothing working on the box except the
BROM: no bootloader, no kernel, no console. If you brick the install, this
gets you back without opening the case.

  sudo ./fel-emmc.py info
  sudo ./fel-emmc.py gpt
  sudo ./fel-emmc.py read  <lba> <sectors> <outfile>
  sudo ./fel-emmc.py write <lba> <infile>
  sudo ./fel-emmc.py cat   <partnum> <path>          print a file from ext4
  sudo ./fel-emmc.py patch <partnum> <path> <old> <new>  in-place, same length

sudo is required: a usbipd-attached device under WSL2 is root-owned and
sunxi-tools ships no udev rule, so without it you get "FEL device not found"
even when the box is sitting in FEL mode.

Requirements: sunxi-fel on PATH (or FEL=/path/to/sunxi-fel), and the
FEL tool SPL (prebuilt/sunxi-spl-fel-installer.bin, or SPL=/path/to/it).

Put the box in FEL mode first (see the README).

Notes / limits, so nothing surprises you:
  * one operation moves at most 4096 sectors (2 MiB)
  * LBA 0 is not addressable (0 means "unset" to the SPL and falls back to 16,
    the bootloader offset) - read LBA 1 onward
  * `patch` only rewrites bytes inside blocks the file already owns. It never
    allocates or frees blocks, so no ext4 bitmaps or checksums change. The
    replacement must be the same length as the original.
"""
import os, struct, subprocess, sys

FEL = os.environ.get("FEL", "sunxi-fel")
HERE = os.path.dirname(os.path.abspath(__file__))
SPL = os.environ.get("SPL", os.path.join(HERE, "..", "prebuilt", "sunxi-spl-fel-installer.bin"))
TMP = "/tmp/.felrw.bin"

STATUS, NSECT, LBA, MODE = "0x40000", "0x40100", "0x40104", "0x40108"
SRC, DST = "0x50000000", "0x60000000"
MAXSECT = 4096


def fel(*a, quiet=True):
    subprocess.run([FEL] + list(a), check=True,
                   stdout=subprocess.DEVNULL if quiet else None,
                   stderr=subprocess.DEVNULL if quiet else None)


def check():
    if not os.path.exists(SPL):
        sys.exit("FEL tool SPL not found: %s" % SPL)
    try:
        out = subprocess.check_output([FEL, "ver"], text=True).strip()
    except Exception as e:
        sys.exit("cannot talk to the box in FEL mode (%s)" % e)
    if "H616" not in out:
        print("warning: unexpected SoC line: %s" % out)
    return out


class Emmc:
    def __init__(self):
        self.cache = {}

    def read(self, lba, nsect):
        if lba == 0:
            sys.exit("LBA 0 is not addressable by this tool, start at 1")
        if nsect > MAXSECT:
            sys.exit("at most %d sectors per read" % MAXSECT)
        key = (lba, nsect)
        if key in self.cache:
            return self.cache[key]
        fel("writel", NSECT, "0"); fel("writel", MODE, "1")
        fel("spl", SPL)
        fel("writel", LBA, str(lba)); fel("writel", MODE, "1")
        fel("writel", NSECT, str(nsect))
        fel("spl", SPL)
        if os.path.exists(TMP):
            os.unlink(TMP)
        fel("read", DST, str(nsect * 512), TMP)
        d = open(TMP, "rb").read()
        if len(self.cache) < 96:
            self.cache[key] = d
        return d

    def write(self, lba, path):
        n = (os.path.getsize(path) + 511) // 512
        if lba == 0 or n > MAXSECT:
            sys.exit("bad lba/size")
        fel("writel", NSECT, "0"); fel("writel", MODE, "0")
        fel("spl", SPL)
        fel("write", SRC, path)
        fel("writel", LBA, str(lba)); fel("writel", MODE, "0")
        fel("writel", NSECT, str(n))
        fel("spl", SPL)
        st = "/tmp/.felst.bin"
        if os.path.exists(st):
            os.unlink(st)
        fel("read", STATUS, "0x24", st)
        d = open(st, "rb").read()
        w = struct.unpack_from("<I", d, 0x10)[0]
        c1 = struct.unpack_from("<I", d, 0x18)[0]
        c2 = struct.unpack_from("<I", d, 0x1c)[0]
        done = struct.unpack_from("<I", d, 0x20)[0]
        ok = (w == n and c1 == c2 and done == 0xC0FFEEEE)
        print("  wrote %d sectors at LBA %d, crc %08x/%08x -> %s"
              % (w, lba, c1, c2, "OK" if ok else "FAILED"))
        return ok


def gpt(e):
    d = e.read(1, 40)
    if d[:8] != b"EFI PART":
        sys.exit("no GPT found")
    part_lba, = struct.unpack_from("<Q", d, 0x48)
    n, = struct.unpack_from("<I", d, 0x50)
    sz, = struct.unpack_from("<I", d, 0x54)
    base = (part_lba - 1) * 512
    parts = {}
    print("%-3s %-16s %12s %12s %9s" % ("#", "NAME", "START", "END", "SIZE MiB"))
    for i in range(n):
        o = base + i * sz
        if o + sz > len(d) or d[o:o+16] == b"\x00" * 16:
            continue
        first, last, attr = struct.unpack_from("<QQQ", d, o + 32)
        name = d[o+56:o+128].decode("utf-16-le").split("\x00")[0]
        parts[i + 1] = (first, last, name)
        print("%-3d %-16s %12d %12d %9d"
              % (i + 1, name, first, last, (last - first + 1) * 512 // (1 << 20)))
    return parts


# --- minimal ext4 reader (see README for why this exists) -------------------
class Ext4:
    def __init__(self, e, part_lba):
        self.e, self.p = e, part_lba
        sb = self.rb(1024, 1024)
        if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
            sys.exit("no ext4 at LBA %d" % part_lba)
        self.bs = 1024 << struct.unpack_from("<I", sb, 0x18)[0]
        self.ipg = struct.unpack_from("<I", sb, 0x28)[0]
        self.isz = struct.unpack_from("<H", sb, 0x58)[0]
        self.fdb = struct.unpack_from("<I", sb, 0x14)[0]
        inc = struct.unpack_from("<I", sb, 0x60)[0]
        ds = struct.unpack_from("<H", sb, 0xFE)[0]
        self.ds = ds if (inc & 0x80 and ds) else 32

    def rb(self, off, ln):
        s = off // 512
        n = (off + ln + 511) // 512 - s
        return self.e.read(self.p + s, n)[off - s * 512:][:ln]

    def blk(self, b):
        return self.rb(b * self.bs, self.bs)

    def inode(self, ino):
        g, i = (ino - 1) // self.ipg, (ino - 1) % self.ipg
        gd = self.rb((self.fdb + 1) * self.bs + g * self.ds, self.ds)
        t = struct.unpack_from("<I", gd, 0x8)[0]
        if self.ds >= 64:
            t |= struct.unpack_from("<I", gd, 0x28)[0] << 32
        return self.rb(t * self.bs + i * self.isz, self.isz)

    def extents(self, nd):
        ib = nd[0x28:0x28+60]
        magic, ent, _, depth, _ = struct.unpack_from("<HHHHI", ib, 0)
        if magic != 0xF30A:
            sys.exit("inode does not use extents")
        out = []
        if depth == 0:
            for k in range(ent):
                eb, ln, hi, lo = struct.unpack_from("<IHHI", ib, 12 + k * 12)
                out.append((eb, (hi << 32) | lo, ln))
        else:
            for k in range(ent):
                eb, lo, hi = struct.unpack_from("<III", ib, 12 + k * 12)
                leaf = self.blk(((hi & 0xFFFF) << 32) | lo)
                _, e2, _, _, _ = struct.unpack_from("<HHHHI", leaf, 0)
                for j in range(e2):
                    b2, l2, h2, lo2 = struct.unpack_from("<IHHI", leaf, 12 + j * 12)
                    out.append((b2, (h2 << 32) | lo2, l2))
        return sorted(out)

    def listdir(self, ino):
        ents = {}
        for _, b, c in self.extents(self.inode(ino)):
            for k in range(c):
                d = self.blk(b + k)
                p = 0
                while p < len(d) - 8:
                    i2, rl, nl, _ = struct.unpack_from("<IHBB", d, p)
                    if rl < 8:
                        break
                    if i2:
                        ents[d[p+8:p+8+nl].decode("ascii", "replace")] = i2
                    p += rl
        return ents

    def resolve(self, path, ino=2, depth=0):
        if depth > 8:
            sys.exit("symlink loop")
        parts = [x for x in path.split("/") if x]
        cur = ino
        for idx, name in enumerate(parts):
            ents = self.listdir(cur)
            if name not in ents:
                sys.exit("not found: %s" % name)
            cur = ents[name]
            nd = self.inode(cur)
            if (struct.unpack_from("<H", nd, 0)[0] & 0xF000) == 0xA000:
                sz = struct.unpack_from("<I", nd, 4)[0]
                if sz >= 60:
                    sys.exit("slow symlink unsupported")
                tgt = nd[0x28:0x28+sz].decode()
                rest = "/".join(parts[idx+1:])
                if not tgt.startswith("/"):
                    tgt = "/".join(parts[:idx]) + "/" + tgt
                return self.resolve(tgt + "/" + rest, 2, depth + 1)
        return cur


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    cmd = sys.argv[1]
    print(check())
    e = Emmc()

    if cmd == "info":
        return
    if cmd == "gpt":
        gpt(e); return

    if cmd == "read":
        lba, n, out = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
        open(out, "wb").write(e.read(lba, n))
        print("wrote %s" % out); return

    if cmd == "write":
        lba, src = int(sys.argv[2]), sys.argv[3]
        sys.exit(0 if e.write(lba, src) else 1)

    if cmd in ("cat", "patch"):
        pn, path = int(sys.argv[2]), sys.argv[3]
        parts = gpt(e)
        if pn not in parts:
            sys.exit("no partition %d" % pn)
        fs = Ext4(e, parts[pn][0])
        ino = fs.resolve(path)
        nd = fs.inode(ino)
        size = struct.unpack_from("<I", nd, 4)[0]
        ext = fs.extents(nd)
        data = b"".join(fs.blk(b + k) for _, b, c in ext for k in range(c))[:size]
        if cmd == "cat":
            sys.stdout.write(data.decode("utf-8", "replace")); return
        old, new = sys.argv[4].encode(), sys.argv[5].encode()
        if len(old) != len(new):
            sys.exit("replacement must be the same length (%d vs %d)"
                     % (len(old), len(new)))
        if old not in data:
            sys.exit("text not found in %s" % path)
        off = data.index(old)
        fb = off // fs.bs
        # find which extent holds that file block
        for feb, db, c in ext:
            if feb <= fb < feb + c:
                disk = db + (fb - feb)
                break
        else:
            sys.exit("could not map file block")
        o = off % fs.bs
        if o + len(old) > fs.bs:
            sys.exit("that text straddles a %d-byte block boundary, which this "
                     "tool does not handle. Pick a shorter piece of the line."
                     % fs.bs)
        blk = bytearray(fs.blk(disk))
        blk[o:o + len(old)] = new
        if len(blk) != fs.bs:
            sys.exit("internal error: block changed size, refusing to write")
        tmp = "/tmp/.felblk.bin"
        open(tmp, "wb").write(bytes(blk))
        abs_lba = fs.p + disk * fs.bs // 512
        print("patching %s at eMMC LBA %d" % (path, abs_lba))
        sys.exit(0 if e.write(abs_lba, tmp) else 1)

    print(__doc__)


if __name__ == "__main__":
    main()
