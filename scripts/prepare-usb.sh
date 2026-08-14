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
# Pinned, not /latest/download/: that resolves against the newest release,
# so this URL would 404 the day a v1.2 is tagged.
REL="https://github.com/MultiX0/wudung-w01-linux/releases/download/v1.1/w01-wifi-v1.1.tar.gz"

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
	echo
	echo "Set KVER=<version> ONLY if you have also rebuilt the driver for that"
	echo "kernel with scripts/build-atbm-driver.sh. The prebuilt one is built"
	echo "for 7.1.1 and will not load on anything else."
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
# A module only loads into the kernel it was built for, and depmod does not
# check. Without this the stick reports success and the box ends up with no
# WiFi and no way to install any.
KO_VER=$(modinfo -F vermagic "$B/atbm603x_wifi_sdio.ko" 2>/dev/null | awk '{print $1}')
if [ -n "$KO_VER" ] && [ "$KO_VER" != "$KVER" ]; then
	echo "ERROR: the driver is built for kernel $KO_VER but this image runs $KVER."
	echo "Rebuild it with scripts/build-atbm-driver.sh against $KVER headers."
	exit 1
fi
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

# Prefer the copy in this checkout: it is the one the README documents and
# the one people send patches against. Fall back to the bundle if missing.
if [ -f "$REPO/rootfs/usr/local/bin/w01-wifi" ]; then
	install -Dm755 "$REPO/rootfs/usr/local/bin/w01-wifi" "$MR/usr/local/bin/w01-wifi"
else
	install -Dm755 "$B/w01-wifi" "$MR/usr/local/bin/w01-wifi"
fi
ln -sf w01-wifi "$MR/usr/local/bin/wifi"


# --- netfilter -------------------------------------------------------------
# This kernel builds nf_tables but not its IPv4/IPv6 families, so the nft
# backend that Arch points iptables at cannot create a filter table and ufw is
# unusable. Ship the fix rather than letting every user rediscover it, and add
# a pacman hook because an iptables upgrade puts the nft symlinks back.
install -Dm755 "$REPO/rootfs/usr/local/bin/w01-iptables-legacy" \
	"$MR/usr/local/bin/w01-iptables-legacy"
install -Dm644 "$REPO/rootfs/etc/pacman.d/hooks/99-w01-iptables-legacy.hook" \
	"$MR/etc/pacman.d/hooks/99-w01-iptables-legacy.hook"
printf 'ip_tables\niptable_filter\nip6_tables\nip6table_filter\n' \
	> "$MR/etc/modules-load.d/iptables-legacy.conf"
# apply it now, inside the target tree, so it is already right on first boot
for b in iptables iptables-restore iptables-save \
         ip6tables ip6tables-restore ip6tables-save; do
	[ -e "$MR/usr/bin/xtables-legacy-multi" ] && \
		ln -sf xtables-legacy-multi "$MR/usr/bin/$b"
done


# --- kernel pin, verified not assumed ---------------------------------------
# The WiFi driver is out-of-tree and built against exactly $KVER; the kernel
# checks vermagic at load time. A "pacman -Syu" that pulled a newer
# linux-aarch64 would leave the box with no driver, and WiFi is its only remote
# link, so that would need a keyboard and a screen to recover.
# MiniArch already pins the kernel in /etc/pacman.conf, so this is only a
# backstop in case a future image drops it. Checked, not assumed.
if [ -f "$MR/etc/pacman.conf" ]; then
	if grep -q '^IgnorePkg.*linux-aarch64' "$MR/etc/pacman.conf"; then
		echo "  kernel already pinned by the base image, leaving it alone"
	else
		echo "  base image does not pin the kernel, adding the pin"
		if grep -q '^IgnorePkg' "$MR/etc/pacman.conf"; then
			sed -i 's/^IgnorePkg.*/& linux-aarch64 linux-aarch64-api-headers/' \
				"$MR/etc/pacman.conf"
		else
			sed -i '/^\[options\]/a IgnorePkg = linux-aarch64 linux-aarch64-api-headers' \
				"$MR/etc/pacman.conf"
		fi
		# never trust a sed that had to find an anchor
		grep -q '^IgnorePkg.*linux-aarch64' "$MR/etc/pacman.conf" || {
			echo
			echo "ERROR: could not pin the kernel in /etc/pacman.conf."
			echo "Without the pin, a later 'pacman -Syu' silently kills WiFi."
			exit 1
		}
	fi
else
	echo "  warning: no /etc/pacman.conf in the target, kernel not pinned"
fi

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
# The drop-in only takes effect if sshd_config includes that directory. If it
# does not, append the setting directly, otherwise OpenSSH keeps its default
# of prohibit-password and root SSH silently fails.
if [ -f "$MR/etc/ssh/sshd_config" ] && \
   ! grep -q '^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d' "$MR/etc/ssh/sshd_config"; then
	echo 'PermitRootLogin yes' >> "$MR/etc/ssh/sshd_config"
fi
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

# The README documents `wifi scan` and `wifi connect` as the way in, so a stick
# that installs without them strands the user at a prompt where the documented
# command does not exist. Check the symlink resolves, not just that a file is
# there: `ln -sf` happily creates a link to nothing.
[ -x "$MR/usr/local/bin/w01-wifi" ]  || MISSING="$MISSING w01-wifi"
[ -x "$MR/usr/local/bin/wifi" ]      || MISSING="$MISSING wifi(symlink)"

# Bail out BEFORE arming the eMMC installer. Otherwise a failed run still
# leaves a stick that will happily install a WiFi-less system to the eMMC.
if [ -n "$MISSING" ]; then
	echo
	echo "=============================================================="
	echo " STOPPING: these are missing from the stick's root filesystem:"
	echo "    $MISSING"
	echo
	echo " The box would have no way to install them, because it has no"
	echo " network until WiFi works. Add the matching aarch64 packages to"
	echo " pkgs/ in the WiFi bundle and run this again."
	echo
	echo " The eMMC installer has NOT been armed, so this stick will not"
	echo " install anything yet."
	echo "=============================================================="
	exit 1
fi

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
