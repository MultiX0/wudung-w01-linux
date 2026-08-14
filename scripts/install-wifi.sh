#!/bin/bash
#
# Install everything the built-in WiFi needs onto a running W01, plus the
# userspace the MiniArch image does not ship (iw, wpa_supplicant) and the
# convenience commands.
#
# Run this ON THE BOX, as root, with the release tarball unpacked next to it:
#
#     tar xf w01-wifi-<version>.tar.gz
#     cd w01-wifi-<version>
#     ./install-wifi.sh
#
# It is safe to re-run.
set -e

KVER=$(uname -r)
EXTRA="/lib/modules/$KVER/extramodules"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "=== Wudung W01 WiFi install ==="
echo "kernel: $KVER"

# ---------------------------------------------------------------- driver ---
[ -f "$HERE/atbm603x_wifi_sdio.ko" ] || { echo "missing atbm603x_wifi_sdio.ko"; exit 1; }
[ -f "$HERE/atbm_fw.bin" ]           || { echo "missing atbm_fw.bin"; exit 1; }

mkdir -p "$EXTRA" /lib/firmware
install -m 644 "$HERE/atbm603x_wifi_sdio.ko" "$EXTRA/atbm603x_wifi_sdio.ko"
install -m 644 "$HERE/atbm_fw.bin"           /lib/firmware/atbm_fw.bin

# The stock MiniArch image ships an unrelated driver (s9083s) whose alias also
# matches SDIO 007a:6011. If it is present it claims the chip first and ours
# never gets it. It lives under kernel/drivers/..., not extramodules, so search
# the whole module tree rather than guessing the directory.
find "/lib/modules/$KVER" -name 's9083s.ko*' -print -delete 2>/dev/null || true
mkdir -p /etc/modprobe.d
echo "blacklist s9083s" > /etc/modprobe.d/blacklist-s9083s.conf

depmod -a

# load at every boot
mkdir -p /etc/modules-load.d
echo "atbm603x_wifi_sdio" > /etc/modules-load.d/atbm.conf

# ------------------------------------------------------------- userspace ---
# iw and wpa_supplicant are NOT in the MiniArch image.
if [ -d "$HERE/pkgs" ] && ls "$HERE/pkgs"/*.pkg.tar.* >/dev/null 2>&1; then
    echo "=== installing bundled packages (offline) ==="
    pacman -U --noconfirm --needed "$HERE"/pkgs/*.pkg.tar.* || true
fi

# Check everything that is actually needed later, not just the two we bundle.
# dhcpcd is what gets an address, sshd is what Part 5 Step 5 promises.
MISSING=""
for b in iw wpa_supplicant wpa_passphrase dhcpcd sshd; do
    command -v "$b" >/dev/null 2>&1 || MISSING="$MISSING $b"
done
# sshd is not on PATH on some images even when installed
[ -x /usr/bin/sshd ] || [ -x /usr/sbin/sshd ] || case "$MISSING" in
    *sshd*) ;; *) MISSING="$MISSING sshd" ;;
esac

if [ -n "$MISSING" ]; then
    echo "=== missing:$MISSING - installing from the network ==="
    pacman -Syu --noconfirm --needed iw wpa_supplicant openssh dhcpcd wget || {
        echo
        echo "ERROR: these are missing and could not be installed:$MISSING"
        echo
        echo "The box has no working connection yet. Either plug in a USB"
        echo "ethernet adapter for one pacman run, or add the packages to"
        echo "pkgs/ in this bundle and re-run. Nothing has been broken."
        exit 1
    }
fi

# -------------------------------------------------------------- commands ---
install -m 755 "$HERE/w01-wifi" /usr/local/bin/w01-wifi
ln -sf /usr/local/bin/w01-wifi /usr/local/bin/wifi

cat > /etc/profile.d/w01.sh <<'EOF'
# Wudung W01 convenience
alias wifi='w01-wifi'
alias wifi-scan='w01-wifi scan'
alias myip="ip -4 -o addr show scope global | awk '{print \$2, \$4}'"
EOF
chmod 644 /etc/profile.d/w01.sh

# Show the address on the login screen, so a headless box tells you where it
# is. agetty reads /etc/issue.d/, so use that rather than clobbering a file the
# user may have customised.
mkdir -p /etc/issue.d
cat > /etc/issue.d/w01.issue <<'EOF'

  Wudung W01   address: \4

EOF

# ------------------------------------------------------------------- ssh ---
systemctl enable sshd || echo "WARNING: could not enable sshd"
systemctl start  sshd || echo "WARNING: could not start sshd"

echo
echo "=== done ==="
echo
echo "Now connect to your network:"
echo
echo "    wifi connect"
echo
echo "After that it reconnects by itself on every boot."
echo "To confirm it survives a restart, power the box off at the wall and"
echo "back on. Do NOT use reboot: this chip only initialises from a cold"
echo "power-on, and a warm reboot leaves it wedged."
