# Openwrt Installer for Zyxel EX5601-T0 / EX5601-T1 routers
### Tested on Generic ACDZ and most ISP specific ACEA ACQQ ACEN and ACID Firmwares

**This tool works without UART connection.**
The installation works from the SSH on OEM firmware, all you need is a single tar file and a script copied to /tmp directory.

> [!WARNING]
> Power loss during flash can brick the device.
> Keep backups of important MTD partitions before flashing 

## Online Install
If internet connection is working on router, use these commands, head to LUCI at port 8080 to finish installation 
```bash
cd /tmp
wget \
https://raw.githubusercontent.com/majad00/ex5601_openwrt_loader/main/tools/openwrt_chroot_rootfs.tar.gz \
https://raw.githubusercontent.com/majad00/ex5601_openwrt_loader/main/tools/loader.sh
chmod +x loader.sh ; ./loader.sh
```

## Offline Install 
If there is no internet connection on router
> Download latest release:  [openwrt_t56_installer_v2.zip](https://github.com/majad00/ex5601_openwrt_loader/releases/download/2/openwrt_t56_installer_v2.zip)
### Zip include two files:
1) Miniroot Archive (openwrt_chroot_rootfs.tar.gz)
2) Main script (loader.sh ) 

> UNZIP download and copy both files to the router's /tmp dir using WinSCP / the SCP or USB:

```bash
scp openwrt_chroot_rootfs.tar.gz loader.sh root@192.168.1.1:/tmp/
```
Alternatively, you can copy files to a USB drive and then use the USB drive to copy both files to /tmp

```bash
mount /dev/sda1 /mnt/usb
cp /mnt/usb/openwrt_chroot_rootfs.tar.gz /tmp
cp /mnt/usb/loader.sh /tmp

```
> Starting

(Assuming you have root access on SSH)
```bash
chmod +x /tmp/loader.sh
/tmp/loader.sh
```

Once the script completes, LUCI web server will be running in RAM at port 8080. 
Flash Openwrt from LUCI menu ... System > Install matrix > and select either stock or ubootmod layout.
> [!Tip]
> You can use LUCI menu ( System > Backup ) to backup current firmware
### Router reboot at the end , usually it take 30 to 50 seconds for full installation.

## Expert's Guide
This bundle provides a safe way to install OpenWrt on the Zyxel EX5601-T0 router directly from the OEM firmware flashing inactive partition, how we do that.

- **`loader.sh`** - A script that creates a Matrix/OpenWrt chroot environment on your running OEM firmware, similar to the second phase of sysupgrade. Instead of immediately flashing, it sets up additional services and the LuCI web interface to help you activate OpenWrt from within the OEM firmware at port 8080.

- **`openwrt_chroot_rootfs.tar.gz`** - OpenWrt rootfs with minimal services enabled.

---


### Troubleshooting
> [!IMPORTANT]
> > These command will create a log, check the log of diagnoses result. If unclear, contact the author or create an issue using repository page.
Start with SSH after the command `loader.sh` finishes and starts LUCI at port 8080.
```sh
# Read-only no-UART diagnosis: Try this first
/tmp/matrix_boot_initramfs.sh --diagnose
# Normal staging:
 /tmp/matrix_boot_initramfs.sh
# Stage without reboot:
NO_REBOOT=1 /tmp/matrix_boot_initramfs.sh
# Optional custom initramfs path:
INITRAMFS=/tmp/initramfs.bin /tmp/matrix_boot_initramfs.sh
```  
For diagnostic testing, stock layout try
```sh
/tmp/matrix_flash_inactive.sh --diagnose  
```
> [!WARNING]
> If router boot to the OEM after script completes, try a different conversion option (stokck Vs ubootmod). If it still fails, use UART-based installation, as repeated failing may brick your router.

> you can always recover your router using UART and utilities like mtk_uarboot or de-bricker.
### How to create miniroot from source

To create `openwrt_chroot_rootfs.tar.gz` file, follow these steps:

   a) Clone the repository and navigate to `source/ubi_patch`.  
   b) Download the latest OpenWrt sysupgrade  firmware with the stock layout.  
   c) Rename it to `openwrt.bin`.  
   d) Run `patch_bin.sh` in the `ubi_patch` directory.  
   e) Copy the generated files (`openwrt_ubi.bin` and `openwrt_ubi2.bin`) to `source/rootfs/etc`.  
   f) go to the `source/rootfs`, and run:
```bash
tar -cpzf ../openwrt_chroot_rootfs.tar.gz .
```  

This will generate "openwrt_chroot_rootfs.tar.gz" inside source dir

### Steps

```bash
# 1. Clone the repository
git clone https://github.com/majad00/ex5601_openwrt_loader.git
cd ex5601_openwrt_loader

# 2. Download the latest OpenWrt sysupgrade image (stock layout) You may also use another compatible OpenWrt stock-layout sysupgrade image for the EX5601-T0.
cd source/ubi_patch
wget https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/openwrt-24.10.5-mediatek-filogic-zyxel_ex5601-t0-stock-squashfs-sysupgrade.bin
mv openwrt-*.bin openwrt.bin

# 3. Apply the patch
chmod +x ./patch_bin.sh
./patch_bin.sh

# 4. Copy the generated files to the rootfs directory
cp openwrt_ubi.bin openwrt_ubi2.bin ../rootfs/etc/

# 5. Create the rootfs archive
cd ../rootfs
tar -cpzf ../openwrt_chroot_rootfs.tar.gz . ; cd ..
```

> The tool is licensed under the GPL v2 (GNU General Public License version 2).


