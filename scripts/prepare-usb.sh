#!/bin/bash
#
# Prepare the USB stick on your PC so the box needs nothing but power.
#
#   sudo ./prepare-usb.sh /dev/sdg
#
# This does every edit the stick needs, in one go:
#   * points the kernel at the USB root instead of the eMMC
#   * adds console=tty0 so you get output on the TV
#   * installs the WiFi driver, firmware, iw and wpa_supplicant into the
#     stick's root filesystem
#   * installs the `wifi` command and the shell aliases
#   * enables the driver at boot, blacklists the wrong s9083s driver
#   * installs the eMMC installer service
#
# The eMMC installer copies the whole root filesystem across, so everything
# above lands on the eMMC too. After the install the box boots with WiFi
# already working, and you only ever need a keyboard to run `wifi connect`.
#
# Needs: sudo, tar, and the WiFi bundle (downloaded automatically, or pass
# BUNDLE=/path/to/w01-wifi-*.tar.gz to use a local copy).
set -euo pipefail

DEV="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KVER="${KVER:-7.1.1}"
REL="https://github.com/MultiX0/wudung-w01-linux/releases/latest/download/w01-wifi-v1.1.tar.gz"

if [ -z "$DEV" ]; then
	echo "usage: sudo $0 /dev/sdX      (the whole drive, not a partition)"
	echo
	echo "Find it with lsblk. It is the device whose size matches your"
	echo "flash drive, and it must already have the MiniArch image written"
	echo "to it (Part 3 Step 2 of the README)."
	exit 1
fi
[ "$(id -u)" = "0" ] || { echo "run this with sudo"; exit 1; }
[ -b "$DEV" ] || { echo "$DEV is not a block device"; exit 1; }

BOOTP="${DEV}1"
ROOTP="${DEV}2"
for p in "$BOOTP" "$ROOTP"; do
	[ -b "$p" ] || { echo "missing $p. Did you write the image and run partprobe?"; exit 1; }
done

MB=$(mktemp -d); MR=$(mktemp -d); WORK=$(mktemp -d)
cleanup() {
	umount "$MB" 2>/dev/null || true
	umount "$MR" 2>/dev/null || true
	rm -rf "$MB" "$MR" "$WORK"
}
trap cleanup EXIT

mount "$BOOTP" "$MB"
mount "$ROOTP" "$MR"

# sanity: make sure these really are the MiniArch partitions and not, say,
# somebody's data drive that happened to be at the same letter
[ -f "$MB/extlinux/extlinux.conf" ] || { echo "no extlinux.conf on $BOOTP - wrong device?"; exit 1; }
[ -d "$MR/usr/lib" ] || { echo "no rootfs on $ROOTP - wrong device?"; exit 1; }
[ -d "$MR/lib/modules/$KVER" ] || {
	echo "the rootfs has no /lib/modules/$KVER."
	echo "Kernel versions present:"; ls "$MR/lib/modules/" 2>/dev/null
	echo "Set KVER=<version> and re-run."
	exit 1
}

echo "=== 1/5 boot configuration ==="
sed -i "s#root=/dev/mmcblk2p2#root=/dev/sda2#" "$MB/extlinux/extlinux.conf"
sed -i "s#console=ttyS0,115200n8#console=tty0 console=ttyS0,115200n8#" \
	"$MB/extlinux/extlinux.conf"
grep -q "root=/dev/sda2" "$MB/extlinux/extlinux.conf" \
	|| { echo "could not point the kernel at /dev/sda2"; exit 1; }
grep -q "console=tty0" "$MB/extlinux/extlinux.conf" \
	|| { echo "could not add console=tty0"; exit 1; }
grep APPEND "$MB/extlinux/extlinux.conf"

echo "=== 2/5 fetching the WiFi bundle ==="
BUNDLE="${BUNDLE:-}"
if [ -z "$BUNDLE" ]; then
	BUNDLE="$WORK/w01-wifi.tar.gz"
	curl -fL --progress-bar -o "$BUNDLE" "$REL" \
		|| { echo "download failed. Pass BUNDLE=/path/to/w01-wifi-*.tar.gz"; exit 1; }
fi
tar xf "$BUNDLE" -C "$WORK"
B=$(find "$WORK" -maxdepth 1 -type d -name 'w01-wifi-*' | head -1)
[ -n "$B" ] || { echo "bundle does not contain a w01-wifi-* directory"; exit 1; }

echo "=== 3/5 driver and firmware ==="
install -Dm644 "$B/atbm603x_wifi_sdio.ko" \
	"$MR/lib/modules/$KVER/extramodules/atbm603x_wifi_sdio.ko"
install -Dm644 "$B/atbm_fw.bin" "$MR/lib/firmware/atbm_fw.bin"

# the wrong driver claims the same SDIO id, remove it wherever it lives
find "$MR/lib/modules/$KVER" -name 's9083s.ko*' -print -delete 2>/dev/null || true
install -d "$MR/etc/modprobe.d"
echo "blacklist s9083s" > "$MR/etc/modprobe.d/blacklist-s9083s.conf"

install -d "$MR/etc/modules-load.d"
echo "atbm603x_wifi_sdio" > "$MR/etc/modules-load.d/atbm.conf"

# Rebuild the module dependency map inside the target tree. This is not
# optional: systemd-modules-load runs "modprobe atbm603x_wifi_sdio" at boot,
# and modprobe needs modules.dep to find a module in extramodules. Nothing on
# the box runs depmod for us, so if this fails the WiFi silently does not come
# up on first boot.
depmod -b "$MR" "$KVER" || {
	echo
	echo "ERROR: depmod failed. Without it the driver will not load on the box."
	echo "Install kmod on this PC and re-run."
	exit 1
}

echo "=== 4/5 userspace ==="
# .pkg.tar.xz is a plain tar, so the payload can be unpacked directly without
# pacman on this PC. Skip the package metadata entries.
for p in "$B"/pkgs/*.pkg.tar.*; do
	[ -e "$p" ] || continue
	echo "  $(basename "$p")"
	tar xf "$p" -C "$MR" --exclude='.PKGINFO' --exclude='.MTREE' \
		--exclude='.BUILDINFO' --exclude='.INSTALL' 2>/dev/null || true
done

install -Dm755 "$B/w01-wifi" "$MR/usr/local/bin/w01-wifi"
ln -sf w01-wifi "$MR/usr/local/bin/wifi"

install -d "$MR/etc/profile.d"
cat > "$MR/etc/profile.d/w01.sh" <<'EOF'
# Wudung W01 convenience
alias wifi='w01-wifi'
alias wifi-scan='w01-wifi scan'
alias myip="ip -4 -o addr show scope global | awk '{print \$2, \$4}'"
EOF
chmod 644 "$MR/etc/profile.d/w01.sh"

install -d "$MR/etc/issue.d"
cat > "$MR/etc/issue.d/w01.issue" <<'EOF'

  Wudung W01   address: \4

EOF

# ssh on by default, with root allowed, so a headless box is reachable
install -d "$MR/etc/ssh/sshd_config.d"
echo 'PermitRootLogin yes' > "$MR/etc/ssh/sshd_config.d/10-root.conf"
if [ -f "$MR/usr/lib/systemd/system/sshd.service" ]; then
	install -d "$MR/etc/systemd/system/multi-user.target.wants"
	ln -sf /usr/lib/systemd/system/sshd.service \
		"$MR/etc/systemd/system/multi-user.target.wants/sshd.service"
	SSH_OK=yes
else
	SSH_OK=no
fi

# The box has no network until wifi connect runs, so anything missing here
# cannot be installed later without a USB ethernet adapter. Say so now, on the
# PC, while it is still cheap to fix, rather than letting the user find out on
# a box they cannot reach.
MISSING=""
[ -x "$MR/usr/bin/iw" ]              || MISSING="$MISSING iw"
[ -x "$MR/usr/bin/wpa_supplicant" ]  || MISSING="$MISSING wpa_supplicant"
[ -x "$MR/usr/bin/wpa_passphrase" ]  || MISSING="$MISSING wpa_passphrase"
[ -x "$MR/usr/bin/dhcpcd" ]          || MISSING="$MISSING dhcpcd"
[ "$SSH_OK" = yes ]                  || MISSING="$MISSING openssh"

echo "=== 5/5 eMMC installer ==="
install -Dm755 "$REPO/emmc-install/install-to-emmc.sh" \
	"$MR/usr/local/bin/install-to-emmc.sh"
install -Dm644 "$REPO/emmc-install/install-to-emmc.service" \
	"$MR/etc/systemd/system/install-to-emmc.service"
install -d "$MR/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/install-to-emmc.service \
	"$MR/etc/systemd/system/multi-user.target.wants/install-to-emmc.service"
ls -l "$MR/etc/systemd/system/multi-user.target.wants/install-to-emmc.service"

sync
echo

if [ -n "$MISSING" ]; then
	echo "=============================================================="
	echo " WARNING: these are missing from the stick's root filesystem:"
	echo "    $MISSING"
	echo
	echo " The box will have no way to install them, because it has no"
	echo " network until WiFi works. Add the matching aarch64 packages to"
	echo " pkgs/ in the WiFi bundle and run this again."
	echo "=============================================================="
	exit 1
fi

echo "=============================================================="
echo " Stick is ready."
echo
echo " Put it in the box and power on. It installs itself onto the"
echo " eMMC and switches the box off when it is done, with the WiFi"
echo " driver already in place."
echo
echo " Then: unplug the stick, plug in a keyboard, power on, and run"
echo "     wifi connect"
echo "=============================================================="
