#!/bin/bash
#
# Copy a running MiniArch (or any Arch Linux ARM rootfs) from the USB stick
# onto the box's internal eMMC, so the box boots standalone with nothing
# plugged into its single USB port.
#
# Runs unattended from systemd on boot, logs to /boot/emmc-install.log (on the
# USB stick, so you can read it afterwards on a PC) and powers the box off when
# it is finished. That is the only progress signal you get: these boxes have no
# UART and U-Boot has no HDMI output, so "the box turned itself off" means done.
#
# It does NOT repartition anything. The stock Android GPT is left exactly as it
# is and two existing Android partitions are simply reformatted and reused:
#
#   /dev/mmcblk2p7   "cache"  1.5G  ->  /boot   (ext4)
#   /dev/mmcblk2p17  "UDISK"  10.9G ->  /       (ext4)
#
# Leaving the partition table alone matters: the table on these boxes is an
# unusual 17-entry GPT, and letting a partitioning tool rewrite it with the
# normal 128-entry layout would run the entry array straight over the
# bootloader we installed at LBA 16.
#
set -u
set -o pipefail        # else a failed source tar in a pipeline reads as success

LOG=/boot/emmc-install.log
BOOT_PART=/dev/mmcblk2p7
BOOT_PARTNUM=7
ROOT_PART=/dev/mmcblk2p17
EMMC=/dev/mmcblk2
MIN_EMMC_BYTES=15000000000

# On failure, do NOT power off. Success powers the box off, and the README
# tells the user that switching off means it finished, so powering off after a
# failure is indistinguishable from success and they would unplug the stick
# and be left with a dead box. Staying on is the failure signal.
fail() {
	echo "FATAL: $*"
	echo
	echo "=============================================="
	echo " INSTALL FAILED. The box has deliberately"
	echo " stayed powered on so you can tell."
	echo " Read emmc-install.log on the USB stick."
	echo "=============================================="
	sync
	exit 1
}

# /boot is the USB stick, and the log lives there. If it is not mounted the
# redirect below fails, the whole block is skipped, and the box powers off
# having done nothing at all.
[ -d /boot ] || { echo "FATAL: /boot is not mounted"; exit 1; }

{
	echo "=== install MiniArch to eMMC ==="
	date
	set -x

	[ -b "$EMMC" ]      || fail "no $EMMC - is this the right board?"
	[ -b "$BOOT_PART" ] || fail "no $BOOT_PART"
	[ -b "$ROOT_PART" ] || fail "no $ROOT_PART"

	SIZE=$(blockdev --getsize64 "$EMMC")
	[ "$SIZE" -gt "$MIN_EMMC_BYTES" ] || fail "unexpected eMMC size $SIZE"

	# --- filesystems -------------------------------------------------
	mkfs.ext4 -F -L EMMCBOOT "$BOOT_PART" || fail "mkfs boot failed"
	mkfs.ext4 -F -L EMMCROOT "$ROOT_PART" || fail "mkfs root failed"

	mkdir -p /mnt/newboot /mnt/newroot
	mount "$BOOT_PART" /mnt/newboot || fail "mount boot failed"
	mount "$ROOT_PART" /mnt/newroot || fail "mount root failed"

	# --- boot partition ----------------------------------------------
	cp -a /boot/. /mnt/newboot/ || fail "boot copy failed"

	# point the kernel at the eMMC root instead of the USB stick.
	# sed -i exits 0 when it matches nothing, so this MUST be verified: if the
	# user skipped the edit in README Part 3 Step 3, the kernel would boot
	# looking for root on the USB stick and hang with no console to say why.
	sed -i "s#root=/dev/sda2#root=$ROOT_PART#" \
		/mnt/newboot/extlinux/extlinux.conf
	grep APPEND /mnt/newboot/extlinux/extlinux.conf
	grep -q "root=$ROOT_PART" /mnt/newboot/extlinux/extlinux.conf \
		|| fail "extlinux.conf does not point at $ROOT_PART. Did you do the
extlinux edit in Part 3 Step 3 before booting the stick?"

	# --- root filesystem ---------------------------------------------
	tar -C / \
		--exclude=./proc --exclude=./sys --exclude=./dev \
		--exclude=./run --exclude=./tmp --exclude=./mnt --exclude=./boot \
		-cf - . | tar -C /mnt/newroot -xf - || fail "rootfs copy failed"

	mkdir -p /mnt/newroot/proc /mnt/newroot/sys /mnt/newroot/dev \
		 /mnt/newroot/run /mnt/newroot/tmp /mnt/newroot/mnt \
		 /mnt/newroot/boot
	chmod 1777 /mnt/newroot/tmp

	# /boot is ext4 on the eMMC, but vfat on the USB stick we copied from
	sed -i "s#LABEL=BOOT#$BOOT_PART#" /mnt/newroot/etc/fstab
	sed -i 's#/boot\tvfat#/boot\text4#; s#/boot vfat#/boot ext4#' \
		/mnt/newroot/etc/fstab
	cat /mnt/newroot/etc/fstab
	grep -q "$BOOT_PART" /mnt/newroot/etc/fstab \
		|| fail "fstab still does not reference $BOOT_PART for /boot"

	# CRITICAL: this very script got copied into the new rootfs along with
	# everything else, and its systemd unit came with it. Left enabled, the
	# copy would run again on the first eMMC boot, try to reformat the
	# filesystem it is itself running from, and power the box off just
	# before the login prompt - forever.
	rm -f /mnt/newroot/etc/systemd/system/multi-user.target.wants/install-to-emmc.service
	rm -f /mnt/newroot/etc/systemd/system/install-to-emmc.service
	rm -f /mnt/newroot/usr/local/bin/install-to-emmc.sh

	# --- make U-Boot willing to look at this partition ----------------
	# U-Boot's distro bootcmd only scans partitions returned by
	# "part list ... -bootable", which filters on the GPT
	# LegacyBIOSBootable attribute (bit 2). The Android partition we
	# reused does not have it, so without this U-Boot silently falls back
	# to scanning partition 1 only and never finds extlinux.conf.
	# Bit 63 is the existing Android attribute; keep it.
	sfdisk --part-attrs "$EMMC" "$BOOT_PARTNUM" "63,LegacyBIOSBootable"
	sfdisk --part-attrs "$EMMC" "$BOOT_PARTNUM"

	# --- disarm this stick --------------------------------------------
	# The unit is still enabled on the stick itself. If the box ever boots
	# from this stick again (eMMC boot fails, or someone leaves it in) it
	# would reformat the install that was just made. Disable it here so the
	# stick is inert from now on and nobody has to remember to do it.
	rm -f /etc/systemd/system/multi-user.target.wants/install-to-emmc.service
	echo "installer disabled on the USB stick"

	# --- done ---------------------------------------------------------
	df -h "$BOOT_PART" "$ROOT_PART"
	du -sh /mnt/newroot/ 2>/dev/null

	sync
	umount /mnt/newboot
	umount /mnt/newroot
	echo "=== finished, powering off ==="
} > "$LOG" 2>&1

sync
sleep 2
poweroff
