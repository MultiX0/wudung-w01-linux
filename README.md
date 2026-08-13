# Mainline Linux on the Wudung W01 (Allwinner H313)

Turn a cheap Wudung W01 Android TV box into a Linux machine that boots by
itself from its internal eMMC. No SD card slot, no serial port, no soldering.

This box has no SD card slot, no SPI flash, and no exposed UART, and its single
USB port is the only way in. That combination is why there was no working
recipe for it before. This repository is that recipe.

Hardware-identical boxes this also applies to:

| Name | Notes |
|---|---|
| Wudung W01 | what this was developed on |
| Tanix TX1 | same PCB, `CS_H313_TX1_EMCP_V1.1` and `QHZIW_H313_TX1_EMCP_V2.0` |
| Vontar QTV Q1 | same board |

| | |
|---|---|
| SoC | Allwinner H313 (`sun50iw9p1`), a binned H616, reports FEL id `0x1823` |
| CPU | Quad Cortex-A53, ARMv8, 64-bit |
| RAM | 1 to 2 GiB LPDDR3 |
| Storage | eMMC only, about 15 GiB. No SD slot. No SPI flash. |
| USB | One USB 2.0 type-A port, which is also the FEL recovery port |
| PMIC | AXP313 |
| WiFi | SCI S9082H, needs an out-of-tree driver, does not work yet |

End result: Arch Linux ARM booting from eMMC to a login prompt on HDMI, with
the USB port free for a keyboard.

**Warning.** This replaces the Android bootloader on the eMMC, so Android will
stop booting. You can put it back, see [Restoring stock
Android](#restoring-stock-android), but read that section before you start
rather than after.

---

## What you need

Hardware:

* The box, its power supply, and an HDMI cable to a TV or monitor.
* A USB A-to-A male-to-male cable, meaning both ends are the normal flat
  rectangular plug. This is not a common cable and you probably have to buy
  one. A normal phone charging cable will not work.
* A toothpick or similar thin plastic stick.
* A USB flash drive, 4 GB or larger. Only used during installation.
* A USB keyboard, and ideally a small USB hub, because the box has one port.

Software: a Linux PC, or Windows 10/11 with WSL2. Setup for both is below.

---

# Part 1: Set up your PC

Follow either the Linux or the Windows section, not both.

## Linux

```bash
sudo apt update
sudo apt install -y sunxi-tools git curl
```

Skip ahead to [Part 2](#part-2-install-u-boot-onto-the-box).

## Windows 10 / 11

You need two things: WSL2 (a real Linux environment) and usbipd-win (which
passes USB devices from Windows into WSL2).

### Step 1. Open PowerShell as Administrator

This matters. Several commands below fail with "Access denied" in a normal
window.

Press the Start button, type `PowerShell`, right click **Windows PowerShell**,
and choose **Run as administrator**. Click Yes on the prompt. The window title
must say "Administrator".

### Step 2. Install WSL2 and usbipd-win

In that Administrator PowerShell window:

```powershell
wsl --install -d Ubuntu
```

If it asks you to reboot, reboot, then continue. The first launch of Ubuntu
asks you to create a username and password. That password is for Linux, it can
be anything you will remember, and it will not show any characters as you type
it.

Still in Administrator PowerShell:

```powershell
winget install --exact --id dorssel.usbipd-win
```

Close PowerShell and open a new Administrator PowerShell window so the new
command is on the path.

### Step 3. Install the tools inside Ubuntu

Open Ubuntu from the Start menu and run:

```bash
sudo apt update
sudo apt install -y sunxi-tools git curl
```

### Step 4. How to attach the box to WSL2

You will repeat this every single time the box reboots or re-enters FEL mode,
because it re-enumerates as a new USB device each time.

In **Administrator PowerShell**:

```powershell
usbipd list
```

Look for a line with `1f3a:efe8`. Note its BUSID, for example `1-2`. Then, the
first time only:

```powershell
usbipd bind --busid 1-2
```

And every time you want to use it from Ubuntu:

```powershell
usbipd attach --wsl --busid 1-2
```

Replace `1-2` with your actual BUSID. `bind` needs Administrator. `attach` does
not, but it is easiest to keep using the same Administrator window.

---

# Part 2: Install U-Boot onto the box

Every command from here on runs in **Linux** (Ubuntu on WSL2 if you are on
Windows), unless it says PowerShell.

## Step 1. Download the files

```bash
mkdir -p ~/w01 && cd ~/w01
curl -LO https://github.com/MultiX0/wudung-w01-linux/releases/download/v1.0/sunxi-spl-fel-installer.bin
curl -LO https://github.com/MultiX0/wudung-w01-linux/releases/download/v1.0/u-boot-sunxi-with-spl-toc0.bin
git clone https://github.com/MultiX0/wudung-w01-linux.git
```

## Step 2. Put the box into FEL mode

Video showing how to enter FEL mode: *(placeholder, link to be added)*

1. Unplug the box from power completely.
2. Push a toothpick into the 3.5 mm A/V jack. There is a recessed button
   inside. Press and hold it.
3. While still holding, plug the USB A-to-A cable from the box into your PC.
4. Keep holding for about 2 seconds, then release.

Windows only, in Administrator PowerShell:

```powershell
usbipd list
usbipd attach --wsl --busid 1-2
```

Then check it worked, in Linux:

```bash
sunxi-fel ver
```

You should see a line containing `soc=00001823(H616)`. If you get
`ERROR: Allwinner USB FEL device not found!`, unplug the box and repeat this
step.

## Step 3. Install U-Boot

```bash
cd ~/w01/wudung-w01-linux/scripts
chmod +x fel-install-uboot.sh
./fel-install-uboot.sh ~/w01/sunxi-spl-fel-installer.bin ~/w01/u-boot-sunxi-with-spl-toc0.bin
```

Wait for this line:

```
SUCCESS - U-Boot is installed and verified byte-for-byte.
```

Do not continue unless you see it.

---

# Part 3: Boot Linux from a USB stick

## Step 1. Download the MiniArch image

This image is somebody else's work, see [Credits](#credits).

```bash
cd ~/w01
curl -LO https://github.com/warpme/miniarch/releases/download/15.2.0/MiniArch-15.2.0-06.06.2026-7.1.1-board-h313.tanix_tx1-SD-Image.img
```

## Step 2. Write it to the USB flash drive

On Windows, first attach the flash drive to WSL2. In Administrator PowerShell,
find its BUSID with `usbipd list` (it will say "USB Mass Storage Device"), then:

```powershell
usbipd bind --busid 1-1
usbipd attach --wsl --busid 1-1
```

Now in Linux, find the drive. Check this carefully, the next command erases
whatever you point it at:

```bash
lsblk
```

Write the image. Replace `/dev/sdX` with your drive, for example `/dev/sdb`,
and note it is the whole drive and not a partition like `/dev/sdb1`:

```bash
sudo dd if=MiniArch-15.2.0-06.06.2026-7.1.1-board-h313.tanix_tx1-SD-Image.img \
        of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

## Step 3. Point the image at the USB stick

The image ships configured to boot from eMMC, which is not where the system is
yet, so it has to be told to use the USB stick instead:

```bash
sudo mkdir -p /mnt/w01boot
sudo mount /dev/sdX1 /mnt/w01boot
sudo sed -i 's#root=/dev/mmcblk2p2#root=/dev/sda2#' /mnt/w01boot/extlinux/extlinux.conf
sudo sed -i 's#console=ttyS0,115200n8#console=tty0 console=ttyS0,115200n8#' /mnt/w01boot/extlinux/extlinux.conf
grep APPEND /mnt/w01boot/extlinux/extlinux.conf
sudo umount /mnt/w01boot
```

That `grep` should print a line containing `root=/dev/sda2` and `console=tty0`.
Adding `console=tty0` is what makes kernel messages appear on the TV. Without
it they only go to a serial port that this box does not expose.

## Step 4. Boot it

1. Unplug the USB stick from the PC and plug it into the box.
2. Make sure HDMI is connected.
3. Power the box on normally, with no toothpick this time.

You should see four penguins, then:

```
Arch Linux ARM 7.1.1 (tty1)
alarm login:
```

Log in as `alarm` with password `alarm`. The root password is `root`.

Linux now works, but only while the USB stick is plugged in. Continue if you
want the box to boot on its own.

---

# Part 4: Move Linux onto the eMMC

## Step 1. Put the install script on the stick

Plug the stick back into your PC, attach it to WSL2 again if you are on
Windows, then:

```bash
sudo mount /dev/sdX2 /mnt
cd ~/w01/wudung-w01-linux/emmc-install
sudo cp install-to-emmc.sh /mnt/usr/local/bin/
sudo chmod +x /mnt/usr/local/bin/install-to-emmc.sh
sudo cp install-to-emmc.service /mnt/etc/systemd/system/
sudo ln -sf /etc/systemd/system/install-to-emmc.service \
            /mnt/etc/systemd/system/multi-user.target.wants/install-to-emmc.service
sync
sudo umount /mnt
```

Note that this uses partition 2 (`/dev/sdX2`), the root filesystem, not
partition 1.

## Step 2. Run it

Plug the stick into the box and power it on.

It now runs on its own: it formats two eMMC partitions, copies everything
across, and then powers the box off by itself when it is finished. This takes a
few minutes. The box switching off is the signal that it is done.

If you want to check what happened, put the stick back in your PC and read
`/boot/emmc-install.log` on the first partition.

## Step 3. Boot standalone

Unplug the USB stick, leave it out, and power the box on.

It boots Arch Linux ARM from its own eMMC. The USB port is now free for a
keyboard.

---

## Restoring stock Android

If you want Android back, or something went wrong:

1. Download the stock firmware,
   [`Wudung_W01_20250616_1449.rar`](https://github.com/MultiX0/wudung-w01-linux/releases/download/v1.0/Wudung_W01_20250616_1449.rar),
   and extract the `.img` file inside it.
2. Install PhoenixSuit on a Windows PC. The installer, `PhoenixSuit_EN.msi`, is
   available at <https://legione.name/upload/?dir=Smart-TV-Box/Q1/>
3. Open PhoenixSuit, go to the Firmware tab, and select the `.img` file.
4. Put the box into FEL mode using the same toothpick procedure as above.
5. PhoenixSuit detects the box and offers to flash it. Accept.

This rewrites the whole eMMC, so it undoes everything in this guide.

The box is very hard to brick permanently. FEL mode lives in mask ROM inside
the SoC and cannot be erased by anything you write to the eMMC, so the toothpick
recovery always works.

---

## Troubleshooting

**`sunxi-fel` says no FEL device found.** On Windows, the most common cause is
forgetting to run `usbipd attach` after the box re-enumerated. Run
`usbipd list` in Administrator PowerShell and check the state of the device.

**`usbipd bind` says access denied.** The PowerShell window is not elevated.
Close it and open a new one with Run as administrator.

**`usbipd list` shows `Unknown USB Device (Device Descriptor Request Failed)`.**
The board firmware has crashed. Only a physical power cycle recovers it. Unplug
the box, then redo the FEL procedure.

**`usbipd list` shows the device as Attached but `sunxi-fel` times out.** The
listing can be stale. Run `usbipd detach --busid 1-2`, check the list again,
and if it now shows the failed-descriptor state, power cycle the box.

**The screen stays black after installing U-Boot.** That is expected. U-Boot
has no HDMI driver on this SoC, so nothing appears until the Linux kernel
starts. If the kernel never starts you will see nothing at all, which is why
step 3 of Part 2 verifies the install over USB instead of relying on the
screen.

---

# How it works, and how this was worked out

Everything below is background. You do not need it to follow the instructions
above.

## The core problem

The Allwinner BROM tries to boot in this order: SD card, then eMMC, then SPI
NOR, then USB FEL. This box has no SD slot and no SPI flash, so there are
exactly two possibilities: whatever is on the eMMC, or FEL recovery mode.

Mainline support already existed. `tanix_tx1_defconfig` landed in U-Boot
v2024.10-rc3 and `sun50i-h313-tanix-tx1.dtb` in Linux 6.10, both from Andre
Przywara. So why had nobody actually booted one of these?

Because the obvious approach cannot work. `sunxi-fel uboot` with a normal
64-bit build always dies like this:

```
=> Executing the SPL... done.
usb_bulk_send() ERROR -7: Operation timed out
```

U-Boot's own `board/sunxi/README.sunxi64` explains why:

> As the FEL mode is controlled by the boot ROM, it expects to be running in
> AArch32. For now the AArch64 SPL cannot properly return into FEL mode, so
> the feature is disabled in the configuration at the moment.

DRAM initialisation succeeds. The handoff back to the 32-bit BROM is what
breaks. On a board with an SD slot this does not matter, because you just write
an image to a card. Here it is fatal: FEL is the only way in, and the only
thing FEL can run cannot come back.

## The way through

Andre Przywara published a
[patch](https://gist.github.com/apritzel/573e1607b255f23ee025837379d8c706)
that builds the H616 SPL as 32-bit ARM. A 32-bit SPL can return to FEL.

That turns FEL into a usable code execution channel, which is all that is
needed. Run a throwaway 32-bit SPL over USB whose only job is to write a real
64-bit U-Boot into the eMMC. After that the box boots from eMMC normally and
the 32-bit build is never used again.

That is what `patches/0002-fel-emmc-installer.patch` does.

## Things that cost hours

Documented so nobody repeats them.

**The patch only applies to tag `v2025.07`.** Against current master,
`arch/arm/mach-sunxi/Kconfig` has drifted and `board_init_f` has moved. `git
apply` is atomic, so nothing applies at all, and the build then cheerfully
compiles arm64 assembly with a 32-bit toolchain and produces thousands of
`Error: ARM register expected`.

**`CONFIG_SUNXI_DRAM_MAX_SIZE` silently truncates to zero.** Kconfig has
`default 0x100000000 if MACH_SUN50I_H616`, but in a 32-bit build `phys_size_t`
is 32 bits, so it becomes `0`. Then in `board/sunxi/board.c`:

```c
if (gd->ram_size > CONFIG_SUNXI_DRAM_MAX_SIZE)
        gd->ram_size = CONFIG_SUNXI_DRAM_MAX_SIZE;   /* becomes ram_size = 0 */
```

U-Boot proper then believes it has no RAM. gcc does warn about it
(`changes value from '4294967296' to '0'`) but it is buried in the build log.
This cannot be fixed in `.config` either, because the symbol has no prompt, so
`make oldconfig` puts the broken default straight back. The Kconfig itself has
to be patched.

**`find_mmc_device()` hangs the CPU on the FEL path.** It walks a static list
in `drivers/mmc/mmc_legacy.c` that only `mmc_initialize()` ever sets up.
Nothing calls that when booting through FEL, so the list head is uninitialised
garbage, walking it dereferences a bogus pointer, and the CPU traps. With no
UART that is a completely silent hang. The fix is to call `mmc_initialize(NULL)`
first. This one cost the most time, because every failed attempt looked
identical from outside: the board vanishes from USB and needs a power cycle.

**`CONFIG_SPL_MMC_WRITE` is off by default and writes fail silently.** With it
disabled, `mmc_bwrite()` resolves to a stub in `drivers/mmc/mmc_private.h` that
just returns 0. The header literally describes them as "dummies to reduce code
size". So the write appears to succeed, reports zero sectors written, and never
touches the hardware.

**This BROM ignores the eMMC hardware boot partitions.** The documented
approach is `mmc partconf 1 1 1 1` to boot from `mmcblk2boot0`. Doing that and
reading `BOOT_PARTITION_ENABLE` back confirmed it was set, and Android still
booted. Dumping the raw eMMC showed why: the stock bootloader lives at LBA 16,
that is 8 KiB, in the user area, in Allwinner TOC0 format, and that is the only
place this BROM looks. The hardware boot partitions were blank and unused the
whole time.

**A plain eGON image is rejected, it has to be TOC0.** The first user-area
write used the default eGON container. The BROM silently refused it and fell
back to FEL. Rebuilding with `CONFIG_SPL_IMAGE_TYPE_SUNXI_TOC0`, self-signed
because the `ROTPK_HASH` eFuse is blank and therefore any key is accepted,
worked immediately.

**`sunxi-fel write` to a DRAM address needs DRAM to exist.** Obvious in
hindsight. Uploading the payload to `0x50000000` straight after power-on fails
with `ERROR -7`, because nothing has initialised the memory controller yet. The
SPL has to run once first, and only then can the payload be uploaded. That is
why `fel-install-uboot.sh` runs the SPL twice.

**U-Boot only scans partitions flagged bootable.** `scan_dev_for_boot_part`
uses `part list ... -bootable`, which filters on the GPT LegacyBIOSBootable
attribute. The repurposed Android partition did not have it, so U-Boot quietly
fell back to `devplist=1` and scanned partition 1, which is Android's unrelated
`bootloader` partition, and found nothing. It came down to one attribute bit.

**Do not let the installer copy itself.** The eMMC install script gets copied
into the new root filesystem along with everything else. If its systemd unit is
still enabled at the moment of copying, the copy runs on the first eMMC boot,
tries to reformat the filesystem it is running from, fails safely, and powers
the box off right before the login prompt, forever. `install-to-emmc.sh`
deletes itself from the destination to prevent this.

## Layout

The stock GPT is left completely alone. It is an unusual 17-entry table with
`first-lba = 73728`, and letting any normal partitioning tool rewrite it with
the standard 128-entry layout would put the entry array straight over the
bootloader at LBA 16. Instead, two existing Android partitions are simply
reformatted:

| Where | Was | Now |
|---|---|---|
| LBA 16, 8 KiB | Android TOC0 bootloader | 64-bit U-Boot and TF-A, TOC0 format |
| `mmcblk2p7`, 1.5 G | `cache` | `/boot`, ext4, LegacyBIOSBootable set |
| `mmcblk2p17`, 10.9 G | `UDISK` | `/`, ext4 |

Everything between LBA 16 and LBA 73728 is unallocated, about 36 MiB, so the
780 KiB bootloader fits with room to spare and no partition data is at risk.

## Known issues

* WiFi does not work. The SCI S9082H needs an out-of-tree driver.
* No U-Boot console output. U-Boot has no HDMI driver on the H616, so the
  screen stays black until the kernel starts. This is normal.
* `BUG: Bad page state in process swapper` appears at `[0.000000]` on boot. It
  is harmless and the system runs fine afterwards.
* `cfg80211: failed to load regulatory.db` is harmless, and moot until WiFi
  works anyway.
* There is only one USB port, so use a hub if you want a keyboard and anything
  else at the same time.

---

## Repository contents

```
patches/
  0001-apritzel-h616-32bit-build.patch   Andre Przywara's 32-bit build hack
  0002-fel-emmc-installer.patch          FEL eMMC installer and DRAM size fix
scripts/
  fel-install-uboot.sh                   installs U-Boot over FEL, main tool
  build-installer-spl.sh                 build the 32-bit installer yourself
  build-uboot-toc0.sh                    build the 64-bit TOC0 U-Boot yourself
emmc-install/
  install-to-emmc.sh                     USB to eMMC copy, runs on the box
  install-to-emmc.service                systemd unit for the above
prebuilt/                                same binaries as the Releases page
```

## Building from source

Not required, the prebuilt binaries on the Releases page are the same thing.

```bash
sudo apt install -y gcc-arm-linux-gnueabihf gcc-aarch64-linux-gnu bison flex \
    libssl-dev bc device-tree-compiler swig python3-dev python3-pyelftools \
    uuid-dev libgnutls28-dev pkg-config zlib1g-dev

cd scripts
./build-installer-spl.sh     # 32-bit FEL installer
./build-uboot-toc0.sh        # 64-bit TOC0 U-Boot payload
```

## Credits

Nearly all of the upstream work here is other people's:

* **Andre Przywara (apritzel)** for mainline U-Boot and Linux support for the
  H616 and H313 and the Tanix TX1, and for the
  [32-bit build patch](https://gist.github.com/apritzel/573e1607b255f23ee025837379d8c706)
  that makes any of this possible.
* **[MiniArch](https://github.com/warpme/miniarch) by warpme** for the Arch
  Linux ARM image used here.
* **[linux-sunxi](https://linux-sunxi.org/Tanix_TX1)** for hardware
  documentation, the [FEL](https://linux-sunxi.org/FEL) and
  [TOC0](https://linux-sunxi.org/TOC0) references, and `sunxi-tools`.
* **billymore** in this [Armbian
  thread](https://forum.armbian.com/topic/56895-have-armbian-for-tanix-tx1-qhziw_h313_tx1_emcp_v20/)
  and **simplicite72** in [MiniArch issue
  116](https://github.com/warpme/miniarch/issues/116), who both got a kernel
  booting on this board and documented where it stopped.
* **carbofos** for W01 PCB photos and FEL findings in [sunxi-tools issue
  222](https://github.com/linux-sunxi/sunxi-tools/issues/222).

## Licence

Patches and scripts are GPL-2.0, matching U-Boot.

The stock firmware image on the Releases page is Wudung's, redistributed only
so owners can restore their own hardware.
