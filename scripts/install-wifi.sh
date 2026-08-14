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
# never gets it.
rm -f "$EXTRA/s9083s.ko"
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

if ! command -v iw >/dev/null || ! command -v wpa_supplicant >/dev/null; then
    echo "=== installing packages from the network ==="
    echo "(needs a working connection - see README if you have none yet)"
    pacman -Syu --noconfirm --needed iw wpa_supplicant openssh wget || {
        echo
        echo "ERROR: iw / wpa_supplicant are missing and could not be installed."
        echo "Bring the box online once (USB ethernet adapter, or the offline"
        echo "package bundle in the release) and re-run this script."
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

# show the address on the login screen, so a headless box tells you where it is
cat > /etc/issue <<'EOF'
Arch Linux ARM \r (\l)  -  Wudung W01

  \4

EOF

# ------------------------------------------------------------------- ssh ---
systemctl enable sshd >/dev/null 2>&1 || true
systemctl start  sshd >/dev/null 2>&1 || true

echo
echo "=== done ==="
echo
echo "Now connect to your network:"
echo
echo "    wifi connect"
echo
echo "After that it reconnects by itself on every boot."
echo "Reboot once to confirm the driver loads cleanly at startup."
